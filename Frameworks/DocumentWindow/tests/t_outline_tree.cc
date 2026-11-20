#include "../src/outline_tree.h"

#include <cstddef>
#include <initializer_list>
#include <vector>

static std::vector<size_t> depths_of (std::initializer_list<size_t> list) { return std::vector<size_t>(list); }

void test_outline_symbol_depth_from_em_space_indentation ()
{
	std::string trimmed;
	OAK_ASSERT(oak::outline_symbol_depth("plain", trimmed) == 0);
	OAK_ASSERT(trimmed == "plain");

	OAK_ASSERT(oak::outline_symbol_depth("\xE2\x80\x83""nested", trimmed) == 1);
	OAK_ASSERT(trimmed == "nested");

	OAK_ASSERT(oak::outline_symbol_depth("\xE2\x80\x83\xE2\x80\x83""twice", trimmed) == 2);
	OAK_ASSERT(trimmed == "twice");

	// Regular spaces are not indentation.
	OAK_ASSERT(oak::outline_symbol_depth("  padded", trimmed) == 0);
	OAK_ASSERT(trimmed == "  padded");

	// Em-space inside the name is preserved.
	OAK_ASSERT(oak::outline_symbol_depth("\xE2\x80\x83""a\xE2\x80\x83""b", trimmed) == 1);
	OAK_ASSERT(trimmed == "a\xE2\x80\x83""b");
}

void test_outline_separator_names ()
{
	OAK_ASSERT(oak::outline_is_separator("-"));
	OAK_ASSERT(!oak::outline_is_separator("-x"));
	OAK_ASSERT(!oak::outline_is_separator(""));
}

void test_outline_normalized_depths_clamps_jumps ()
{
	OAK_ASSERT(oak::outline_normalized_depths(depths_of({})) == depths_of({}));
	OAK_ASSERT(oak::outline_normalized_depths(depths_of({0, 1, 2, 1, 0})) == depths_of({0, 1, 2, 1, 0}));
	// First entry can never be nested.
	OAK_ASSERT(oak::outline_normalized_depths(depths_of({2, 3})) == depths_of({0, 1}));
	// A jump of two levels collapses to one.
	OAK_ASSERT(oak::outline_normalized_depths(depths_of({0, 4, 5, 0})) == depths_of({0, 1, 2, 0}));
}

void test_outline_parents_builds_tree_links ()
{
	OAK_ASSERT(oak::outline_parents(depths_of({})) == std::vector<std::ptrdiff_t>{});

	// A – B – C, back to A, then a new root.
	std::vector<std::ptrdiff_t> parents = oak::outline_parents(depths_of({0, 1, 2, 1, 0}));
	std::vector<std::ptrdiff_t> expected = { -1, 0, 1, 0, -1 };
	OAK_ASSERT(parents == expected);

	// Normalized depths never orphan an entry.
	parents = oak::outline_parents(oak::outline_normalized_depths(depths_of({3, 1, 2})));
	expected = { -1, 0, 1 };
	OAK_ASSERT(parents == expected);
}
