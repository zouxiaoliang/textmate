#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import "../src/DocumentWindowController.h"
#import "../src/OutlineViewController.h"
#import "../src/ProjectLayoutView.h"
#import <OakTextView/OakDocumentView.h>
#import <OakTextView/OakTextView.h>

void test_restored_outline_loads_symbols_when_language_server_opens_document ()
{
	NSFileManager* files = NSFileManager.defaultManager;
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	OAK_ASSERT([files createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:nil]);
	NSString* fixture = [@(__FILE__).stringByDeletingLastPathComponent.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"context-tests/language_server.py"];
	OAK_ASSERT([files copyItemAtPath:fixture toPath:[directory stringByAppendingPathComponent:@"server.py"] error:nil]);
	NSString* settings = [NSString stringWithFormat:@"lspCommand = '/usr/bin/python3 server.py'\nlspRootPath = '%@'\n", directory];
	OAK_ASSERT([settings writeToFile:[directory stringByAppendingPathComponent:@".textmate"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	NSString* source = [directory stringByAppendingPathComponent:@"source.cpp"];
	OAK_ASSERT([@"// Symbols for this test come from the language server.\n" writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	NSString* secondSource = [directory stringByAppendingPathComponent:@"second.cpp"];
	OAK_ASSERT([files copyItemAtPath:source toPath:secondSource error:nil]);

	__block DocumentWindowController* controller;
	__block NSOutlineView* tree;
	__block NSPopUpButton* menu;
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		controller = [[DocumentWindowController alloc] init];
		NSDictionary* project = @{
			@"projectPath": directory, @"fileBrowserVisible": @YES, @"outlineVisible": @YES,
			@"documents": @[ @{ @"path": source, @"fileType": @"source.c++", @"selected": @YES }, @{ @"path": secondSource, @"fileType": @"source.c++" } ],
		};
		((void(*)(id, SEL, NSDictionary*, BOOL))objc_msgSend)(controller, @selector(setupControllerForProject:skipMissingFiles:), project, YES);
		ProjectLayoutView* layout = [controller valueForKey:@"layoutView"];
		tree = (NSOutlineView*)[(NSScrollView*)layout.outlineView.subviews.firstObject documentView];
	});

	BOOL (^waitFor)(BOOL (^)(void)) = ^BOOL(BOOL (^predicate)(void)){
		NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:4];
		do {
			__block BOOL found;
			dispatch_sync(dispatch_get_main_queue(), ^{
				found = predicate();
			});
			if(found)
				return YES;
			[NSThread sleepForTimeInterval:0.02];
		} while(deadline.timeIntervalSinceNow > 0);
		return NO;
	};
	BOOL loadedAutomatically = waitFor(^BOOL{
		return tree.numberOfRows > 0 && [[[tree itemAtRow:0] description] isEqualToString:@"Outer"];
	});
	OAK_MASSERT("The restored outline must load symbols without being toggled", loadedAutomatically);
	dispatch_sync(dispatch_get_main_queue(), ^{
		OakDocumentView* editor = [controller valueForKey:@"documentView"];
		menu = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
		OAK_ASSERT([editor tryToPerform:@selector(showSymbolSelector:) with:menu]);
		OAK_ASSERT(([menu.itemTitles isEqualToArray:@[ @"Outer", @"inner" ]]));
		NSMenuItem* inner = [menu itemAtIndex:1];
		OAK_ASSERT(inner.indentationLevel == 1);
		OAK_ASSERT([NSApp sendAction:inner.action to:inner.target from:inner]);
		OAK_ASSERT([controller.textView.selectionString isEqualToString:@"1:4"]);
		controller.outlineVisible = NO;
		[controller selectNextTab:nil];
	});
	OAK_ASSERT(waitFor(^BOOL{ return [[[controller.selectedDocument valueForKey:@"path"] lastPathComponent] isEqualToString:@"second.cpp"]; }));
	dispatch_sync(dispatch_get_main_queue(), ^{
		OakDocumentView* editor = [controller valueForKey:@"documentView"];
		OAK_ASSERT([editor tryToPerform:@selector(showSymbolSelector:) with:menu]);
		OAK_ASSERT(([menu.itemTitles isEqualToArray:@[ @"Loading symbols…" ]]));
	});
	OAK_MASSERT("The status bar can load symbols without the outline", waitFor(^BOOL{
		return [menu.itemTitles isEqualToArray:@[ @"Outer", @"inner" ]];
	}));
	dispatch_sync(dispatch_get_main_queue(), ^{
		[controller close];
		[DocumentWindowController enableSessionSave];
	});
	[files removeItemAtPath:directory error:nil];
}

void test_outline_scroll_view_fills_panel ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		@autoreleasepool
		{
			[NSApplication sharedApplication];
			OutlineViewController* controller = [[OutlineViewController alloc] init];
			NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 250, 400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
			window.releasedWhenClosed = NO;
			NSView* panel = controller.view;
			panel.translatesAutoresizingMaskIntoConstraints = NO;
			[window.contentView addSubview:panel];
			[NSLayoutConstraint activateConstraints:@[
				[panel.leftAnchor constraintEqualToAnchor:window.contentView.leftAnchor],
				[panel.rightAnchor constraintEqualToAnchor:window.contentView.rightAnchor],
				[panel.topAnchor constraintEqualToAnchor:window.contentView.topAnchor],
				[panel.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor],
			]];
			[window.contentView layoutSubtreeIfNeeded];
			NSScrollView* scrollView = (NSScrollView*)panel.subviews.firstObject;
			OAK_ASSERT(NSWidth(scrollView.frame) == NSWidth(panel.bounds));
			OAK_ASSERT(NSHeight(scrollView.frame) == NSHeight(panel.bounds));

			NSDictionary* (^symbol)(NSString*, NSInteger, NSArray*) = ^NSDictionary*(NSString* name, NSInteger kind, NSArray* children){
				return @{ @"name": name, @"kind": @(kind), @"selectionRange": @{ @"start": @{ @"line": @0, @"character": @0 } }, @"children": children };
			};
			NSArray* symbols = @[ symbol(@"redxx", 3, @[ symbol(@"Channel", 5, @[ symbol(@"post", 6, @[]), symbol(@"loop", 8, @[]) ]), symbol(@"connect", 12, @[]) ]), symbol(@"main", 12, @[]) ];
			OAK_ASSERT([controller tryToPerform:@selector(rebuildFromLSPDocumentSymbols:) with:symbols]);
			NSOutlineView* tree = (NSOutlineView*)scrollView.documentView;
			OAK_ASSERT(tree.numberOfRows == 2);
			id module = [tree itemAtRow:0];
			[tree expandItem:module expandChildren:YES];
			[window.contentView layoutSubtreeIfNeeded];
			OAK_ASSERT(tree.numberOfRows == 6);
			id type = [tree itemAtRow:1];
			OAK_ASSERT([tree parentForItem:type] == module && [tree parentForItem:[tree itemAtRow:2]] == type);
			NSTableCellView* moduleRow = [tree viewAtColumn:0 row:0 makeIfNecessary:YES];
			NSTableCellView* typeRow = [tree viewAtColumn:0 row:1 makeIfNecessary:YES];
			NSTableCellView* methodRow = [tree viewAtColumn:0 row:2 makeIfNecessary:YES];
			OAK_ASSERT(moduleRow.imageView.image && typeRow.imageView.image && methodRow.imageView.image);
			OAK_ASSERT(NSMinX(moduleRow.frame) < NSMinX(typeRow.frame) && NSMinX(typeRow.frame) < NSMinX(methodRow.frame));
			[tree collapseItem:type];
			OAK_ASSERT(tree.numberOfRows == 4 && [tree parentForItem:[tree itemAtRow:2]] == module);
			[window close];
		}
	});
}

