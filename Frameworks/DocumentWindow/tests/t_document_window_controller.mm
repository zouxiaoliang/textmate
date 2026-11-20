#import <Cocoa/Cocoa.h>
#import "../src/DocumentWindowController.h"
#import "../src/EmptyWorkspaceView.h"
#import "../src/ProjectLayoutView.h"
#import "../src/TerminalPanelViewController.h"
#import <FileBrowser/FileBrowserViewController.h>
#import <FileBrowser/FileItem.h>
#import <Find/Find.h>
#import <OakFoundation/OakFoundation.h>
#import <OakTextView/OakDocumentView.h>
#import <OakTextView/OakNavigationHistory.h>
#import <OakTextView/OakTextView.h>
#import <OakTabBarView/OakTabBarView.h>
#import <Preferences/Keys.h>
#import <Preferences/ShortcutsPreferences.h>
#import <document/OakDocument.h>
#import <document/OakDocumentController.h>
#import <kvdb/kvdb.h>
#import <objc/message.h>
#import <objc/runtime.h>

extern "C" NSRect SidebarExpandedFrame (NSRect frame, NSRect screen, CGFloat sidebarWidth, CGFloat editorWidth, BOOL onRight);

static void wait_for_sidebar_animation (DocumentWindowController* controller)
{
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:2];
	while([controller valueForKey:@"sidebarTransitionTimer"] && deadline.timeIntervalSinceNow > 0)
		[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
	OAK_ASSERT(![controller valueForKey:@"sidebarTransitionTimer"]);
}

static bool region_has_ink (NSBitmapImageRep* bitmap, NSSize viewSize, NSRect region, CGFloat contrast = 0.2)
{
	CGFloat sx = bitmap.pixelsWide / viewSize.width, sy = bitmap.pixelsHigh / viewSize.height;
	CGFloat min = 1, max = 0;
	for(NSInteger y = floor((viewSize.height - NSMaxY(region)) * sy); y < ceil((viewSize.height - NSMinY(region)) * sy); ++y)
	{
		for(NSInteger x = floor(NSMinX(region) * sx); x < ceil(NSMaxX(region) * sx); ++x)
		{
			NSColor* color = [[bitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
			CGFloat lightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3;
			min = MIN(min, lightness);
			max = MAX(max, lightness);
			if(max - min > contrast)
				return true;
		}
	}
	return false;
}

static CGFloat title_bar_ink_center_y (NSBitmapImageRep* bitmap, NSSize viewSize, NSRect region)
{
	CGFloat sx = bitmap.pixelsWide / viewSize.width, sy = bitmap.pixelsHigh / viewSize.height;
	NSInteger first = bitmap.pixelsHigh, last = -1;
	for(NSInteger y = floor((viewSize.height - NSMaxY(region)) * sy); y < ceil((viewSize.height - NSMinY(region)) * sy); ++y)
	{
		for(NSInteger x = floor(NSMinX(region) * sx); x < ceil(NSMaxX(region) * sx); ++x)
		{
			NSColor* color = [[bitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
			if((color.redComponent + color.greenComponent + color.blueComponent) / 3 > 0.24)
			{
				first = MIN(first, y);
				last = y;
				break;
			}
		}
	}
	OAK_ASSERT(first <= last);
	return (first + last) / 2.0;
}

void test_empty_window_shortcuts_follow_menu_configuration ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSMenu* originalMenu = NSApp.mainMenu;
		NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Main"];
		for(NSString* section in @[ @"File", @"View", @"Navigate", @"Edit", @"Bundles", @"TextMate" ])
		{
			NSMenuItem* parent = [[NSMenuItem alloc] initWithTitle:section action:nil keyEquivalent:@""];
			parent.submenu = [[NSMenu alloc] initWithTitle:section];
			[menu addItem:parent];
		}
		NSArray<NSString*>* labels = @[ @"Open…", @"New document", @"New tab", @"Open Quickly…", @"Open Recent Project…", @"File Browser", @"Outline", @"Terminal Panel" ];
		NSArray<NSString*>* actions = @[ @"openDocument:", @"newDocument:", @"newDocumentInTab:", @"goToFile:", @"openFavorites:", @"toggleFileBrowser:", @"toggleOutline:", @"toggleTerminalPanel:" ];
		for(NSUInteger index = 0; index < actions.count; ++index)
		{
			NSMenu* submenu = [menu itemWithTitle:index < 5 ? @"File" : @"View"].submenu;
			NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:labels[index] action:NSSelectorFromString(actions[index]) keyEquivalent:@[ @"o", @"n", @"t", @"g", @"r", @"d", @"l", @"p" ][index]];
			item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
			[submenu addItem:item];
		}
		auto addShortcut = ^NSMenuItem*(NSMenu* submenu, NSString* title, NSString* action, NSString* key, NSEventModifierFlags flags){
			NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:NSSelectorFromString(action) keyEquivalent:key];
			item.keyEquivalentModifierMask = flags;
			[submenu addItem:item];
			return item;
		};
		NSMenuItem* palette = addShortcut([menu itemWithTitle:@"Navigate"].submenu, @"Command Palette…", @"showCommandPalette:", @"P", NSEventModifierFlagCommand | NSEventModifierFlagShift);
		NSMenuItem* find = addShortcut([menu itemWithTitle:@"Edit"].submenu, @"Find", @"", @"", 0);
		find.submenu = [[NSMenu alloc] initWithTitle:@"Find"];
		addShortcut(find.submenu, @"Find and Replace…", @"orderFrontFindPanel:", @"f", NSEventModifierFlagCommand).tag = FFSearchTargetDocument;
		addShortcut(find.submenu, @"Find in Project…", @"orderFrontFindPanel:", @"F", NSEventModifierFlagCommand | NSEventModifierFlagShift).tag = FFSearchTargetProject;
		addShortcut([menu itemWithTitle:@"Bundles"].submenu, @"Select Bundle Item…", @"showBundleItemChooser:", @"t", NSEventModifierFlagControl | NSEventModifierFlagCommand);
		addShortcut([menu itemWithTitle:@"TextMate"].submenu, @"Preferences…", @"showPreferences:", @",", NSEventModifierFlagCommand);

		NSApp.mainMenu = menu;
		DocumentWindowController* controller = [DocumentWindowController new];
		[controller.window setContentSize:NSMakeSize(900, 600)];
		[controller showWindow:nil];
		EmptyWorkspaceView* empty = [controller valueForKey:@"emptyStateView"];
		NSView* files = [empty valueForKey:@"files"];
		NSView* tools = [empty valueForKey:@"tools"];
		NSArray<NSView*>* fileRows = [files valueForKey:@"rows"];
		NSArray<NSView*>* toolRows = [tools valueForKey:@"rows"];
		OAK_ASSERT(fileRows.count == 6 && toolRows.count == 6);
		OAK_ASSERT([[(NSTextField*)[fileRows.firstObject valueForKey:@"shortcut"] stringValue] isEqualToString:@"⌘O"]);
		OAK_ASSERT([[(NSTextField*)[fileRows[3] valueForKey:@"shortcut"] stringValue] isEqualToString:@"⇧⌘F"]);
		OAK_ASSERT([[(NSTextField*)[toolRows.firstObject valueForKey:@"name"] stringValue] isEqualToString:@"Command Palette…"]);
		OAK_ASSERT([[(NSTextField*)[toolRows.firstObject valueForKey:@"shortcut"] stringValue] isEqualToString:@"⇧⌘P"]);
		[controller.window.contentView layoutSubtreeIfNeeded];
		OAK_ASSERT(NSMinX(tools.frame) > NSMaxX(files.frame));
		OAK_ASSERT(NSMinY(tools.frame) == NSMinY(files.frame));
		OAK_ASSERT(NSMaxY(empty.heading.frame) < NSMinY(files.frame));
		for(NSView* row in fileRows)
		{
			NSView* name = [row valueForKey:@"name"];
			NSView* keycap = [[row valueForKey:@"shortcut"] superview].superview;
			OAK_ASSERT(!NSIntersectsRect(name.frame, keycap.frame));
			OAK_ASSERT(NSMaxX(keycap.frame) == NSWidth(row.bounds));
		}
		NSMenuItem* open = [menu itemWithTitle:@"File"].submenu.itemArray.firstObject;
		palette.keyEquivalent = @"k";
		palette.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
		[NSNotificationCenter.defaultCenter postNotificationName:MenuShortcutsDidChangeNotification object:nil];
		OAK_ASSERT(tools.superview == nil);
		tools = [empty valueForKey:@"tools"];
		toolRows = [tools valueForKey:@"rows"];
		OAK_ASSERT([[(NSTextField*)[toolRows.firstObject valueForKey:@"shortcut"] stringValue] isEqualToString:@"⇧⌘K"]);
		open.keyEquivalent = @"";
		[NSNotificationCenter.defaultCenter postNotificationName:MenuShortcutsDidChangeNotification object:nil];
		OAK_ASSERT(files.superview == nil);
		files = [empty valueForKey:@"files"];
		tools = [empty valueForKey:@"tools"];
		OAK_ASSERT([(NSArray*)[files valueForKey:@"rows"] count] == 5);
		[controller setValue:@YES forKey:@"disableFileBrowserWindowResize"];
		controller.fileBrowserWidth = 250;
		[controller.window setContentSize:NSMakeSize(560, 320)];
		controller.fileBrowserVisible = YES;
		wait_for_sidebar_animation(controller);
		[controller.window.contentView layoutSubtreeIfNeeded];
		OAK_ASSERT(NSMinX(tools.frame) == NSMinX(files.frame));
		OAK_ASSERT(NSMinY(tools.frame) > NSMaxY(files.frame));
		OAK_ASSERT(NSMaxX(tools.frame) <= NSWidth(empty.contentView.bounds));
		[empty.documentView scrollRectToVisible:tools.frame];
		OAK_ASSERT(NSContainsRect(empty.documentVisibleRect, tools.frame));
		[controller close];
		NSApp.mainMenu = originalMenu;
		[DocumentWindowController enableSessionSave];
	});
}

