#import "../src/OakTextView_Private.h"
#import <lsp/LSPClient.h>
#import <lsp/LSPManager.h>

@interface ContextMenuTextView : OakTextView
@property (nonatomic, copy) NSString* jumpedURI;
@property (nonatomic) NSUInteger jumpedLine;
@property (nonatomic) NSUInteger jumpedCharacter;
@end

@implementation ContextMenuTextView
- (void)jumpToLSPLocation:(NSString*)uri line:(NSUInteger)line character:(NSUInteger)character
{
	self.jumpedURI = uri;
	self.jumpedLine = line;
	self.jumpedCharacter = character;
}
@end

static BOOL WaitUntil (NSTimeInterval timeout, BOOL (^predicate)(void))
{
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while(!predicate() && deadline.timeIntervalSinceNow > 0)
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
	return predicate();
}

static NSMenu* MenuAtByte (OakTextView* view, size_t index)
{
	CGRect caret = view->documentView->rect_at_index(index);
	NSPoint point = [view convertPoint:NSMakePoint(CGRectGetMinX(caret) + 0.25, CGRectGetMidY(caret)) toView:nil];
	NSEvent* click = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:point modifierFlags:0 timestamp:0
		windowNumber:view.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
	NSMenu* menu = [view menuForEvent:click];
	[menu update];
	NSMenuItem* item = [menu itemWithTitle:@"LSP"];
	return item.enabled ? item.submenu : nil;
}

static BOOL Choose (NSMenu* menu, NSString* title)
{
	NSMenuItem* item = [menu itemWithTitle:title];
	if(!item.enabled)
		return NO;
	[menu performActionForItemAtIndex:[menu indexOfItem:item]];
	return YES;
}

int main ()
{
	@autoreleasepool
	{
		[NSApplication sharedApplication];
		NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
		[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
		NSString* resultFile = [directory stringByAppendingPathComponent:@"result.txt"];
		OakDocument* doc = [OakDocument documentWithString:@"alpha\nreturn sample\n" fileType:@"source.ts" customName:nil];
		[doc loadModalForWindow:nil completionHandler:nullptr];
		doc.path = [directory stringByAppendingPathComponent:@"case.ts"];

		NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 300)
			styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
		window.releasedWhenClosed = NO;
		ContextMenuTextView* view = [[ContextMenuTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, 300)];
		window.contentView = view;
		view.document = doc;
		[window makeKeyAndOrderFront:nil];
		[window makeFirstResponder:view];

		NSMenu* withoutServer = MenuAtByte(view, 15);
		BOOL noServerState = [withoutServer itemWithTitle:@"No Language Server"] && ![withoutServer itemWithTitle:@"Go to Definition"].enabled;
		LSPClient* client = [[LSPClient alloc] initWithCommand:@"/usr/bin/python3"
			arguments:@[ @LSP_TEST_FIXTURE, @"f12_context_menu", resultFile ] workingDirectory:directory initOptions:nil];
		LSPManager* manager = LSPManager.sharedManager;
		NSMutableDictionary* clients = [manager valueForKey:@"_documentClients"];
		NSMutableSet* openDocuments = [manager valueForKey:@"_openDocuments"];
		clients[doc.identifier] = client;
		[openDocuments addObject:doc.identifier];
		[client openDocument:doc languageId:@"typescript"];

		BOOL ready = WaitUntil(10, ^{ return [manager isServerReadyForDocument:doc]; });
		view.selectionString = @"1:1";
		NSMenu* codeMenu = [MenuAtByte(view, 15) copy];
		BOOL unsupported = [codeMenu itemWithTitle:@"Go to Implementation"] && ![codeMenu itemWithTitle:@"Go to Implementation"].enabled;
		BOOL jumped = Choose(codeMenu, @"Go to Definition") && WaitUntil(5, ^{ return view.jumpedURI != nil; }) &&
			[view.jumpedURI isEqualToString:[NSURL fileURLWithPath:doc.path].absoluteString] && view.jumpedLine == 0 && view.jumpedCharacter == 1;

		view.selectionString = @"2:8-2:14";
		BOOL rangeFormatted = Choose(MenuAtByte(view, 15), @"Format Selection") &&
			WaitUntil(5, ^{ return [doc.content isEqualToString:@"alpha\nreturn SAMPLE\n"]; });
		view.selectionString = @"2:8-2:14";
		BOOL documentFormatted = Choose(MenuAtByte(view, 2), @"Format Document") &&
			WaitUntil(5, ^{ return [doc.content isEqualToString:@"ALPHA\nreturn SAMPLE\n"]; });

		view.document = nil;
		[window close];
		[openDocuments removeObject:doc.identifier];
		[clients removeObjectForKey:doc.identifier];
		[client shutdown];
		WaitUntil(5, ^{ return !client.running; });
		NSString* verdict = [NSString stringWithContentsOfFile:resultFile encoding:NSUTF8StringEncoding error:NULL];
		[[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
		if(!noServerState || !ready || !unsupported || !jumped || !rangeFormatted || !documentFormatted || ![verdict containsString:@"SCENARIO f12_context_menu PASS"])
		{
			fprintf(stderr, "FAIL: noServer=%d ready=%d unsupported=%d jump=%d formatSelection=%d formatDocument=%d\n%s\n",
				noServerState, ready, unsupported, jumped, rangeFormatted, documentFormatted, (verdict ?: @"").UTF8String);
			return 1;
		}
		puts("PASS: native context menu dispatches definition and formatting to the server at the clicked position or selection");
	}
	return 0;
}
