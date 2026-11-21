#import <layout/layout.h>
#import <buffer/buffer.h>
#import <theme/theme.h>

void test_inlay_hint_reserves_space_without_changing_buffer ()
{
	ng::buffer_t buffer;
	buffer.replace(0, 0, "f(1, 2)\n");
	theme_ptr theme = parse_theme(bundles::lookup(kMacClassicThemeUUID));
	OAK_ASSERT(theme);

	ng::layout_t layout(buffer, theme, "Menlo", 12);
	layout.update_metrics(CGRectMake(0, 0, 500, 100));
	CGFloat before = CGRectGetMinX(layout.rect_at_index(ng::index_t(2)));
	layout.set_inlay_hints({{2, "value: "}});
	CGFloat after = CGRectGetMinX(layout.rect_at_index(ng::index_t(2)));
	OAK_ASSERT(after > before);
	OAK_ASSERT_EQ(buffer.substr(0, buffer.size()), "f(1, 2)\n");
	CGPoint middleOfHint = CGPointMake((before + after) / 2, CGRectGetMidY(layout.rect_at_index(ng::index_t(2))));
	OAK_ASSERT_EQ(layout.index_at_point(middleOfHint).index, 2);

	buffer.replace(2, 3, "3");
	layout.update_metrics(CGRectMake(0, 0, 500, 100));
	OAK_ASSERT_EQ(CGRectGetMinX(layout.rect_at_index(ng::index_t(2))), before);
	layout.set_inlay_hints({{2, "value: "}});
	OAK_ASSERT(CGRectGetMinX(layout.rect_at_index(ng::index_t(2))) > before);
	layout.set_inlay_hints({});
	OAK_ASSERT_EQ(CGRectGetMinX(layout.rect_at_index(ng::index_t(2))), before);
	OAK_ASSERT(layout.structural_integrity());
}

void test_edit_preserves_hints_on_untouched_lines ()
{
	ng::buffer_t buffer;
	buffer.replace(0, 0, "f(1)\ng(2)\nh(3)\n");
	theme_ptr theme = parse_theme(bundles::lookup(kMacClassicThemeUUID));
	OAK_ASSERT(theme);

	ng::layout_t layout(buffer, theme, "Menlo", 12);
	layout.update_metrics(CGRectMake(0, 0, 500, 100));
	size_t first = buffer.begin(0) + 2, edited = buffer.begin(1) + 2, last = buffer.begin(2) + 2;
	CGFloat plainFirst = CGRectGetMinX(layout.rect_at_index(ng::index_t(first)));
	CGFloat plainLast = CGRectGetMinX(layout.rect_at_index(ng::index_t(last)));
	layout.set_inlay_hints({{first, "first: "}, {edited, "edited: "}, {last, "last: "}});

	buffer.replace(buffer.begin(1) + 1, buffer.begin(1) + 1, "XX");
	layout.update_metrics(CGRectMake(0, 0, 500, 100));
	ng::layout_t plain(buffer, theme, "Menlo", 12);
	plain.update_metrics(CGRectMake(0, 0, 500, 100));
	OAK_ASSERT(CGRectGetMinX(layout.rect_at_index(ng::index_t(first))) > plainFirst);
	OAK_ASSERT(CGRectGetMinX(layout.rect_at_index(ng::index_t(buffer.begin(1) + 4))) >
	           CGRectGetMinX(plain.rect_at_index(ng::index_t(buffer.begin(1) + 4))));
	OAK_ASSERT(CGRectGetMinX(layout.rect_at_index(ng::index_t(last + 2))) > plainLast);
	buffer.replace(buffer.begin(1) + 4, buffer.begin(1) + 5, "4");
	layout.update_metrics(CGRectMake(0, 0, 500, 100));
	OAK_ASSERT_EQ(CGRectGetMinX(layout.rect_at_index(ng::index_t(buffer.begin(1) + 4))),
	              CGRectGetMinX(plain.rect_at_index(ng::index_t(buffer.begin(1) + 4))));
	OAK_ASSERT(CGRectGetMinX(layout.rect_at_index(ng::index_t(first))) > plainFirst);
	OAK_ASSERT(CGRectGetMinX(layout.rect_at_index(ng::index_t(last + 2))) > plainLast);
	OAK_ASSERT(layout.structural_integrity());
}