void test_sidebar_window_only_grows_when_editor_needs_room ()
{
	NSRect screen = NSMakeRect(0, 0, 1200, 800);
	NSRect wide = NSMakeRect(300, 100, 800, 450);
	NSRect narrow = NSMakeRect(300, 100, 560, 450);
	NSRect atLeftEdge = NSMakeRect(0, 100, 560, 450);
	NSRect fullWidth = NSMakeRect(0, 100, 1200, 450);
	OAK_ASSERT(NSEqualRects(SidebarExpandedFrame(wide, screen, 250, 800, NO), wide));
	OAK_ASSERT(NSEqualRects(SidebarExpandedFrame(wide, screen, 250, 651, NO), wide));
	OAK_ASSERT(NSEqualRects(SidebarExpandedFrame(wide, screen, 250, 600, NO), NSMakeRect(249, 100, 851, 450)));
	OAK_ASSERT(NSEqualRects(SidebarExpandedFrame(narrow, screen, 250, 560, NO), NSMakeRect(209, 100, 651, 450)));
	OAK_ASSERT(NSEqualRects(SidebarExpandedFrame(atLeftEdge, screen, 250, 560, NO), NSMakeRect(0, 100, 651, 450)));
	OAK_ASSERT(NSEqualRects(SidebarExpandedFrame(fullWidth, screen, 250, 560, NO), fullWidth));
	OAK_ASSERT(NSEqualRects(SidebarExpandedFrame(narrow, screen, 250, 560, YES), NSMakeRect(300, 100, 651, 450)));
}

