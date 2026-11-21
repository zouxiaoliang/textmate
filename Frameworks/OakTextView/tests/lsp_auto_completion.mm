#import <Cocoa/Cocoa.h>
#import "../src/OakTextView_Private.h"
#import "../src/OakTextView_LSPUtilities.h"
#import <lsp/LSPClient.h>
#import <lsp/LSPManager.h>
#import <document/OakDocument Private.h>

static BOOL WaitUntil (NSTimeInterval timeout, BOOL (^predicate)(void))
{
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while(!predicate() && [deadline timeIntervalSinceNow] > 0)
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
	return predicate();
}

int main ()
{
	@autoreleasepool
	{
		[NSApplication sharedApplication];
		NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"lsp_auto_completion_%@", NSUUID.UUID.UUIDString]];
		[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
		NSString* resultFile = [directory stringByAppendingPathComponent:@"result.txt"];
		LSPClient* client = [[LSPClient alloc] initWithCommand:@"/usr/bin/python3"
			arguments:@[ @LSP_TEST_FIXTURE, @"f11_completion", resultFile ]
			workingDirectory:directory initOptions:nil];
		if(!WaitUntil(10, ^{ return client.initialized; }))
			return 2;

		OakDocument* doc = [OakDocument documentWithString:@"" fileType:@"source.ts" customName:nil];
		[doc loadModalForWindow:nil completionHandler:nullptr];
		doc.path = [directory stringByAppendingPathComponent:@"case.ts"];
		LSPManager* manager = [LSPManager sharedManager];
		NSMutableDictionary* clients = [manager valueForKey:@"_documentClients"];
		clients[doc.identifier] = client;

		NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 300)
			styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
		window.releasedWhenClosed = NO;
		OakTextView* view = [[OakTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, 300)];
		window.contentView = view;
		view.document = doc;
		[window makeKeyAndOrderFront:nil];
		[window makeFirstResponder:view];

		BOOL supports = [manager serverSupportsCompletionsForDocument:doc];
		// Match realKeyDown:'s outer refresh cycle: insertText: returns before
		// the outer cycle advances the buffer revision.
		{
			refresh_helper_t keyEvent(view, view->documentView);
			[view insertText:@"f"];
		}
		{
			refresh_helper_t keyEvent(view, view->documentView);
			[view insertText:@"o"];
		}
		BOOL appeared = WaitUntil(5, ^{ return [view->_lspCompletionPopup isVisible]; });
		NSString* verdict = [NSString stringWithContentsOfFile:resultFile encoding:NSUTF8StringEncoding error:NULL];
		BOOL correctRequest = [verdict containsString:@"SCENARIO f11_completion PASS"];
		BOOL untouched = [doc.content isEqualToString:@"fo"];
		NSEvent* tab = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
			modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil
			characters:@"\t" charactersIgnoringModifiers:@"\t" isARepeat:NO keyCode:48];
		if(appeared)
			[view keyDown:tab];
		BOOL accepted = [doc.content isEqualToString:@"foobar"];
		view.document = nil;
		[window close];
		[clients removeObjectForKey:doc.identifier];
		[client shutdown];
		WaitUntil(5, ^{ return !client.running; });
		[[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];

		if(!supports || !appeared || !correctRequest || !untouched || !accepted)
		{
			fprintf(stderr, "FAIL: supports=%d popup=%d request=%d inputUntouched=%d accepted=%d\n", supports, appeared, correctRequest, untouched, accepted);
			return 1;
		}
		printf("PASS: typing opens LSP candidates and Tab accepts without premature insertion\n");
	}
	return 0;
}
