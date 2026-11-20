#import <Cocoa/Cocoa.h>
#import "../src/OakTextView_Private.h"
#import <lsp/LSPManager.h>

int main ()
{
	@autoreleasepool
	{
		OakTextView* view = [[OakTextView alloc] initWithFrame:NSMakeRect(0, 0, 500, 200)];
		OakDocument* document = [OakDocument documentWithString:@"f(1, 2)\n" fileType:@"source.c" customName:nil];
		[document loadModalForWindow:nil completionHandler:nullptr];
		view.document = document;
		if(!view->documentView)
			return 2;

		CGFloat before = CGRectGetMinX(view->documentView->rect_at_index(ng::index_t(2)));
		view->documentView->set_inlay_hints({{2, "value: "}});
		CGFloat withHint = CGRectGetMinX(view->documentView->rect_at_index(ng::index_t(2)));
		if(withHint <= before)
			return 3;

		view.document = document;
		CGFloat after = CGRectGetMinX(view->documentView->rect_at_index(ng::index_t(2)));
		if(after != withHint)
		{
			fprintf(stderr, "FAIL: reselecting document removed inlay hint (%.1f -> %.1f)\n", withHint, after);
			return 1;
		}
		[view refreshInlayHints:[NSNotification notificationWithName:LSPInlayHintsRefreshNotification object:document]];
		after = CGRectGetMinX(view->documentView->rect_at_index(ng::index_t(2)));
		if(after != withHint)
		{
			fprintf(stderr, "FAIL: refreshing hints removed them before the server replied (%.1f -> %.1f)\n", withHint, after);
			return 1;
		}
		view.document = nil;
		printf("PASS: reselecting and refreshing preserve visible inlay hints\n");
	}
	return 0;
}