void test_sidebar_collapses_when_dragged_small ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		DocumentWindowController* controller = [DocumentWindowController new];
		ProjectLayoutView* layout = [controller valueForKey:@"layoutView"];
		layout.fileBrowserOnRight = NO;
		controller.fileBrowserWidth = 250;
		[controller.window setFrame:NSMakeRect(0, 0, 800, 450) display:NO];
		[controller showWindow:nil];
		[(NSButton*)[controller valueForKey:@"sidebarButton"] performClick:nil];
		wait_for_sidebar_animation(controller);
		NSView* sidebar = [layout valueForKey:@"sidebar"];
		OAK_ASSERT(controller.fileBrowserVisible && controller.outlineVisible);
		[layout layoutSubtreeIfNeeded];
		OAK_ASSERT(NSWidth(sidebar.frame) > 100);
		NSRect frameBeforeDrag = controller.window.frame;
		NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
		NSInteger savedSidebarWidth = [defaults integerForKey:@"fileBrowserWidth"];

		NSPoint start = [layout convertPoint:NSMakePoint(NSMaxX(sidebar.frame), NSMidY(sidebar.frame)) toView:nil];
		NSPoint intermediate = NSMakePoint(start.x - NSWidth(sidebar.frame) + 115, start.y);
		NSPoint end = NSMakePoint(start.x - NSWidth(sidebar.frame) + 50, start.y);
		NSEvent* down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:start modifierFlags:0 timestamp:1 windowNumber:controller.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
		NSEvent* drag = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged location:intermediate modifierFlags:0 timestamp:2 windowNumber:controller.window.windowNumber context:nil eventNumber:2 clickCount:1 pressure:1];
		NSEvent* finalDrag = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged location:end modifierFlags:0 timestamp:3 windowNumber:controller.window.windowNumber context:nil eventNumber:3 clickCount:1 pressure:1];
		NSEvent* up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:end modifierFlags:0 timestamp:4 windowNumber:controller.window.windowNumber context:nil eventNumber:4 clickCount:1 pressure:1];
		[NSApp postEvent:up atStart:YES];
		[NSApp postEvent:finalDrag atStart:YES];
		[NSApp postEvent:drag atStart:YES];
		[layout mouseDown:down];
		if([controller valueForKey:@"sidebarCollapseToken"])
		{
			BOOL sawIntermediateWidth = NO;
			NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:2];
			while([controller valueForKey:@"sidebarCollapseToken"] && deadline.timeIntervalSinceNow > 0)
			{
				[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
				CGFloat width = NSWidth(sidebar.frame);
				sawIntermediateWidth |= sidebar.superview && width > 1 && width < 98;
				OAK_ASSERT(NSEqualRects(controller.window.frame, frameBeforeDrag));
			}
			OAK_ASSERT(sawIntermediateWidth);
		}
		wait_for_sidebar_animation(controller);
		OAK_ASSERT(!controller.fileBrowserVisible && !controller.outlineVisible);
		OAK_ASSERT(NSEqualRects(controller.window.frame, frameBeforeDrag));
		OAK_ASSERT(controller.fileBrowserWidth == 250);
		OAK_ASSERT([defaults integerForKey:@"fileBrowserWidth"] == savedSidebarWidth);
		[(NSButton*)[controller valueForKey:@"sidebarButton"] performClick:nil];
		wait_for_sidebar_animation(controller);
		OAK_ASSERT(controller.fileBrowserVisible && controller.outlineVisible);
		if(!NSEqualRects(controller.window.frame, frameBeforeDrag))
			NSLog(@"Sidebar reopen changed the window frame from %@ to %@", NSStringFromRect(frameBeforeDrag), NSStringFromRect(controller.window.frame));
		OAK_ASSERT(NSEqualRects(controller.window.frame, frameBeforeDrag));
		OAK_ASSERT(layout.sidebarOpacity == 1);
		[controller close];
		[DocumentWindowController enableSessionSave];
	});
}

void test_opening_project_file_shows_editor_and_title_with_outline ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		@autoreleasepool
		{
			[NSApplication sharedApplication];
			[DocumentWindowController disableSessionSave];
			NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
			OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil]);
			NSURL* url = [directory URLByAppendingPathComponent:@"open-from-project.txt"];
			OAK_ASSERT([@"Body opened from Project\n" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil]);
			OakDocument* fixture = [OakDocumentController.sharedInstance documentWithPath:url.path];
			fixture.fileType = @"text.plain";
			DocumentWindowController* controller = [[DocumentWindowController alloc] init];
			controller.defaultProjectPath = directory.path;
			controller.fileBrowserWidth = 250;
			controller.fileBrowserVisible = YES;
			controller.outlineVisible = YES;
			[controller.window setContentSize:NSMakeSize(900, 540)];
			[controller.window.contentView layoutSubtreeIfNeeded];
			FileBrowserViewController* browser = [controller valueForKey:@"fileBrowser"];
			browser.fileItem.arrangedChildren = [NSMutableArray arrayWithObject:[FileItem fileItemWithURL:url]];
			[browser.outlineView reloadData];
			OAK_ASSERT(browser.outlineView.numberOfRows == 1);
			[browser.outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
			[NSApp sendAction:browser.outlineView.doubleAction to:browser.outlineView.target from:browser.outlineView];
			NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
			while(!controller.selectedDocument && deadline.timeIntervalSinceNow > 0)
				[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
			[controller.window.contentView layoutSubtreeIfNeeded];
			OakDocumentView* editor = [controller valueForKey:@"documentView"];
			OakTabBarView* tabs = [controller valueForKey:@"tabBarView"];
			OAK_ASSERT([controller.selectedDocument.displayName isEqualToString:url.lastPathComponent]);
			OAK_ASSERT(editor.document == controller.selectedDocument);
			OAK_ASSERT([editor.document.content isEqualToString:@"Body opened from Project\n"]);
			OAK_ASSERT(!editor.hiddenOrHasHiddenAncestor && NSWidth(editor.visibleRect) > 0 && NSHeight(editor.visibleRect) > 0);
			OAK_ASSERT([controller.window.title containsString:url.lastPathComponent]);
			// Capture the whole window. Checking just document state or view frames misses painting over them.
			NSView* content = controller.window.contentView;
			NSBitmapImageRep* bitmap = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
			[content cacheDisplayInRect:content.bounds toBitmapImageRep:bitmap];
			NSRect titleBar = [tabs convertRect:tabs.bounds toView:content];
			NSRect text = [editor.textView convertRect:editor.textView.visibleRect toView:content];
			OAK_ASSERT(region_has_ink(bitmap, content.bounds.size, NSMakeRect(NSMidX(titleBar)-100, NSMinY(titleBar)+3, 200, NSHeight(titleBar)-6)));
			OAK_ASSERT(region_has_ink(bitmap, content.bounds.size, NSMakeRect(NSMinX(text)+3, NSMaxY(text)-32, 200, 32)));
			[controller close];
			[NSFileManager.defaultManager removeItemAtURL:directory error:nil];
			[DocumentWindowController enableSessionSave];
		}
	});
}

