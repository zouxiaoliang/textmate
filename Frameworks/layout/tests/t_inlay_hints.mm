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
