#include <layout/layout.h>
#include <theme/theme.h>
#include <mach/mach.h>
#include <chrono>

namespace
{
	using clock_type = std::chrono::steady_clock;

	double elapsed_ms (clock_type::time_point start)
	{
		return std::chrono::duration<double, std::milli>(clock_type::now() - start).count();
	}

	double footprint_mib ()
	{
		task_vm_info_data_t info{};
		mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
		if(task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS)
			return -1;
		return info.phys_footprint / (1024.0 * 1024.0);
	}

	struct layout_callback_t : ng::callback_t
	{
		layout_callback_t (ng::buffer_t& buffer, ng::layout_t& layout) : buffer(buffer), layout(layout) { buffer.add_callback(this); }
		~layout_callback_t () { buffer.remove_callback(this); }
		void did_parse (size_t from, size_t to) override { layout.did_update_scopes(from, to); }
		ng::buffer_t& buffer;
		ng::layout_t& layout;
	};
}

int main (int argc, char const* argv[])
{
	std::string mode = argc > 1 ? argv[1] : "plain";
	bool longLine = mode == "long-line" || mode == "long-wrap";
	if(mode != "plain" && mode != "semantic" && !longLine)
	{
		fprintf(stderr, "usage: %s [plain|semantic|long-line|long-wrap] [line-count or long-line-byte-count] [max-p95-ms]\n", argv[0]);
		return 2;
	}

	size_t count = argc > 2 ? strtoull(argv[2], nullptr, 10) : (longLine ? 1024 * 1024 : 200000);
	if(count < 2)
		return 2;

	auto theme = parse_theme(bundles::lookup(kMacClassicThemeUUID));
	ng::buffer_t buffer;
	double initialFootprint = footprint_mib();
	auto start = clock_type::now();
	std::string const line = "const example = calculate(argument); // sample text\n";
	{
		std::string input;
		if(longLine)
			input.assign(count, 'x');
		else
		{
			input.reserve(line.size() * count);
			for(size_t row = 0; row < count; ++row)
				input += line;
		}
		buffer.insert(0, input);
	}
	printf("%s: %zu bytes, %zu lines, buffer %.2f ms, footprint %.2f MiB (initial %.2f MiB)\n",
	       mode.c_str(), buffer.size(), buffer.lines(), elapsed_ms(start), footprint_mib(), initialFootprint);

	start = clock_type::now();
	ng::layout_t layout(buffer, theme, "Menlo", 12, mode == "long-wrap");
	layout_callback_t callback(buffer, layout);
	CGRect viewport = CGRectMake(0, 0, 1000, 700);
	layout.set_viewport_size(viewport.size);
	layout.update_metrics(viewport);
	printf("layout %.2f ms, footprint %.2f MiB\n", elapsed_ms(start), footprint_mib());

	if(mode == "semantic")
	{
		start = clock_type::now();
		{
			std::vector<ng::buffer_t::semantic_range_t> ranges;
			ranges.reserve(3 * count);
			for(size_t row = 0; row < count; ++row)
			{
				size_t offset = row * line.size();
				ranges.push_back({offset + 6, offset + 13, "variable.other"});
				ranges.push_back({offset + 16, offset + 25, "entity.name.function"});
				ranges.push_back({offset + 26, offset + 34, "variable.parameter"});
			}
			buffer.set_semantic_scopes(ranges);
		}
		layout.update_metrics(viewport);
		printf("semantic overlay %.2f ms, footprint %.2f MiB\n", elapsed_ms(start), footprint_mib());
	}

	std::vector<double> edits;
	ng::ranges_t selection(0);
	for(size_t edit = 0; edit < 40; ++edit)
	{
		size_t offset = longLine ? count / 2 : buffer.begin(edit % std::min<size_t>(count, 20)) + 8;
		selection = ng::ranges_t(offset);
		start = clock_type::now();
		layout.begin_refresh_cycle(selection);
		if(edit < 20)
			buffer.insert(offset, "x");
		else
			buffer.erase(offset, offset + 1);
		buffer.bump_revision();
		selection = ng::ranges_t(offset + (edit < 20));
		layout.end_refresh_cycle(selection, viewport);
		edits.push_back(elapsed_ms(start));
	}
	if(!layout.structural_integrity())
		return 1;

	std::sort(edits.begin(), edits.end());
	double p95 = edits[edits.size() * 95 / 100 - 1];
	printf("edit p50 %.3f ms, p95 %.3f ms, max %.3f ms, footprint %.2f MiB\n",
	       edits[edits.size() / 2], p95, edits.back(), footprint_mib());
	return argc > 3 && p95 > strtod(argv[3], nullptr);
}