void test_closing_last_project_tab_keeps_empty_project_window ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
		OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil]);
		NSURL* file = [directory URLByAppendingPathComponent:@"project-file.txt"];
		OAK_ASSERT([@"project content" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);

		DocumentWindowController* controller = [DocumentWindowController new];
		controller.defaultProjectPath = directory.path;
		controller.fileBrowserVisible = YES;
		[controller showWindow:nil];
		[OakDocumentController.sharedInstance showDocument:[OakDocumentController.sharedInstance documentWithPath:file.path] inProject:controller.identifier bringToFront:YES];
		OAK_ASSERT(controller.documents.count > 0);
		[controller performCloseAllTabs:nil];
		OAK_ASSERT(controller.documents.count == 0);
		OAK_ASSERT(controller.selectedDocument == nil);
		OakDocumentView* emptyEditor = [controller valueForKey:@"documentView"];
		OAK_ASSERT(emptyEditor.document == nil && emptyEditor.hidden);
		OAK_ASSERT(controller.window.firstResponder != controller.textView);
		OAK_ASSERT([controller.projectPath isEqualToString:directory.path]);
		OAK_ASSERT(controller.fileBrowserVisible && controller.window.isVisible);
		OAK_ASSERT([controller.window.title containsString:directory.lastPathComponent]);
		OAK_ASSERT([((EmptyWorkspaceView*)[controller valueForKey:@"emptyStateView"]).heading.stringValue isEqualToString:@"No open tabs"]);
		NSEvent* click = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(80, 80) modifierFlags:0 timestamp:0 windowNumber:controller.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
		OAK_ASSERT(![controller.textView shouldDelayWindowOrderingForEvent:click]);
		OAK_ASSERT(![controller.textView acceptsFirstMouse:click]);
		[controller showWindow:nil];
		OAK_ASSERT(controller.documents.count == 0);
		[OakDocumentController.sharedInstance showDocument:[OakDocumentController.sharedInstance documentWithPath:file.path] inProject:controller.identifier bringToFront:YES];
		OAK_ASSERT(controller.documents.count == 1);
		[controller performCloseTab:nil];
		OAK_ASSERT(controller.documents.count == 0);
		OAK_ASSERT([controller.projectPath isEqualToString:directory.path]);

		NSDictionary* project = ((NSDictionary*(*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(sessionInfoIncludingUntitledDocuments:), NO);
		[controller close];
		DocumentWindowController* restored = [DocumentWindowController new];
		((void(*)(id, SEL, NSDictionary*, BOOL))objc_msgSend)(restored, @selector(setupControllerForProject:skipMissingFiles:), project, NO);
		[restored showWindow:nil];
		OAK_ASSERT(restored.documents.count == 0);
		OAK_ASSERT([restored.projectPath isEqualToString:directory.path]);
		[restored close];
		[NSFileManager.defaultManager removeItemAtURL:directory error:nil];
		[DocumentWindowController enableSessionSave];
	});
}

void test_window_without_project_has_none_state ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		DocumentWindowController* controller = [DocumentWindowController new];
		[controller.window setContentSize:NSMakeSize(900, 540)];
		[controller showWindow:nil];
		OAK_ASSERT(controller.documents.count == 0);
		OAK_ASSERT(controller.projectPath == nil);
		OAK_ASSERT([controller.window.title isEqualToString:@"None"]);
		controller.fileBrowserVisible = YES;
		FileBrowserViewController* emptyBrowser = [controller valueForKey:@"fileBrowser"];
		OakTabBarView* emptyTabs = [controller valueForKey:@"tabBarView"];
		OAK_ASSERT(controller.projectPath == nil && controller.defaultProjectPath == nil);
		OAK_ASSERT(emptyBrowser.URL == nil && emptyBrowser.path == nil);
		NSPopUpButton* emptyFolder = [[emptyBrowser headerView] valueForKey:@"folderPopUpButton"];
		OAK_ASSERT([emptyFolder.title isEqualToString:@"None"]);
		OAK_ASSERT([controller.window.title isEqualToString:@"None"]);
		OAK_ASSERT([emptyTabs.collapsedTitle isEqualToString:@"None"]);
		OAK_ASSERT([[(NSButton*)[[controller valueForKey:@"layoutView"] valueForKey:@"fileBrowserHeader"] title] isEqualToString:@"Project"]);
		NSDictionary* emptyProject = ((NSDictionary*(*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(sessionInfoIncludingUntitledDocuments:), YES);
		OAK_ASSERT(emptyProject[@"projectPath"] == nil && [emptyProject[@"documents"] count] == 0);
		DocumentWindowController* restoredEmpty = [DocumentWindowController new];
		((void(*)(id, SEL, NSDictionary*, BOOL))objc_msgSend)(restoredEmpty, @selector(setupControllerForProject:skipMissingFiles:), emptyProject, NO);
		[restoredEmpty showWindow:nil];
		OAK_ASSERT(restoredEmpty.documents.count == 0 && restoredEmpty.fileBrowserVisible);
		OAK_ASSERT(restoredEmpty.projectPath == nil && restoredEmpty.defaultProjectPath == nil);
		OAK_ASSERT([restoredEmpty.window.title isEqualToString:@"None"]);
		FileBrowserViewController* restoredBrowser = [restoredEmpty valueForKey:@"fileBrowser"];
		OAK_ASSERT([[(NSPopUpButton*)[[restoredBrowser headerView] valueForKey:@"folderPopUpButton"] title] isEqualToString:@"None"]);
		OAK_ASSERT([[(OakTabBarView*)[restoredEmpty valueForKey:@"tabBarView"] collapsedTitle] isEqualToString:@"None"]);
		[restoredEmpty close];
		EmptyWorkspaceView* emptyState = [controller valueForKey:@"emptyStateView"];
		OAK_ASSERT(!emptyState.hidden);
		[controller.window.contentView layoutSubtreeIfNeeded];
		OAK_ASSERT(NSWidth(emptyState.visibleRect) > 0 && NSHeight(emptyState.visibleRect) > 0);
		OAK_ASSERT([emptyState.heading.stringValue isEqualToString:@"No project open"]);
		NSView* content = controller.window.contentView;
		NSBitmapImageRep* bitmap = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
		[content cacheDisplayInRect:content.bounds toBitmapImageRep:bitmap];
		NSView* heading = emptyState.heading;
		OAK_ASSERT(region_has_ink(bitmap, content.bounds.size, [heading convertRect:heading.bounds toView:content]));

		[controller newDocumentInTab:nil];
		OAK_ASSERT(controller.documents.count == 1);
		OAK_ASSERT(emptyState.hidden);
		NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
		while(!controller.selectedDocument && deadline.timeIntervalSinceNow > 0)
			[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		OAK_ASSERT([controller.selectedDocument.displayName hasPrefix:@"untitled"]);
		[controller performCloseTab:nil];
		OAK_ASSERT(controller.documents.count == 0);
		OAK_ASSERT(controller.projectPath == nil);
		OAK_ASSERT([controller.window.title isEqualToString:@"None"]);
		OAK_ASSERT([emptyTabs.collapsedTitle isEqualToString:@"None"]);
		OAK_ASSERT(!emptyState.hidden);
		OAK_ASSERT(controller.window.isVisible);
		[controller close];
		[DocumentWindowController enableSessionSave];
	});
}