void test_inserted_line_shifts_unrelated_hints ()
{
	ng::buffer_t buffer;
	buffer.replace(0, 0, "f(1)\ng(2)\nh(3)\n");
	theme_ptr theme = parse_theme(bundles::lookup(kMacClassicThemeUUID));
	OAK_ASSERT(theme);
	ng::layout_t layout(buffer, theme, "Menlo", 12);
	layout.update_metrics(CGRectMake(0, 0, 500, 100));
	size_t first = buffer.begin(0) + 2, last = buffer.begin(2) + 2;
	CGFloat plainFirst = CGRectGetMinX(layout.rect_at_index(ng::index_t(first)));
	CGFloat plainLast = CGRectGetMinX(layout.rect_at_index(ng::index_t(last)));
	layout.set_inlay_hints({{first, "first: "}, {last, "last: "}});

	buffer.replace(buffer.begin(1), buffer.begin(1), "new\n");
	layout.update_metrics(CGRectMake(0, 0, 500, 100));
	OAK_ASSERT(CGRectGetMinX(layout.rect_at_index(ng::index_t(first))) > plainFirst);
	OAK_ASSERT(CGRectGetMinX(layout.rect_at_index(ng::index_t(buffer.begin(3) + 2))) > plainLast);
	buffer.replace(buffer.begin(1), buffer.begin(2), "");
	layout.update_metrics(CGRectMake(0, 0, 500, 100));
	OAK_ASSERT(CGRectGetMinX(layout.rect_at_index(ng::index_t(first))) > plainFirst);
	OAK_ASSERT(CGRectGetMinX(layout.rect_at_index(ng::index_t(buffer.begin(2) + 2))) > plainLast);
	OAK_ASSERT(layout.structural_integrity());
}

void test_layout_of_edited_offscreen_lines ()
{
	ng::buffer_t buffer("first\nsecond\nthird\nfourth\n");
	theme_ptr theme = parse_theme(bundles::lookup(kMacClassicThemeUUID));
	ng::layout_t layout(buffer, theme, "Menlo", 12);
	buffer.replace(buffer.begin(1) + 2, buffer.begin(2) + 2, "\t中\x01");
	size_t offset = buffer.begin(1) + 7;
	OAK_ASSERT_EQ(layout.index_at_eol_for(offset).index, buffer.eol(1));
	OAK_ASSERT(layout.structural_integrity());

	auto line = layout.line_record_for(text::pos_t(1, 0));
	OAK_ASSERT_EQ(layout.index_at_point(CGPointMake(0, (line.top + line.bottom) / 2)).index, buffer.begin(1));
	CGRect caret = layout.rect_at_index(offset);
	OAK_ASSERT_EQ(layout.index_at_point(CGPointMake(CGRectGetMinX(caret), CGRectGetMidY(caret))).index, offset);

	layout.fold(buffer.begin(1) + 1, buffer.begin(2) + 2);
	OAK_ASSERT_EQ(layout.index_right_of(buffer.begin(1) + 1).index, buffer.begin(2) + 2);
	layout.unfold(buffer.begin(1) + 1, buffer.begin(2) + 2);
	OAK_ASSERT(layout.structural_integrity());
}

void test_soft_wrap_breaks_follow_edits ()
{
	std::string input;
	for(size_t repeat = 0; repeat < 200; ++repeat)
		input += "abcdefgh ijk\t中lm nopqr ";
	ng::buffer_t buffer(input.c_str());
	theme_ptr theme = parse_theme(bundles::lookup(kMacClassicThemeUUID));
	ng::layout_t layout(buffer, theme, "Menlo", 12, true, false, 18);
	layout.update_metrics(CGRectMake(0, 0, 300, 200));
	buffer.insert(3, "XXX");
	layout.update_metrics(CGRectMake(0, 0, 300, 200));
	ng::layout_t fresh(buffer, theme, "Menlo", 12, true, false, 18);
	fresh.update_metrics(CGRectMake(0, 0, 300, 200));
	OAK_ASSERT_EQ(layout.height(), fresh.height());
	for(size_t index : { 0, 30, 2200, 3900 })
	{
		auto visualLine = fresh.softline_for_index(index);
		OAK_ASSERT_EQ(layout.softline_for_index(index), visualLine);
		OAK_ASSERT_EQ(layout.range_for_softline(visualLine).min().index, fresh.range_for_softline(visualLine).min().index);
		OAK_ASSERT_EQ(layout.range_for_softline(visualLine).max().index, fresh.range_for_softline(visualLine).max().index);
	}
	OAK_ASSERT(layout.structural_integrity());
}