void test_project_and_outline_share_a_collapsible_sidebar ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		@autoreleasepool
		{
			[NSApplication sharedApplication];
			[DocumentWindowController disableSessionSave];
			DocumentWindowController* controller = [[DocumentWindowController alloc] init];
			ProjectLayoutView* layout = [controller valueForKey:@"layoutView"];
			layout.fileBrowserOnRight = NO;
			layout.fileBrowserWidth = 250;
			controller.fileBrowserVisible = YES;
			[controller.window setContentSize:NSMakeSize(900, 540)];
			NSRect windowFrame = controller.window.frame;
			controller.outlineVisible = YES;
			[controller.window.contentView layoutSubtreeIfNeeded];

			NSView* project = layout.fileBrowserView;
			NSView* outline = layout.outlineView;
			NSView* sidebar = project.superview;
			OAK_ASSERT(sidebar && sidebar == outline.superview);
			OAK_ASSERT(NSWidth(project.frame) > 0 && NSWidth(project.frame) == NSWidth(outline.frame));
			OAK_ASSERT(NSMinY(project.frame) > NSMaxY(outline.frame));
			OAK_ASSERT(NSMaxX(sidebar.frame) < NSMinX(layout.documentView.frame));
			OAK_ASSERT(NSEqualRects(windowFrame, controller.window.frame));

			NSButton* projectHeader = nil;
			NSButton* outlineHeader = nil;
			for(NSView* row in sidebar.subviews)
			{
				if([row isKindOfClass:NSButton.class])
				{
					NSButton* button = (NSButton*)row;
					if([button.title isEqualToString:@"Project"]) projectHeader = button;
					if([button.title isEqualToString:@"Outline"]) outlineHeader = button;
				}
			}
			OAK_ASSERT(projectHeader && outlineHeader);
			NSView* actions = layout.fileBrowserActionsView;
			OAK_ASSERT(actions.superview == sidebar && actions.subviews.count == 6);
			for(NSView* button in actions.subviews)
				OAK_ASSERT(!button.hidden && NSWidth(button.frame) > 0);
			OAK_ASSERT(NSMinX(actions.frame) > NSMaxX(projectHeader.frame));
			OAK_ASSERT(std::abs(NSMidY(actions.frame) - NSMidY(projectHeader.frame)) <= 0.5);

			layout.fileBrowserWidth = 125;
			[controller.window.contentView layoutSubtreeIfNeeded];
			NSPopUpButton* actionsMenu = nil;
			NSUInteger visibleButtons = 0;
			for(NSView* button in actions.subviews)
			{
				if([button isKindOfClass:NSPopUpButton.class]) actionsMenu = (NSPopUpButton*)button;
				if(!button.hidden) ++visibleButtons;
			}
			OAK_ASSERT(visibleButtons < actions.subviews.count && actionsMenu && !actionsMenu.hidden);
			OAK_ASSERT(NSContainsRect(actions.bounds, actionsMenu.frame));
			[actionsMenu.menu.delegate menuNeedsUpdate:actionsMenu.menu];
			for(SEL action : { @selector(newDocumentInDirectory:), @selector(reload:), @selector(orderFrontFindPanelForFileBrowser:), @selector(goToFavorites:), @selector(goToSCMDataSource:) })
				OAK_ASSERT([actionsMenu.menu indexOfItemWithTarget:nil andAction:action] != -1 || [actionsMenu.menu indexOfItemWithTarget:actionsMenu.menu.delegate andAction:action] != -1);
			layout.fileBrowserWidth = 250;
			[controller.window.contentView layoutSubtreeIfNeeded];

			OAK_ASSERT(NSMaxY(outlineHeader.frame) == NSMinY(project.frame));
			CGFloat originalOutlineHeight = NSHeight(outline.frame);
			BOOL (^increaseHeight)(void) = outlineHeader.accessibilityCustomActions.firstObject.handler;
			OAK_ASSERT(increaseHeight && increaseHeight());
			OAK_ASSERT(NSHeight(outline.frame) > originalOutlineHeight);
			CGFloat beforeDrag = NSHeight(outline.frame);
			NSPoint start = [outlineHeader convertPoint:NSMakePoint(NSMidX(outlineHeader.bounds), NSMidY(outlineHeader.bounds)) toView:nil];
			start.y += NSHeight(outlineHeader.bounds) / 2 + 2;
			NSPoint end = NSMakePoint(start.x, start.y + 30);
			NSEvent* (^mouseEvent)(NSEventType, NSPoint) = ^NSEvent*(NSEventType type, NSPoint location){
				return [NSEvent mouseEventWithType:type location:location modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:controller.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
			};
			NSView* hit = [layout hitTest:[layout.superview convertPoint:start fromView:nil]];
			OAK_ASSERT(hit.superview == sidebar && hit != project && hit != outlineHeader);
			OAK_ASSERT(NSMinY(hit.frame) == NSMaxY(outlineHeader.frame));
			[NSApp postEvent:mouseEvent(NSEventTypeLeftMouseUp, end) atStart:YES];
			[NSApp postEvent:mouseEvent(NSEventTypeLeftMouseDragged, end) atStart:YES];
			[hit mouseDown:mouseEvent(NSEventTypeLeftMouseDown, start)];

			CGFloat resizedOutlineHeight = NSHeight(outline.frame);
			OAK_ASSERT(!layout.outlineCollapsed && resizedOutlineHeight == beforeDrag + 30 && resizedOutlineHeight == layout.outlineHeight);
			OAK_ASSERT(NSEqualRects(windowFrame, controller.window.frame));
			NSPoint click = [outlineHeader convertPoint:NSMakePoint(NSMidX(outlineHeader.bounds), NSMidY(outlineHeader.bounds)) toView:nil];
			click.y += NSHeight(outlineHeader.bounds) / 2 - 2;
			OAK_ASSERT([layout hitTest:[layout.superview convertPoint:click fromView:nil]] == outlineHeader);
			[outlineHeader performClick:nil];
			OAK_ASSERT(layout.outlineCollapsed && !outline.superview);
			[outlineHeader performClick:nil];
			[controller.window.contentView layoutSubtreeIfNeeded];
			OAK_ASSERT(!layout.outlineCollapsed && NSHeight(outline.frame) == resizedOutlineHeight);
			CGFloat projectTitleX = NSMinX([(NSButtonCell*)projectHeader.cell titleRectForBounds:projectHeader.bounds]);
			CGFloat outlineTitleX = NSMinX([(NSButtonCell*)outlineHeader.cell titleRectForBounds:outlineHeader.bounds]);
			[projectHeader performClick:nil];
			[controller.window.contentView layoutSubtreeIfNeeded];
			OAK_ASSERT(projectTitleX == NSMinX([(NSButtonCell*)projectHeader.cell titleRectForBounds:projectHeader.bounds]));
			OAK_ASSERT(!project.superview && !actions.superview && outline.superview == sidebar);
			OAK_ASSERT(outlineHeader.accessibilityCustomActions.count == 0);
			[outlineHeader performClick:nil];
			[controller.window.contentView layoutSubtreeIfNeeded];
			OAK_ASSERT(outlineTitleX == NSMinX([(NSButtonCell*)outlineHeader.cell titleRectForBounds:outlineHeader.bounds]));
			OAK_ASSERT(!outline.superview && outlineHeader.superview == sidebar && projectHeader.superview == sidebar);
			[projectHeader performClick:nil];
			OAK_ASSERT(project.superview == sidebar && !outline.superview);
			[outlineHeader performClick:nil];
			layout.fileBrowserOnRight = YES;
			[controller.window.contentView layoutSubtreeIfNeeded];
			OAK_ASSERT(outline.superview == sidebar && NSMinX(sidebar.frame) > NSMaxX(layout.documentView.frame));
			OAK_ASSERT(NSHeight(outline.frame) == resizedOutlineHeight);
			OAK_ASSERT(NSEqualRects(windowFrame, controller.window.frame));

			[controller close];
			[DocumentWindowController enableSessionSave];
		}
	});
}