void test_opening_project_folder_starts_with_no_tabs ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
		OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil]);
		DocumentWindowController* controller = [DocumentWindowController new];
		controller.fileBrowserVisible = YES;
		controller.outlineVisible = YES;
		[controller showWindow:nil];
		[OakDocumentController.sharedInstance showFileBrowserAtPath:directory.path];
		OAK_ASSERT(controller.documents.count == 0);
		OAK_ASSERT([[controller.projectPath stringByResolvingSymlinksInPath] isEqualToString:[directory.path stringByResolvingSymlinksInPath]]);
		OAK_ASSERT([controller.window.title isEqualToString:directory.lastPathComponent]);
		FileBrowserViewController* projectBrowser = [controller valueForKey:@"fileBrowser"];
		OAK_ASSERT([[(NSPopUpButton*)[[projectBrowser headerView] valueForKey:@"folderPopUpButton"] title] isEqualToString:directory.lastPathComponent]);
		OAK_ASSERT([[(NSButton*)[[controller valueForKey:@"layoutView"] valueForKey:@"fileBrowserHeader"] title] isEqualToString:@"Project"]);
		OAK_ASSERT([((EmptyWorkspaceView*)[controller valueForKey:@"emptyStateView"]).heading.stringValue isEqualToString:@"No open tabs"]);
		[controller close];
		[NSFileManager.defaultManager removeItemAtURL:directory error:nil];
		[DocumentWindowController enableSessionSave];
	});
}

void test_switching_projects_in_same_window_restores_each_projects_tabs ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
		id restorePreference = [defaults objectForKey:kUserDefaultsDisableFolderStateRestore];
		[defaults setBool:NO forKey:kUserDefaultsDisableFolderStateRestore];
		NSURL* root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
		NSURL* first = [root URLByAppendingPathComponent:@"Project A" isDirectory:YES];
		NSURL* second = [root URLByAppendingPathComponent:@"Project B" isDirectory:YES];
		NSFileManager* files = NSFileManager.defaultManager;
		OAK_ASSERT([files createDirectoryAtURL:first withIntermediateDirectories:YES attributes:nil error:nil]);
		OAK_ASSERT([files createDirectoryAtURL:second withIntermediateDirectories:NO attributes:nil error:nil]);
		KVDB* projectDB = [[KVDB alloc] initWithSQLFile:@"Projects.db" inDirectory:root.path];
		Method databaseMethod = class_getClassMethod(DocumentWindowController.class, @selector(sharedProjectStateDB));
		IMP testDatabase = imp_implementationWithBlock(^KVDB*(id){ return projectDB; });
		IMP originalDatabase = method_setImplementation(databaseMethod, testDatabase);
		NSURL* one = [first URLByAppendingPathComponent:@"one.txt"];
		NSURL* two = [first URLByAppendingPathComponent:@"two.txt"];
		NSURL* three = [second URLByAppendingPathComponent:@"three.txt"];
		for(NSURL* file in @[ one, two, three ])
			OAK_ASSERT([@"saved content\n" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);

		DocumentWindowController* controller = [DocumentWindowController new];
		[controller showWindow:nil];
		NSWindow* window = controller.window;
		OakDocumentController* documents = OakDocumentController.sharedInstance;
		[documents showFileBrowserAtPath:first.path];
		auto waitForTab = ^(NSURL* url){
			NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
			while(![controller.selectedDocument.path isEqualToString:url.path] && deadline.timeIntervalSinceNow > 0)
				[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
			OAK_ASSERT([controller.selectedDocument.path isEqualToString:url.path]);
		};
		auto openTab = ^(NSURL* url){
			[documents showDocument:[documents documentWithPath:url.path] inProject:controller.identifier bringToFront:YES];
			waitForTab(url);
		};
		auto switchProject = ^(NSURL* url){
			__block BOOL prompted = NO;
			NSTimer* chooseCurrentWindow = [NSTimer timerWithTimeInterval:0.01 repeats:YES block:^(NSTimer* timer){
				if(NSApp.modalWindow)
				{
					prompted = YES;
					[NSApp stopModalWithCode:NSAlertFirstButtonReturn];
				}
			}];
			[NSRunLoop.currentRunLoop addTimer:chooseCurrentWindow forMode:NSModalPanelRunLoopMode];
			[documents showFileBrowserAtPath:url.path];
			[chooseCurrentWindow invalidate];
			OAK_ASSERT(prompted && controller.window == window && window.isVisible);
		};

		openTab(one);
		openTab(two);

		switchProject(second);
		OAK_ASSERT([controller.defaultProjectPath.lastPathComponent isEqualToString:@"Project B"]);
		OAK_ASSERT(controller.documents.count == 0 && controller.selectedDocument == nil);
		openTab(three);

		switchProject(first);
		waitForTab(two);
		OAK_ASSERT([[controller.documents valueForKey:@"path"] isEqualToArray:(@[ one.path, two.path ])]);
		switchProject(second);
		waitForTab(three);
		OAK_ASSERT(controller.documents.count == 1);

		OakDocument* edited = controller.selectedDocument;
		[edited beginUndoGrouping];
		edited.content = @"unsaved content\n";
		[edited endUndoGrouping];
		OAK_ASSERT(edited.isDocumentEdited);
		__block NSArray* documentsAskedToSave;
		Method warningMethod = class_getInstanceMethod(DocumentWindowController.class, @selector(showCloseWarningUIForDocuments:completionHandler:));
		IMP cancelWarning = imp_implementationWithBlock(^(id, NSArray* documents, void(^completion)(BOOL)){
			documentsAskedToSave = documents;
			completion(NO);
		});
		IMP originalWarning = method_setImplementation(warningMethod, cancelWarning);
		switchProject(first);
		method_setImplementation(warningMethod, originalWarning);
		imp_removeBlock(cancelWarning);
		OAK_ASSERT([controller.defaultProjectPath.lastPathComponent isEqualToString:@"Project B"]);
		OAK_ASSERT(controller.selectedDocument == edited && [edited.content isEqualToString:@"unsaved content\n"]);
		OAK_ASSERT([documentsAskedToSave isEqualToArray:@[ edited ]]);

		[controller close];
		method_setImplementation(databaseMethod, originalDatabase);
		imp_removeBlock(testDatabase);
		[files removeItemAtURL:root error:nil];
		if(restorePreference)
			[defaults setObject:restorePreference forKey:kUserDefaultsDisableFolderStateRestore];
		else
			[defaults removeObjectForKey:kUserDefaultsDisableFolderStateRestore];
		[DocumentWindowController enableSessionSave];
	});
}

