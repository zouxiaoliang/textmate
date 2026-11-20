#ifndef OUTLINE_TREE_H_7C0D139C
#define OUTLINE_TREE_H_7C0D139C

#include <cstddef>
#include <string>
#include <vector>

namespace oak
{
	// Grammar-derived symbol names indent nested symbols with em-spaces (U+2003),
	// the same convention used by the status bar symbol pop up and “Jump to Symbol”.
	// Returns the number of leading em-spaces and stores the trimmed name.
	inline size_t outline_symbol_depth (std::string const& name, std::string& trimmed)
	{
		static std::string const em_space = "\xE2\x80\x83";
		size_t pos = 0;
		while(name.compare(pos, em_space.size(), em_space) == 0)
			pos += em_space.size();
		trimmed = name.substr(pos);
		return pos / em_space.size();
	}

	inline bool outline_is_separator (std::string const& name) { return name == "-"; }

	// Clamp so depth grows at most one level per entry; bundles may emit jumps.
	inline std::vector<size_t> outline_normalized_depths (std::vector<size_t> const& depths)
	{
		std::vector<size_t> res;
		res.reserve(depths.size());
		size_t prev = 0;
		for(size_t i = 0; i < depths.size(); ++i)
		{
			size_t depth = depths[i];
			if(i == 0)
				depth = 0;
			else if(depth > prev + 1)
				depth = prev + 1;
			res.push_back(depth);
			prev = depth;
		}
		return res;
	}

	// Parent index for each entry, -1 for roots. Depths must be normalized first.
	inline std::vector<std::ptrdiff_t> outline_parents (std::vector<size_t> const& depths)
	{
		std::vector<std::ptrdiff_t> res;
		res.reserve(depths.size());
		std::vector<size_t> stack; // index of the most recent item at each depth
		for(size_t i = 0; i < depths.size(); ++i)
		{
			size_t const depth = depths[i];
			while(stack.size() > depth)
				stack.pop_back();
			res.push_back(stack.empty() ? -1 : (std::ptrdiff_t)stack.back());
			stack.push_back(i);
		}
		return res;
	}

} /* namespace oak */

#endif /* OUTLINE_TREE_H_7C0D139C */
