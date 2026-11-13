#include "buffer.h"
#include "meta_data.h"
#include <cstring>

namespace ng
{
	// ===================
	// = buffer_parser_t =
	// ===================

	namespace
	{
		// Parse this many lines (or bytes) per job. The result is applied on the main thread, so
		// batching amortizes the cost of hopping between the parser queue and the main run loop,
		// which previously happened once per line.
		size_t const kRepairBatchMaxLines = 64;
		size_t const kRepairBatchMaxBytes = 256 * 1024;

		struct result_t
		{
			parse::stack_ptr state;
			std::map<size_t, scope::scope_t> scopes; // offsets are relative to the start of the parsed text
			size_t parsed_to = 0;                    // how far we parsed; may be less than the text size when the parser state converged with an existing state
		};

		result_t parse_batch (parse::grammar_ptr const& grammar, parse::stack_ptr state, std::string const& text, std::map<size_t, parse::stack_ptr> const& existingStates, bool firstLine)
		{
			std::lock_guard<std::mutex> lock(grammar->mutex());

			result_t result;
			char const* from       = text.data();
			char const* const last = from + text.size();
			size_t pos = 0;

			while(from < last)
			{
				char const* const eol = (char const*)memchr(from, '\n', last - from);
				char const* const to  = eol ? eol + 1 : last;

				std::map<size_t, scope::scope_t> scopes;
				state = parse::parse(from, to, state, scopes, firstLine && pos == 0);
				for(auto const& pair : scopes)
					result.scopes.emplace(pos + pair.first, pair.second);

				pos += to - from;
				from = to;

				// Stop when the parser state is identical to the state we already have at the upcoming
				// line boundary, i.e. parsing further would not change any scopes.
				auto existing = existingStates.find(pos);
				if(existing != existingStates.end() && parse::equal(state, existing->second))
					break;
			}

			result.state     = state;
			result.parsed_to = pos;
			return result;
		}
	}

	// ============
	// = buffer_t =
	// ============

	std::pair<size_t, parse::stack_ptr> buffer_t::parser_state_at_or_before (size_t from) const
	{
		auto it = _parser_states.lower_bound(from);
		if(it == _parser_states.end() || it->first != from)
		{
			if(it == _parser_states.begin())
				return { from, parse::stack_ptr() };
			--it;
		}
		return { std::max<ssize_t>(it->first, 0), it->second };
	}

	size_t buffer_t::repair_batch_end (size_t from) const
	{
		size_t const n    = convert(from).line;
		size_t const last = std::min(n + kRepairBatchMaxLines, lines()) - 1;
		size_t to         = end(last);

		if(to - from > kRepairBatchMaxBytes)
		{
			auto it = _hardlines.lower_bound(from + kRepairBatchMaxBytes);
			if(it != _hardlines.begin())
			{
				--it;
				if(it->first >= (ssize_t)from)
					to = it->first + 1;
			}
		}

		return to;
	}

	void buffer_t::initiate_repair ()
	{
		if(!_async_parsing || _parser_running)
			return;

		if(!_dirty.empty() && !_parser_states.empty())
		{
			size_t n = convert(_dirty.begin()->first).line;
			auto state = parser_state_at_or_before(begin(n));
			if(!state.second)
			{
				os_log_error(OS_LOG_DEFAULT, "No parser state for line %zu (%p)", n, this);
				return;
			}

			size_t const from = state.first;
			size_t const to   = repair_batch_end(from);

			// Parser states we already have at line boundaries inside (from, to), used to stop
			// parsing when the state converges with an existing one.
			std::map<size_t, parse::stack_ptr> existingStates;
			for(auto it = _parser_states.lower_bound(from + 1); it != _parser_states.end() && it->first < (ssize_t)to; ++it)
				existingStates.emplace(it->first - from, it->second);

			auto grammarRef      = grammar();
			std::string const text = substr(from, to);
			bool const firstLine = from == 0;

			size_t const bufferRev = revision();
			auto bufferRef         = parser_reference();
			_parser_running        = true;

			CFRunLoopRef runLoop = CFRunLoopGetCurrent();
			dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
				result_t result = parse_batch(grammarRef, state.second, text, existingStates, firstLine);
				CFRunLoopPerformBlock(runLoop, kCFRunLoopCommonModes, ^{
					if(bufferRef.lock())
					{
						_parser_running = false;
						if(bufferRev == revision())
						{
							size_t const parsedTo = std::min(from + result.parsed_to, size());
							update_scopes({ from, parsedTo }, result.scopes, result.state);
						}
						else
						{
							initiate_repair();
						}
					}
				});
				CFRunLoopWakeUp(runLoop);
			});
		}
	}

	void buffer_t::update_scopes (std::pair<size_t, size_t> const& range, std::map<size_t, scope::scope_t> const& newScopes, parse::stack_ptr parserState)
	{
		bool atEOF = range.second >= size();
		_scopes.remove(_scopes.lower_bound(range.first), atEOF ? _scopes.end() : _scopes.lower_bound(range.second));
		for(auto const& pair : newScopes)
		{
			if(range.first + pair.first < range.second || atEOF)
				_scopes.set(range.first + pair.first, pair.second);
		}

		_dirty.remove(_dirty.lower_bound(range.first), atEOF ? _dirty.end() : _dirty.lower_bound(range.second));
		if((_parser_states.find(range.second) == _parser_states.end() || !parse::equal(parserState, (_parser_states.find(range.second)->second))))
		{
			_parser_states.set(range.second, parserState);
			if(!atEOF)
				_dirty.set(range.second, true);
		}

		_parser_reference.reset();
		_parser_running = false;

		did_parse(range.first, range.second);
		initiate_repair();
	}

	void buffer_t::wait_for_repair ()
	{
		if(!grammar())
			return;

		_parser_reference.reset();
		_parser_running = false;

		// Using the NSSpellChecker API while main thread is blocked can result in this exception:
		// Dispatch Thread Soft Limit Reached: 64 (too many dispatch threads blocked in synchronous operations)
		// Therefor we disable spell checking during refresh. First noticed with macOS 10.12
		if(_spelling)
			_spelling->set_disabled(true);

		auto grammarRef = grammar();

		while(!_dirty.empty() && !_parser_states.empty())
		{
			size_t n = convert(_dirty.begin()->first).line;
			auto state = parser_state_at_or_before(begin(n));
			if(!state.second)
			{
				os_log_error(OS_LOG_DEFAULT, "No parser state for line %zu (%p)", n, this);
				break;
			}

			size_t const from = state.first;
			size_t const to   = repair_batch_end(from);

			std::map<size_t, parse::stack_ptr> existingStates;
			for(auto it = _parser_states.lower_bound(from + 1); it != _parser_states.end() && it->first < (ssize_t)to; ++it)
				existingStates.emplace(it->first - from, it->second);

			result_t result = parse_batch(grammarRef, state.second, substr(from, to), existingStates, from == 0);
			update_scopes({ from, from + result.parsed_to }, result.scopes, result.state);
		}

		if(_spelling)
			_spelling->set_disabled(false);
	}

} /* ng */