void test_restoring_project_into_empty_sidebar_updates_folder ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
		OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil]);
		DocumentWindowController* source = [DocumentWindowController new];
		source.defaultProjectPath = directory.path;
		source.fileBrowserVisible = YES;
		NSDictionary* project = ((NSDictionary*(*)(id, SEL, BOOL))objc_msgSend)(source, @selector(sessionInfoIncludingUntitledDocuments:), YES);
		[source close];

		DocumentWindowController* target = [DocumentWindowController new];
		target.fileBrowserVisible = YES;
		[target showWindow:nil];
		OAK_ASSERT(((FileBrowserViewController*)[target valueForKey:@"fileBrowser"]).path == nil);
		((void(*)(id, SEL, NSDictionary*, BOOL))objc_msgSend)(target, @selector(setupControllerForProject:skipMissingFiles:), project, NO);
		FileBrowserViewController* browser = [target valueForKey:@"fileBrowser"];
		OAK_ASSERT([browser.path isEqualToString:directory.path]);
		OAK_ASSERT([[(NSPopUpButton*)[[browser headerView] valueForKey:@"folderPopUpButton"] title] isEqualToString:directory.lastPathComponent]);
		[target close];
		[NSFileManager.defaultManager removeItemAtURL:directory error:nil];
		[DocumentWindowController enableSessionSave];
	});
}

void test_opening_project_in_window_with_only_browser_location_uses_current_window ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSURL* location = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"Untitled"] isDirectory:YES];
		NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
		OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil]);
		DocumentWindowController* controller = [DocumentWindowController new];
		controller.fileBrowserVisible = YES;
		[controller showWindow:nil];
		FileBrowserViewController* browser = [controller valueForKey:@"fileBrowser"];
		[browser goToURL:location];
		OAK_ASSERT(controller.projectPath == nil && controller.defaultProjectPath == nil);
		OAK_ASSERT(browser.path != nil);
		__block BOOL prompted = NO;
		NSTimer* cancelUnexpectedPrompt = [NSTimer timerWithTimeInterval:0.01 repeats:YES block:^(NSTimer* timer){
			if(NSApp.modalWindow)
			{
				prompted = YES;
				[NSApp stopModalWithCode:NSAlertThirdButtonReturn];
			}
		}];
		[NSRunLoop.currentRunLoop addTimer:cancelUnexpectedPrompt forMode:NSModalPanelRunLoopMode];
		[OakDocumentController.sharedInstance showFileBrowserAtPath:directory.path];
		[cancelUnexpectedPrompt invalidate];
		OAK_ASSERT(!prompted);
		OAK_ASSERT(controller.documents.count == 0 && [[controller.projectPath stringByResolvingSymlinksInPath] isEqualToString:[directory.path stringByResolvingSymlinksInPath]]);
		OAK_ASSERT([[browser.path stringByResolvingSymlinksInPath] isEqualToString:[directory.path stringByResolvingSymlinksInPath]]);
		[controller close];
		[NSFileManager.defaultManager removeItemAtURL:directory error:nil];
		[DocumentWindowController enableSessionSave];
	});
}

void test_close_project_returns_to_none_without_reusing_its_folder ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
		OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil]);
		NSURL* file = [directory URLByAppendingPathComponent:@"project-file.txt"];
		OAK_ASSERT([@"project content" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);

		DocumentWindowController* controller = [DocumentWindowController new];
		controller.defaultProjectPath = directory.path;
		controller.fileBrowserVisible = YES;
		controller.outlineVisible = YES;
		[controller showWindow:nil];
		[OakDocumentController.sharedInstance showDocument:[OakDocumentController.sharedInstance documentWithPath:file.path] inProject:controller.identifier bringToFront:YES];
		OAK_ASSERT(controller.documents.count == 1);
		NSDate* loaded = [NSDate dateWithTimeIntervalSinceNow:3];
		while(!controller.selectedDocument && loaded.timeIntervalSinceNow > 0)
			[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		OAK_ASSERT(controller.selectedDocument != nil);
		[controller performCloseProject:nil];
		OAK_ASSERT(controller.documents.count == 0 && controller.selectedDocument == nil);
		OAK_ASSERT(controller.projectPath == nil && controller.defaultProjectPath == nil);
		OAK_ASSERT(controller.fileBrowserVisible && controller.outlineVisible && controller.window.isVisible);
		FileBrowserViewController* emptyBrowser = [controller valueForKey:@"fileBrowser"];
		OAK_ASSERT(emptyBrowser.path == nil);
		OAK_ASSERT([[(NSPopUpButton*)[[emptyBrowser headerView] valueForKey:@"folderPopUpButton"] title] isEqualToString:@"None"]);
		OAK_ASSERT([[(NSButton*)[[controller valueForKey:@"layoutView"] valueForKey:@"fileBrowserHeader"] title] isEqualToString:@"Project"]);
		OAK_ASSERT([controller.window.title isEqualToString:@"None"]);
		OAK_ASSERT(![(NSView*)[controller valueForKey:@"emptyStateView"] isHidden]);

		[controller newDocumentInTab:nil];
		NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
		while(!controller.selectedDocument && deadline.timeIntervalSinceNow > 0)
			[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		OAK_ASSERT(controller.selectedDocument != nil);
		OAK_ASSERT(controller.projectPath == nil);
		[controller close];
		[NSFileManager.defaultManager removeItemAtURL:directory error:nil];
		[DocumentWindowController enableSessionSave];
	});
}

void test_window_without_documents_is_kept_for_file_browser_or_terminal ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		@autoreleasepool
		{
			[NSApplication sharedApplication];
			[DocumentWindowController disableSessionSave];
			DocumentWindowController* controller = [[DocumentWindowController alloc] init];
			OAK_ASSERT(!controller.keepsWindowWithoutDocuments);

			controller.fileBrowserVisible = YES;
			OAK_ASSERT(controller.keepsWindowWithoutDocuments);
			// Enabling the file browser in a window that was never laid out aborted when the project layout was pinned to a frame.
			OAK_ASSERT(![[controller valueForKey:@"layoutView"] translatesAutoresizingMaskIntoConstraints]);
			controller.fileBrowserVisible = NO;
			OAK_ASSERT(!controller.keepsWindowWithoutDocuments);

			TerminalPanelViewController* panel = [controller valueForKey:@"terminalPanelController"];
			panel.terminalShellPath      = @"/bin/sh";
			panel.terminalShellArguments = @[ ];
			[panel startTerminal];
			if(panel.hasTerminal) // built without the Swift terminal component
			{
				OAK_ASSERT(controller.keepsWindowWithoutDocuments);
				[panel stopTerminal];
				OAK_ASSERT(!controller.keepsWindowWithoutDocuments);
			}
			[DocumentWindowController enableSessionSave];
		}
	});
}

void test_title_bar_controls_navigate_between_files_and_restore_sidebar ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		@autoreleasepool
		{
			[NSApplication sharedApplication];
			RegisterDefaults();
			[DocumentWindowController disableSessionSave];
			NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
			OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil]);
			NSMutableArray<OakDocument*>* files = [NSMutableArray array];
			for(NSString* name in @[ @"first.txt", @"second.txt" ])
			{
				NSURL* url = [directory URLByAppendingPathComponent:name];
				OAK_ASSERT([@"First line\nSecond line\n" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil]);
				OakDocument* file = [OakDocumentController.sharedInstance documentWithPath:url.path];
				file.fileType = @"text.plain";
				[files addObject:file];
			}
			DocumentWindowController* controller = [DocumentWindowController new];
			controller.defaultProjectPath = directory.path;
			void (^waitForDocument)(OakDocument*) = ^(OakDocument* file){
				NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
				while(controller.selectedDocument != file && deadline.timeIntervalSinceNow > 0)
					[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
				OAK_ASSERT(controller.selectedDocument == file);
			};
			[(id<FileBrowserDelegate>)controller fileBrowser:nil openURLs:@[ [NSURL fileURLWithPath:files[1].path], [NSURL fileURLWithPath:files[0].path] ]];
			waitForDocument(files[0]);
			[controller.window setContentSize:NSMakeSize(900, 540)];
			NSView* content = controller.window.contentView;
			[content layoutSubtreeIfNeeded];

			OakTabBarView* bar = [controller valueForKey:@"tabBarView"];
			NSButton* back = bar.leadingButtons[0];
			NSButton* forward = bar.leadingButtons[1];
			NSButton* sidebar = bar.leadingButtons[2];
			NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
			NSInteger previousHeight = [defaults integerForKey:kUserDefaultsTitleBarHeightKey];
			CGFloat automaticHeight = [[controller valueForKey:@"automaticTitleBarHeight"] doubleValue];
			void (^checkTitleBarAlignment)(BOOL) = ^(BOOL hasTabs){
				NSView* frameView = content.superview;
				[frameView layoutSubtreeIfNeeded];
				CGFloat center = NSMidY(bar.bounds);
				BOOL (^centerHitsControl)(NSView*) = ^BOOL(NSView* control){
					NSPoint point = [control convertPoint:NSMakePoint(NSMidX(control.bounds), NSMidY(control.bounds)) toView:frameView.superview];
					return [frameView hitTest:point] == control;
				};
				for(NSNumber* kind in @[ @(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton) ])
				{
					NSButton* button = [controller.window standardWindowButton:(NSWindowButton)kind.unsignedIntegerValue];
					OAK_ASSERT(button);
					// AppKit can snap its native container to a whole point.
					OAK_ASSERT(fabs(NSMidY([bar convertRect:button.bounds fromView:button]) - center) <= 0.5);
					OAK_ASSERT(centerHitsControl(button));
				}
				for(NSButton* button in bar.leadingButtons)
					OAK_ASSERT_EQ(NSMidY(button.frame), center);
				OAK_ASSERT(centerHitsControl(sidebar));
				NSButton* addTab = [bar valueForKey:@"createNewTabButton"];
				OAK_ASSERT(addTab.hidden == !hasTabs);
				if(hasTabs)
				{
					OAK_ASSERT_EQ(NSMidY(addTab.frame), center);
					OAK_ASSERT(centerHitsControl(addTab));
					OAK_ASSERT(bar.countOfVisibleTabs == 2);
					for(NSView* view in bar.subviews)
					{
						if(![view.accessibilityRole isEqualToString:NSAccessibilityRadioButtonRole])
							continue;
						NSTextField* title = [view valueForKey:@"textField"];
						OAK_ASSERT(title.stringValue.length > 0);
						// Auto Layout may snap the label frame to a whole point.
						OAK_ASSERT(fabs(NSMidY([bar convertRect:title.bounds fromView:title]) - center) <= 0.5);
					}
				}
				else
				{
					NSTextField* title = [bar valueForKey:@"collapsedTitleLabel"];
					OAK_ASSERT(title.stringValue.length > 0);
					OAK_ASSERT_EQ(NSMidY(title.frame), center);
				}
			};
			void (^changeTitleBarHeight)(NSInteger, CGFloat) = ^(NSInteger preference, CGFloat expected){
				[defaults setInteger:preference forKey:kUserDefaultsTitleBarHeightKey];
				[(id<OakUserDefaultsObserver>)controller userDefaultsDidChange:nil];
				[content layoutSubtreeIfNeeded];
				OAK_ASSERT(NSHeight(bar.frame) == expected);
			};
			controller.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
			bar.titleBarBackgroundColor = [NSColor colorWithSRGBRed:0.11 green:0.11 blue:0.11 alpha:1];
			for(NSInteger height : { 40, 41 })
			{
				changeTitleBarHeight(height, height);
				NSView* frameView = content.superview;
				NSSize size = frameView.bounds.size;
				NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:2 * size.width pixelsHigh:2 * size.height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
				bitmap.size = size;
				[frameView cacheDisplayInRect:frameView.bounds toBitmapImageRep:bitmap];
				NSRect barRect = [bar convertRect:bar.bounds toView:frameView];
				// Sample the empty part of the bar, clear of the window edge and tab divider.
				NSRect blankArea = NSMakeRect(NSMaxX(barRect) - 45, NSMinY(barRect) + 2, 20, NSHeight(barRect) - 4);
				OAK_ASSERT(!region_has_ink(bitmap, size, blankArea, 0.04));

				// Compare the painted pixels, since button frames can align even when their glyphs don't.
				NSButton* close = [controller.window standardWindowButton:NSWindowCloseButton];
				CGFloat midline = title_bar_ink_center_y(bitmap, size, [frameView convertRect:close.bounds fromView:close]);
				for(NSView* view in [bar.leadingButtons arrayByAddingObject:[bar valueForKey:@"createNewTabButton"]])
				{
					CGFloat iconCenter = title_bar_ink_center_y(bitmap, size, [frameView convertRect:view.bounds fromView:view]);
					OAK_ASSERT(fabs(iconCenter - midline) <= 1);
				}
			}
			changeTitleBarHeight(64, 64);
			checkTitleBarAlignment(YES);
			[controller.window setContentSize:NSMakeSize(880, 570)];
			checkTitleBarAlignment(YES);
			controller.window.title = @"Updated title";
			[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
			checkTitleBarAlignment(YES);
			changeTitleBarHeight(25, 25);
			checkTitleBarAlignment(YES);
			changeTitleBarHeight(24, 24);
			controller.window.title = @"Compact title";
			[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
			checkTitleBarAlignment(YES);
			changeTitleBarHeight(52, 52);
			bar.collapsedTitle = controller.window.title;
			checkTitleBarAlignment(NO);
			changeTitleBarHeight(0, automaticHeight);
			checkTitleBarAlignment(YES);

			NSButton* zoom = [controller.window standardWindowButton:NSWindowZoomButton];
			OAK_ASSERT(NSMinX([back convertRect:back.bounds toView:nil]) > NSMaxX([zoom convertRect:zoom.bounds toView:nil]));
			OAK_ASSERT(NSMaxX(back.frame) <= NSMinX(forward.frame) && NSMaxX(forward.frame) <= NSMinX(sidebar.frame));
			OAK_ASSERT(bar.countOfVisibleTabs == 2);
			for(NSView* view in bar.subviews)
				if([view.accessibilityRole isEqualToString:NSAccessibilityRadioButtonRole])
					OAK_ASSERT(NSMinX(view.frame) >= NSMaxX(sidebar.frame));
			NSPoint sidebarCenter = [content convertPoint:NSMakePoint(NSMidX(sidebar.bounds), NSMidY(sidebar.bounds)) fromView:sidebar];
			OAK_ASSERT([bar hitTest:sidebarCenter] == sidebar);
			OAK_ASSERT(!back.enabled && !forward.enabled);

			NSRect frame = controller.window.frame;
			[sidebar performClick:nil];
			OAK_ASSERT(controller.fileBrowserVisible && controller.outlineVisible);
			ProjectLayoutView* layout = [controller valueForKey:@"layoutView"];
			layout.fileBrowserCollapsed = YES;
			layout.outlineHeight = 180;
			[sidebar performClick:nil];
			wait_for_sidebar_animation(controller);
			OAK_ASSERT(!controller.fileBrowserVisible && !controller.outlineVisible);
			OAK_ASSERT(!layout.fileBrowserView && !layout.outlineView);
			[sidebar performClick:nil];
			OAK_ASSERT(controller.fileBrowserVisible && controller.outlineVisible);
			OAK_ASSERT(layout.fileBrowserCollapsed && layout.outlineHeight == 180);
			OAK_ASSERT(NSEqualRects(frame, controller.window.frame));

			controller.fileBrowserVisible = NO;
			wait_for_sidebar_animation(controller);
			[sidebar performClick:nil];
			if([controller valueForKey:@"sidebarCollapseToken"])
			{
				[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.08]];
				OAK_ASSERT(layout.sidebarOpacity < 1);
				[sidebar performClick:nil];
				OAK_ASSERT(![controller valueForKey:@"sidebarCollapseToken"]);
				wait_for_sidebar_animation(controller);
				OAK_ASSERT(!controller.fileBrowserVisible && controller.outlineVisible);
				OAK_ASSERT(layout.sidebarOpacity == 1);
				[sidebar performClick:nil];
			}
			wait_for_sidebar_animation(controller);
			[sidebar performClick:nil];
			OAK_ASSERT(!controller.fileBrowserVisible && controller.outlineVisible);

			OakTextView* editor = controller.textView;
			editor.selectionString = @"2:3";
			[controller selectNextTab:nil];
			waitForDocument(files[1]);
			editor.selectionString = @"1:4";
			OAK_ASSERT(back.enabled && !forward.enabled);
			[back performClick:nil];
			waitForDocument(files[0]);
			OAK_ASSERT([editor.selectionString isEqualToString:@"2:3"]);
			OAK_ASSERT(!back.enabled && forward.enabled);
			[forward performClick:nil];
			waitForDocument(files[1]);
			OAK_ASSERT([editor.selectionString isEqualToString:@"1:4"]);

			[OakNavigationHistory.sharedInstance goBackFromDocument:nil selection:text::range_t() jump:^(NSString*, text::range_t){}];
			changeTitleBarHeight(previousHeight, NormalizeTitleBarHeight(previousHeight) ?: automaticHeight);
			[controller close];
			[NSFileManager.defaultManager removeItemAtURL:directory error:nil];
			[DocumentWindowController enableSessionSave];
		}
	});
}
