#import <Cocoa/Cocoa.h>
#import "EmptyWorkspaceCommandProbe.h"
#import "../src/DocumentWindowController.h"
#import "../src/EmptyWorkspaceView.h"
#import "../src/GitDiffView.h"
#import "../src/GitGraphTracksView.h"
#import "../src/GitOperationSheet.h"
#import "../src/GitRevisionView.h"
#import "../src/GitWorkspaceViewController.h"
#import "../src/GitWorkspaceData.h"
#import "../src/ProjectLayoutView.h"
#import "../src/SourceControlViewController.h"
#import "../src/TerminalPanelViewController.h"
#import <FileBrowser/FileBrowserOutlineView.h>
#import <FileBrowser/FileBrowserViewController.h>
#import <FileBrowser/FileItem.h>
#import <FileBrowser/FileItemTableCellView.h>
#import <Find/Find.h>
#import <OakFilterList/FileChooser.h>
#import <OakFoundation/OakFoundation.h>
#import <OakFoundation/NSString Additions.h>
#import <OakTextView/OakDocumentView.h>
#import <OakTextView/OakNavigationHistory.h>
#import <OakTextView/OakTextView.h>
#import <OakTabBarView/OakTabBarView.h>
#import <Preferences/Keys.h>
#import <Preferences/ShortcutsPreferences.h>
#import <bundles/query.h>
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
		EmptyWorkspaceCommandProbe* probe = [EmptyWorkspaceCommandProbe new];
		NSMenuItem* projectFind = addShortcut(find.submenu, @"Find in Project…", @"orderFrontFindPanel:", @"F", NSEventModifierFlagCommand | NSEventModifierFlagShift);
		projectFind.tag = FFSearchTargetProject;
		projectFind.target = probe;
		addShortcut([menu itemWithTitle:@"Bundles"].submenu, @"Select Bundle Item…", @"showBundleItemChooser:", @"t", NSEventModifierFlagControl | NSEventModifierFlagCommand);
		addShortcut([menu itemWithTitle:@"TextMate"].submenu, @"Preferences…", @"showPreferences:", @",", NSEventModifierFlagCommand);

		NSApp.mainMenu = menu;
		DocumentWindowController* controller = [DocumentWindowController new];
		[controller.window setContentSize:NSMakeSize(900, 600)];
		[controller showWindow:nil];
		EmptyWorkspaceView* empty = [controller valueForKey:@"emptyStateView"];
		NSView* files = [empty valueForKey:@"files"];
		NSView* tools = [empty valueForKey:@"tools"];
		NSArray<NSButton*>* fileRows = [files valueForKey:@"rows"];
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
		for(NSButton* row in fileRows)
		{
			NSView* name = [row valueForKey:@"name"];
			NSView* keycap = [[row valueForKey:@"shortcut"] superview].superview;
			OAK_ASSERT(!NSIntersectsRect(name.frame, keycap.frame));
			OAK_ASSERT(NSMaxX(keycap.frame) == NSWidth(row.bounds));
			for(NSPoint point : { NSMakePoint(NSMidX(name.frame), NSMidY(name.frame)), NSMakePoint(NSMidX(keycap.frame), NSMidY(keycap.frame)), NSMakePoint(NSMaxX(name.frame) + 6, NSMidY(row.bounds)) })
				OAK_ASSERT([files hitTest:[row convertPoint:point toView:files.superview]] == row);
		}
		[fileRows[3] performClick:nil];
		OAK_ASSERT(probe.invokedItem == nil);
		probe.allowsAction = YES;
		[fileRows[3] performClick:nil];
		OAK_ASSERT(probe.invokedItem == projectFind && probe.invokedItem.tag == FFSearchTargetProject);
		NSMenuItem* open = [menu itemWithTitle:@"File"].submenu.itemArray.firstObject;
		open.target = probe;
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
		fileRows = [files valueForKey:@"rows"];
		OAK_ASSERT(fileRows.count == 6);
		OAK_ASSERT([(NSView*)[[fileRows.firstObject valueForKey:@"shortcut"] superview].superview isHidden]);
		[fileRows.firstObject performClick:nil];
		OAK_ASSERT(probe.invokedItem == open);
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
		[fileRows.lastObject scrollRectToVisible:fileRows.lastObject.bounds];
		[fileRows.lastObject performClick:nil];
		OAK_ASSERT(controller.documents.count == 1 && empty.hidden);
		[controller close];
		NSApp.mainMenu = originalMenu;
		[DocumentWindowController enableSessionSave];
	});
}

void test_open_quickly_search_streams_ranked_paths_and_line_locations ()
{
	__block NSString* directory;
	__block NSString* mainPath;
	__block id originalSource;
	__block FileChooser* search;
	__block NSArray<NSDictionary*>* matches;
	__block BOOL finished = NO;
	NSString* sourceKey = @"fileChooserSourceIndex";
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		NSFileManager* files = NSFileManager.defaultManager;
		directory = [NSTemporaryDirectory().stringByResolvingSymlinksInPath stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
		NSString* source = [directory stringByAppendingPathComponent:@"src"];
		OAK_ASSERT([files createDirectoryAtPath:source withIntermediateDirectories:YES attributes:nil error:nil]);
		mainPath = [source stringByAppendingPathComponent:@"main.go"];
		NSString* otherPath = [directory stringByAppendingPathComponent:@"main.go"];
		OAK_ASSERT([@"package main\n" writeToFile:mainPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
		OAK_ASSERT([@"package demo\n" writeToFile:otherPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);

		originalSource = [NSUserDefaults.standardUserDefaults objectForKey:sourceKey];
		search = [[FileChooser alloc] initWithResultsHandler:^(NSArray<NSDictionary*>* results, BOOL searching){
			matches = results;
			finished = !searching;
		}];
		search.sourceIndex = kFileChooserAllSourceIndex;
		search.filterString = @"src/main.go:42";
		search.path = directory;
		OAK_ASSERT(!finished && search.window == nil);
	});
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
	while(deadline.timeIntervalSinceNow > 0)
	{
		__block BOOL ready;
		dispatch_sync(dispatch_get_main_queue(), ^{ ready = finished; });
		if(ready)
			break;
		[NSThread sleepForTimeInterval:0.01];
	}
	dispatch_sync(dispatch_get_main_queue(), ^{
		OAK_ASSERT(finished);
		OAK_ASSERT_EQ(matches.count, (NSUInteger)1);
		OAK_ASSERT([matches.firstObject[@"item"][@"path"] isEqual:mainPath]);
		OAK_ASSERT([matches.firstObject[@"item"][@"selectionString"] isEqual:@"42"]);
		search.filterString = @"*.go";
		OAK_ASSERT(matches.count == 2);
		[search endSearch];
		[NSUserDefaults.standardUserDefaults setObject:originalSource forKey:sourceKey];
		[NSFileManager.defaultManager removeItemAtPath:directory error:nil];
	});
}

void test_open_quickly_is_attached_to_its_editor_window ()
{
#if HAVE_OAK_SWIFTUI
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
		OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
		DocumentWindowController* controller = [DocumentWindowController new];
		controller.defaultProjectPath = directory;
		[controller showWindow:nil];
		[controller goToFile:nil];
		NSWindow* child = controller.window.childWindows.lastObject;
		OAK_ASSERT(child && [child isKindOfClass:NSPanel.class] && child.isVisible);
		OAK_ASSERT(child.parentWindow == controller.window && (child.styleMask & NSWindowStyleMaskNonactivatingPanel));
		[controller close];
		OAK_ASSERT(!child.isVisible && child.parentWindow == nil);
		[NSFileManager.defaultManager removeItemAtPath:directory error:nil];
		[DocumentWindowController enableSessionSave];
	});
#endif
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

void test_sidebar_collapse_keeps_file_rows_valid_at_narrow_widths ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
		OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil]);
		NSURL* file = [directory URLByAppendingPathComponent:@"project-file.txt"];
		OAK_ASSERT([@"Project file\n" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);

		DocumentWindowController* controller = [DocumentWindowController new];
		controller.defaultProjectPath = directory.path;
		[controller setValue:@YES forKey:@"disableFileBrowserWindowResize"];
		controller.fileBrowserWidth = 250;
		controller.fileBrowserVisible = YES;
		[controller.window setContentSize:NSMakeSize(900, 540)];
		[controller showWindow:nil];
		ProjectLayoutView* layout = [controller valueForKey:@"layoutView"];
		FileBrowserViewController* browser = [controller valueForKey:@"fileBrowser"];
		FileBrowserOutlineView* files = (FileBrowserOutlineView*)browser.outlineView;
		browser.fileItem.arrangedChildren = [NSMutableArray arrayWithObject:[FileItem fileItemWithURL:file]];
		[files reloadData];
		OAK_ASSERT(files.numberOfRows == 1);
		NSButton* toggle = [controller valueForKey:@"sidebarButton"];
		NSRect originalFrame = controller.window.frame;
		for(BOOL onRight : { NO, YES })
		{
			layout.fileBrowserOnRight = onRight;
			[layout setSidebarTransitionWidth:16 opacity:0.1];
			[controller.window.contentView layoutSubtreeIfNeeded];
			CGFloat originalIndentation = files.rootIndentation;
			CGFloat availableWidth = NSWidth([files frameOfCellAtColumn:0 row:0]);
			OAK_ASSERT(availableWidth >= 16);
			files.rootIndentation += availableWidth - 16;
			[files reloadData];
			FileItemTableCellView* cell = (FileItemTableCellView*)[files viewAtColumn:0 row:0 makeIfNecessary:YES];
			OAK_ASSERT(cell && fabs(NSWidth(cell.frame) - 16) < 0.5);
			[cell layoutSubtreeIfNeeded];
			OAK_ASSERT(fabs(layout.visibleSidebarWidth - 16) < 0.5);
			OAK_ASSERT(NSWidth(cell.openButton.frame) == 16);
			OAK_ASSERT(cell.clipsToBounds);
			files.rootIndentation = originalIndentation;
			[files reloadData];
			[layout setSidebarTransitionWidth:250 opacity:1];
			[controller.window.contentView layoutSubtreeIfNeeded];
			[toggle performClick:nil];
			wait_for_sidebar_animation(controller);
			OAK_ASSERT(!controller.fileBrowserVisible);
			[toggle performClick:nil];
			wait_for_sidebar_animation(controller);
			OAK_ASSERT(controller.fileBrowserVisible && layout.sidebarOpacity == 1);
			OAK_ASSERT(NSEqualRects(controller.window.frame, originalFrame));
		}
		[controller close];
		[NSFileManager.defaultManager removeItemAtURL:directory error:nil];
		[DocumentWindowController enableSessionSave];
	});
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

void test_source_control_projects_and_outline_are_independent_sidebar_sections ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		DocumentWindowController* controller = [DocumentWindowController new];
		controller.fileBrowserVisible = YES;
		[controller toggleOutline:nil];
		[controller.window setContentSize:NSMakeSize(850, 510)];
		ProjectLayoutView* layout = [controller valueForKey:@"layoutView"];
		NSView* project = layout.fileBrowserView;
		NSView* projectActions = layout.fileBrowserActionsView;
		NSView* outline = layout.outlineView;
		NSRect frame = controller.window.frame;
		[controller toggleSourceControl:nil];
		[controller.window.contentView layoutSubtreeIfNeeded];
		NSView* sourceControl = layout.sourceControlView;
		NSView* sidebar = project.superview;
		OAK_ASSERT(controller.fileBrowserVisible && controller.outlineVisible);
		OAK_ASSERT(sidebar && outline.superview == sidebar && sourceControl.superview == sidebar && projectActions.superview == sidebar);
		OAK_ASSERT(NSMinY(project.frame) > NSMaxY(sourceControl.frame) && NSMinY(sourceControl.frame) > NSMaxY(outline.frame));
		OAK_ASSERT(NSWidth(sourceControl.frame) == NSWidth(project.frame) && NSHeight(sourceControl.frame) > 120);
		OAK_ASSERT(NSEqualRects(controller.window.frame, frame));

		NSButton* sourceHeader = [layout valueForKey:@"sourceControlHeader"];
		[sourceHeader performClick:nil];
		OAK_ASSERT(layout.sourceControlCollapsed && !sourceControl.superview);
		OAK_ASSERT(project.superview == sidebar && outline.superview == sidebar && !layout.fileBrowserCollapsed);
		NSDictionary* state = ((NSDictionary*(*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(sessionInfoIncludingUntitledDocuments:), YES);
		DocumentWindowController* restored = [DocumentWindowController new];
		((void(*)(id, SEL, NSDictionary*, BOOL))objc_msgSend)(restored, @selector(setupControllerForProject:skipMissingFiles:), state, NO);
		ProjectLayoutView* restoredLayout = [restored valueForKey:@"layoutView"];
		OAK_ASSERT(restoredLayout.fileBrowserView.superview && restoredLayout.outlineView.superview);
		OAK_ASSERT(restoredLayout.sourceControlView && !restoredLayout.sourceControlView.superview && restoredLayout.sourceControlCollapsed);
		[restored close];

		[controller toggleSourceControl:nil];
		OAK_ASSERT(!layout.sourceControlCollapsed && sourceControl.superview == sidebar);
		[controller toggleSourceControl:nil];
		OAK_ASSERT(!layout.sourceControlView && project.superview == sidebar && outline.superview == sidebar);
		[controller toggleOutline:nil];
		[controller toggleSourceControl:nil];
		[controller toggleFileBrowser:nil];
		OAK_ASSERT(!layout.fileBrowserView && sourceControl.superview == sidebar);
		[controller toggleFileBrowser:nil];
		OAK_ASSERT(layout.fileBrowserView == project && sourceControl.superview == sidebar);
		OAK_ASSERT(NSEqualRects(controller.window.frame, frame));
		[controller close];
		[DocumentWindowController enableSessionSave];
	});
}

void test_source_control_bulk_stage_and_expand_description ()
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	NSFileManager* files = NSFileManager.defaultManager;
	OAK_ASSERT([files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
	NSDictionary* init = GitRepositoryCommand(directory, @[@"init", @"--quiet"], YES);
	OAK_ASSERT(!init[@"error"] && [init[@"status"] intValue] == 0);
	for(NSString* name in @[@"one.txt", @"two.txt"])
		OAK_ASSERT([name writeToFile:[directory stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:nil]);

	__block SourceControlViewController* controller;
	__block NSWindow* window;
	__block NSButton* bulk;
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		controller = [SourceControlViewController new];
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 250, 360) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
		window.releasedWhenClosed = NO;
		window.contentView = controller.view;
		controller.directory = directory;
		controller.panelVisible = YES;
		bulk = [controller valueForKey:@"bulkStage"];
	});
	void (^waitForAction)(NSString*) = ^(NSString* title){
		NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
		while(deadline.timeIntervalSinceNow > 0) {
			__block BOOL ready;
			dispatch_sync(dispatch_get_main_queue(), ^{ ready = bulk.enabled && [bulk.title isEqual:title]; });
			if(ready) return;
			[NSThread sleepForTimeInterval:0.01];
		}
		OAK_ASSERT(false && "Bulk stage action did not update");
	};
	waitForAction(@"Stage All");
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSView* description = [controller valueForKey:@"descriptionEditor"];
		NSTableView* table = [controller valueForKey:@"table"];
		[window.contentView layoutSubtreeIfNeeded];
		CGFloat collapsedListHeight = NSHeight(table.enclosingScrollView.frame);
		OAK_ASSERT(description.hidden);
		OAK_ASSERT([window makeFirstResponder:[controller valueForKey:@"message"]]);
		[window.contentView layoutSubtreeIfNeeded];
		OAK_ASSERT(!description.hidden && NSHeight(table.enclosingScrollView.frame) < collapsedListHeight);
		[bulk performClick:nil];
	});
	waitForAction(@"Unstage All");
	dispatch_sync(dispatch_get_main_queue(), ^{ [bulk performClick:nil]; });
	waitForAction(@"Stage All");
	NSArray* changes = GitRepositoryChanges(ProjectChangesSnapshot(directory, @{}, YES));
	OAK_ASSERT(changes.count == 2);
	for(NSDictionary* change in changes) OAK_ASSERT([change[@"code"] isEqual:@"?"]);
	OAK_ASSERT([[@"one.txt" dataUsingEncoding:NSUTF8StringEncoding] isEqual:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"one.txt"]]]);
	dispatch_sync(dispatch_get_main_queue(), ^{
		controller.panelVisible = NO;
		[window close];
		bulk = nil;
		window = nil;
		controller = nil;
	});
	OAK_ASSERT([files removeItemAtPath:directory error:nil]);
}

void test_git_diff_marks_missing_newlines_on_both_sides ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		GitDiffView* diff = [[GitDiffView alloc] initWithFrame:NSMakeRect(0, 0, 748, 420)];
		diff.syntaxPath = @"package.json.md5";
		NSString* removed = @"73aa0c3d5a6d202703011ba04e19f184";
		NSString* added = @"9f29c7013975ecda6dd9f7e14da12e96";
		NSString* source = [NSString stringWithFormat:@"diff --git a/package.json.md5 b/package.json.md5\n@@ -1 +1 @@\n-%@\n\\ No newline at end of file\n+%@\n\\ No newline at end of file\n", removed, added];
		[diff showTitle:diff.syntaxPath subtitle:@"" patch:@{@"text": source}];
		NSTextView* text = [diff valueForKey:@"textView"];
		NSArray<NSString*>* lines = [text.string componentsSeparatedByString:@"\n"];
		OAK_ASSERT(([lines isEqual:@[@"1 chunk, 1 insertion, 1 deletion", @"@@ -1 +1 @@", removed, @" No newline at end of file", added, @" No newline at end of file"]]));
		NSUInteger oldIndex = [text.string rangeOfString:removed].location;
		NSUInteger newIndex = [text.string rangeOfString:added].location;
		NSDictionary* old = [text.textStorage attribute:@"TextMateDiffLine" atIndex:oldIndex effectiveRange:NULL];
		NSDictionary* newLine = [text.textStorage attribute:@"TextMateDiffLine" atIndex:newIndex effectiveRange:NULL];
		NSDictionary* note = [text.textStorage attribute:@"TextMateDiffLine" atIndex:oldIndex+removed.length+1 effectiveRange:NULL];
		OAK_ASSERT([old[@"old"] isEqual:@"−1"] && [old[@"new"] isEqual:@"0"]);
		OAK_ASSERT([newLine[@"old"] isEqual:@""] && [newLine[@"new"] isEqual:@"+1"]);
		OAK_ASSERT([note[@"old"] isEqual:@""] && [note[@"new"] isEqual:@""]);
		OAK_ASSERT(GitDiffHunks(source).count == 1 && [GitDiffHunks(source).firstObject containsString:@"\\ No newline at end of file"]);
	});
}

void test_empty_editor_git_workspace_and_terminal_share_the_selected_theme ()
{
	auto makeTheme = [](std::string const& background, std::string const& foreground){
		auto item = std::make_shared<bundles::item_t>(oak::uuid_t().generate(), bundles::item_ptr(), bundles::kItemTypeTheme);
		item->set_plist({ { "settings", plist::array_t{ plist::dictionary_t{ { "settings", plist::dictionary_t{
			{ "background", background }, { "foreground", foreground }
		} } } } } });
		return item;
	};
	auto light = makeTheme("#F6F0DE", "#221F19");
	auto dark = makeTheme("#312838", "#EEEAF5");
	NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
	NSArray<NSString*>* keys = @[ @"themeAppearance", @"universalThemeUUID", @"darkModeThemeUUID" ];
	NSMutableDictionary* previous = [NSMutableDictionary dictionary];
	NSString* lightUUID = [NSString stringWithCxxString:light->uuid()];
	__block DocumentWindowController* controller;
	__block GitWorkspaceViewController* git;
	void (^checkTerminalTheme)(NSColor*) = ^(NSColor* body){
#if HAVE_OAK_SWIFTUI
		TerminalPanelViewController* panel = [controller valueForKey:@"terminalPanelController"];
		NSView* terminalContent = [panel valueForKey:@"panelView"];
		OAK_ASSERT(panel.hasTerminal && panel.terminalSessionIdentifiers.count == 1);
		OAK_ASSERT(terminalContent.layer.backgroundColor && CGColorEqualToColor(terminalContent.layer.backgroundColor, body.CGColor));
#endif
	};
	void (^checkTheme)(bundles::item_ptr const&) = ^(bundles::item_ptr const& item){
		theme_ptr theme = parse_theme(item);
		NSColor* body = [NSColor colorWithCGColor:theme->background()];
		NSColor* gutter = [NSColor colorWithCGColor:theme->gutter_styles().background];
		EmptyWorkspaceView* empty = [controller valueForKey:@"emptyStateView"];
		OakTabBarView* bar = [controller valueForKey:@"tabBarView"];
		OAK_ASSERT(!controller.selectedDocument && [empty.heading.stringValue isEqual:@"No project open"]);
		OAK_ASSERT([controller.window.backgroundColor isEqual:body]);
		OAK_ASSERT([bar.titleBarBackgroundColor isEqual:body]);
		OAK_ASSERT(empty.drawsBackground && [empty.backgroundColor isEqual:body]);
		OAK_ASSERT([git.editorTheme.syntaxThemeUUID isEqual:[NSString stringWithCxxString:item->uuid()]]);
		OAK_ASSERT([[git.view valueForKey:@"fillColor"] isEqual:body]);
		OAK_ASSERT([[[git valueForKey:@"navigationSurface"] valueForKey:@"fillColor"] isEqual:gutter]);
		OAK_ASSERT([empty.appearance.name isEqual:git.view.appearance.name]);
		checkTerminalTheme(body);
	};
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		bundles::add_item(light);
		bundles::add_item(dark);
		for(NSString* key in keys)
			previous[key] = [defaults objectForKey:key];
		[defaults setObject:lightUUID forKey:@"universalThemeUUID"];
		[defaults setObject:[NSString stringWithCxxString:dark->uuid()] forKey:@"darkModeThemeUUID"];
		[defaults setObject:@"dark" forKey:@"themeAppearance"];

		controller = [DocumentWindowController new];
		NSSegmentedControl* modes = [controller valueForKey:@"workspaceModeControl"];
		EmptyWorkspaceView* empty = [controller valueForKey:@"emptyStateView"];
		OAK_ASSERT(!empty.isHiddenOrHasHiddenAncestor);
		OAK_ASSERT([empty.backgroundColor isEqual:[NSColor colorWithCGColor:parse_theme(dark)->background()]]);
#if HAVE_OAK_SWIFTUI
		TerminalPanelViewController* panel = [controller valueForKey:@"terminalPanelController"];
		panel.terminalShellPath = @"/bin/sh";
		panel.terminalShellArguments = @[];
		((void(*)(id, SEL, id))objc_msgSend)(controller, @selector(toggleTerminalPanel:), nil);
		checkTerminalTheme(empty.backgroundColor);
#endif
		modes.selectedSegment = 1;
		[modes sendAction:modes.action to:modes.target];
		git = [controller valueForKey:@"gitWorkspaceController"];
		checkTheme(dark);

		[defaults setObject:@"light" forKey:@"themeAppearance"];
		[NSNotificationCenter.defaultCenter postNotificationName:NSUserDefaultsDidChangeNotification object:defaults];
	});
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:2];
	while(deadline.timeIntervalSinceNow > 0)
	{
		__block BOOL updated;
		dispatch_sync(dispatch_get_main_queue(), ^{ updated = [git.editorTheme.syntaxThemeUUID isEqual:lightUUID]; });
		if(updated)
			break;
		[NSThread sleepForTimeInterval:0.01];
	}
	dispatch_sync(dispatch_get_main_queue(), ^{
		checkTheme(light);
		NSSegmentedControl* modes = [controller valueForKey:@"workspaceModeControl"];
		modes.selectedSegment = 0;
		[modes sendAction:modes.action to:modes.target];
		EmptyWorkspaceView* empty = [controller valueForKey:@"emptyStateView"];
		OAK_ASSERT(!empty.isHiddenOrHasHiddenAncestor);
		checkTheme(light);
		[controller close];
		for(NSString* key in keys)
		{
			if(previous[key]) [defaults setObject:previous[key] forKey:key];
			else [defaults removeObjectForKey:key];
		}
		bundles::remove_item(light);
		bundles::remove_item(dark);
	});
}

void test_git_workspace_updates_surfaces_and_open_diff_with_editor_theme ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		GitWorkspaceViewController* workspace = [GitWorkspaceViewController new];
		GitEditorTheme* dark = [GitEditorTheme new];
		dark.background = [NSColor colorWithSRGBRed:0.12 green:0.16 blue:0.22 alpha:1];
		dark.gutterBackground = [NSColor colorWithSRGBRed:0.16 green:0.20 blue:0.26 alpha:1];
		dark.foreground = NSColor.whiteColor;
		dark.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
		workspace.editorTheme = dark;
		NSView* content = workspace.view;
		NSView* navigation = [workspace valueForKey:@"navigationSurface"];
		NSView* pages = [workspace valueForKey:@"workspacePages"];
		SourceControlViewController* workingCopy = [workspace valueForKey:@"workingCopy"];
		GitDiffView* diff = [workspace valueForKey:@"diff"];
		GitRevisionView* revision = [workspace valueForKey:@"revisionInspector"];
		OAK_ASSERT([[content valueForKey:@"fillColor"] isEqual:dark.background]);
		OAK_ASSERT([[navigation valueForKey:@"fillColor"] isEqual:dark.gutterBackground]);
		OAK_ASSERT(diff.editorTheme == dark && revision.editorTheme == dark && [content.appearance.name isEqual:NSAppearanceNameDarkAqua]);

		[diff showTitle:@"demo.txt" subtitle:@"" patch:@{ @"text": @"@@ -1,2 +1,2 @@\n context\n-old\n+new\n" }];
		NSTextView* text = [diff valueForKey:@"textView"];
		NSRange context = [text.string rangeOfString:@"context"];
		OAK_ASSERT(context.location != NSNotFound);
		OAK_ASSERT([[text.textStorage attribute:NSForegroundColorAttributeName atIndex:context.location effectiveRange:nil] isEqual:dark.foreground]);
		text.selectedRange = context;

		GitEditorTheme* light = [GitEditorTheme new];
		light.background = [NSColor colorWithSRGBRed:0.97 green:0.94 blue:0.87 alpha:1];
		light.gutterBackground = [NSColor colorWithSRGBRed:0.92 green:0.89 blue:0.82 alpha:1];
		light.foreground = NSColor.blackColor;
		light.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
		workspace.editorTheme = light;
		OAK_ASSERT([[content valueForKey:@"fillColor"] isEqual:light.background] && [[pages valueForKey:@"fillColor"] isEqual:light.background]);
		OAK_ASSERT([[navigation valueForKey:@"fillColor"] isEqual:light.gutterBackground] && [workingCopy.themeBackgroundColor isEqual:light.background]);
		OAK_ASSERT([[[workspace.titleBarItems valueForKey:@"editorTheme"] background] isEqual:light.background]);
		OAK_ASSERT(diff.editorTheme == light && revision.editorTheme == light && [diff.appearance.name isEqual:NSAppearanceNameAqua]);
		OAK_ASSERT([[text.textStorage attribute:NSForegroundColorAttributeName atIndex:context.location effectiveRange:nil] isEqual:light.foreground]);
		OAK_ASSERT(NSEqualRanges(text.selectedRange, context));
		NSUInteger oldIndex = [text.string rangeOfString:@"old"].location, newIndex = [text.string rangeOfString:@"new"].location;
		NSDictionary* removed = [text.textStorage attribute:@"TextMateDiffLine" atIndex:oldIndex effectiveRange:nil];
		NSDictionary* added = [text.textStorage attribute:@"TextMateDiffLine" atIndex:newIndex effectiveRange:nil];
		OAK_ASSERT([removed[@"kind"] unsignedShortValue] == '-' && [added[@"kind"] unsignedShortValue] == '+');
	});
}

void test_git_operation_sheet_keeps_fields_fixed_when_options_expand ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		NSWindow* parent = [[NSWindow alloc] initWithContentRect:NSMakeRect(50, 50, 780, 620) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
		parent.releasedWhenClosed = NO;
		[parent orderFront:nil];
		GitOperationSheet* form = [[GitOperationSheet alloc] initWithTitle:@"Fetch" detail:@"Fetch changes from the selected remote." helpTopic:@"fetch"];
		NSPopUpButton* remote = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
		[remote addItemWithTitle:@"origin"];
		[form addField:remote label:@"Remote:"];
		NSButton* all = [form addOption:@"Fetch All Remotes" detail:nil];
		all.state = NSControlStateValueOn;
		[form setControls:@[remote] enabledWhen:all checked:NO];
		[form beginOptions];
		NSButton* prune = [form addOption:@"Prune Obsolete Remote Branches" detail:@"Removes obsolete branches."];
		[form presentInWindow:parent firstResponder:all accept:^{ OAK_ASSERT(false && "Cancel should not confirm the operation"); }];
		NSWindow* panel = form.window;
		OAK_ASSERT(panel && panel.contentView == form && panel.titleVisibility == NSWindowTitleHidden);
		OAK_ASSERT(!remote.enabled && prune.isHiddenOrHasHiddenAncestor);
		[all performClick:nil];
		OAK_ASSERT(remote.enabled);
		NSRect remoteFrame = remote.frame;
		CGFloat collapsedHeight = NSHeight(form.frame);
		NSButton* options = nil;
		for(NSView* child in form.subviews)
			if([child isKindOfClass:NSButton.class] && [((NSButton*)child).title isEqual:@"Options"]) options = (NSButton*)child;
		[options performClick:nil];
		OAK_ASSERT(!prune.isHiddenOrHasHiddenAncestor && NSEqualRects(remoteFrame, remote.frame));
		OAK_ASSERT(NSHeight(form.frame) > collapsedHeight);
		[options performClick:nil];
		OAK_ASSERT(prune.isHiddenOrHasHiddenAncestor && NSHeight(form.frame) == collapsedHeight);
		if([parent.sheets containsObject:panel]) [parent endSheet:panel returnCode:NSModalResponseCancel];
		else [panel orderOut:nil];
		[parent close];
	});
}

void test_git_mode_switch_preserves_editor_and_shows_working_and_history_diffs ()
{
	NSFileManager* files = NSFileManager.defaultManager;
	NSString* fixture = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	NSString* directory = [fixture stringByAppendingPathComponent:@"Example Project"];
	OAK_ASSERT([files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
	NSString* tracked = [directory stringByAppendingPathComponent:@"README.md"];
	void (^git)(NSArray*) = ^(NSArray* args){
		NSArray* config = @[@"-c", @"user.name=Git Workspace Tests", @"-c", @"user.email=git@example.invalid", @"-c", @"commit.gpgsign=false", @"-c", @"core.hooksPath=/dev/null"];
		NSDictionary* result = GitRepositoryCommand(directory, [config arrayByAddingObjectsFromArray:args], YES);
		OAK_ASSERT(!result[@"error"] && [result[@"status"] intValue] == 0);
	};
	git(@[@"init", @"-qb", @"main"]);
	git(@[@"config", @"--local", @"user.name", @"Git Workspace Tests"]);
	git(@[@"config", @"--local", @"user.email", @"git@example.invalid"]);
	git(@[@"config", @"--local", @"commit.template", @"/dev/null"]);
	NSMutableArray<NSString*>* initialLines = [NSMutableArray arrayWithObject:@"Initial content"];
	for(NSUInteger line = 2; line < 49; ++line) [initialLines addObject:[NSString stringWithFormat:@"Line %lu remains unchanged.", (unsigned long)line]];
	BOOL (^writeReadme)(NSArray<NSString*>*) = ^BOOL(NSArray<NSString*>* lines){
		return [[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] writeToFile:tracked atomically:YES encoding:NSUTF8StringEncoding error:nil];
	};
	OAK_ASSERT(writeReadme(initialLines));
	git(@[@"add", @"README.md"]);
	NSMutableString* messageBody = [NSMutableString stringWithString:@"Original fixture body\n\n"];
	for(NSUInteger line = 1; line <= 36; ++line)
		[messageBody appendFormat:@"Line %lu explains why the source tree changed.\n", (unsigned long)line];
	git(@[@"commit", @"--date=2025-10-15T12:00:00+00:00", @"-qm", @"Initial commit", @"-m", messageBody]);
	git(@[@"commit", @"--date=2025-11-12T12:00:00+00:00", @"--allow-empty", @"-qm", @"November update"]);
	git(@[@"commit", @"--date=2025-11-13T12:00:00+00:00", @"--allow-empty", @"-qm", @"Latest update"]);
	git(@[@"branch", @"topic/ui"]);
	git(@[@"tag", @"v1"]);
	git(@[@"update-ref", @"refs/remotes/origin/main", @"HEAD"]);
	git(@[@"config", @"remote.origin.url", @"."]);
	git(@[@"config", @"remote.origin.fetch", @"+refs/heads/*:refs/remotes/origin/*"]);
	git(@[@"branch", @"--set-upstream-to=origin/main", @"main"]);
	NSMutableArray<NSString*>* edited = [initialLines mutableCopy];
	edited[0] = @"Older draft";
	OAK_ASSERT(writeReadme(edited));
	git(@[@"stash", @"push", @"-qm", @"Older draft"]);
	edited[0] = @"Stashed draft";
	OAK_ASSERT(writeReadme(edited));
	git(@[@"stash", @"push", @"-qm", @"Stashed draft"]);
	edited[0] = @"Working copy edit";
	edited[3] = @"Line 4  remains unchanged.";
	edited[25] = @"Line 26 has a second edit.";
	OAK_ASSERT(writeReadme(edited));
	OAK_ASSERT([files createDirectoryAtPath:[directory stringByAppendingPathComponent:@"notes"] withIntermediateDirectories:NO attributes:nil error:nil]);
	OAK_ASSERT([@"draft\n" writeToFile:[directory stringByAppendingPathComponent:@"notes/draft.md"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);

	__block DocumentWindowController* controller;
	__block GitWorkspaceViewController* workspace;
	__block NSSegmentedControl* modes;
	__block OakDocument* document;
	__block OakTextView* editor;
	__block NSTableView* changes;
	__block NSOutlineView* navigation;
	__block NSTextView* patch;
	void (^navigate)(NSString*) = ^(NSString* destination){
		for(NSInteger row = 0; row < navigation.numberOfRows; ++row) {
			if([[[navigation itemAtRow:row] objectForKey:@"id"] isEqual:destination]) {
				[navigation selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
				return;
			}
		}
		OAK_ASSERT(false && "Git workspace destination is missing");
	};
	void (^checkGitTitleBar)(BOOL) = ^(BOOL windowButtonsVisible){
		NSWindow* window = controller.window;
		NSView* content = window.contentView;
		NSView* chrome = content.superview;
		[chrome layoutSubtreeIfNeeded];
		OakTabBarView* bar = (OakTabBarView*)modes.superview;
		NSRect barFrame = [bar convertRect:bar.bounds toView:content];
		NSView* items = workspace.titleBarItems;
		NSView* repositoryItems = [items valueForKey:@"repositoryItems"];
		NSSplitView* split = [workspace valueForKey:@"split"];
		NSSearchField* search = [workspace valueForKey:@"search"];
		OAK_ASSERT(NSWidth(repositoryItems.bounds) > 0);
		OAK_ASSERT(items.superview == bar && NSMinX(repositoryItems.frame) > NSMaxX(modes.frame));
		OAK_ASSERT(NSMinX(repositoryItems.frame) == NSMaxX(split.subviews.firstObject.frame));
		OAK_ASSERT(bar.countOfVisibleTabs == 0 && NSHeight(modes.frame) >= 16 && !modes.isHiddenOrHasHiddenAncestor);
		NSRect searchFrame = [search convertRect:search.bounds toView:content];
		OAK_ASSERT(NSContainsRect(barFrame, searchFrame) && NSWidth(searchFrame) >= 105);
		OAK_ASSERT(fabs(NSMidY(searchFrame) - NSMidY(barFrame)) <= 0.5);
		OAK_ASSERT(NSMaxY([split convertRect:split.bounds toView:content]) == NSMinY(barFrame));
		if(windowButtonsVisible)
		{
			NSButton* zoom = [window standardWindowButton:NSWindowZoomButton];
			NSRect zoomFrame = [zoom convertRect:zoom.bounds toView:content];
			OAK_ASSERT(NSMaxX(zoomFrame) < NSMinX(modes.frame) && fabs(NSMidY(zoomFrame) - NSMidY(barFrame)) <= 0.5);
			for(NSView* control in @[modes, search])
			{
				NSPoint point = [control convertPoint:NSMakePoint(NSMidX(control.bounds), NSMidY(control.bounds)) toView:chrome.superview];
				OAK_ASSERT([[chrome hitTest:point] isDescendantOf:control]);
			}
		}
	};
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		controller = [DocumentWindowController new];
		controller.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
		controller.defaultProjectPath = directory;
		[controller.window setContentSize:NSMakeSize(900, 540)];
		editor = [controller valueForKey:@"textView"];
		modes = [controller valueForKey:@"workspaceModeControl"];
		OAK_ASSERT(modes.selectedSegment == 0 && modes.window == controller.window);
		[(id<FileBrowserDelegate>)controller fileBrowser:nil openURLs:@[[NSURL fileURLWithPath:tracked]]];
	});
	void (^waitForUI)(BOOL(^)(void)) = ^(BOOL(^condition)(void)){
		NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
		while(deadline.timeIntervalSinceNow > 0) {
			__block BOOL ready;
			dispatch_sync(dispatch_get_main_queue(), ^{ ready = condition(); });
			if(ready) return;
			[NSThread sleepForTimeInterval:0.01];
		}
		OAK_ASSERT(false && "Git mode did not update");
	};
	waitForUI(^BOOL{ return [controller.selectedDocument.path isEqual:tracked]; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		document = controller.selectedDocument;
		editor.selectionString = @"1:4";
		[controller.window.contentView layoutSubtreeIfNeeded];
		NSWindow* window = controller.window;
		NSRect windowFrame = window.frame;
		NSRect controlFrame = modes.frame;
		modes.selectedSegment = 1;
		[NSAnimationContext runAnimationGroup:^(NSAnimationContext* context){
			context.allowsImplicitAnimation = YES;
			[modes sendAction:modes.action to:modes.target];
		} completionHandler:nil];
		workspace = [controller valueForKey:@"gitWorkspaceController"];
		OAK_ASSERT(workspace.isActive && workspace.view.window == window && controller.window == window);
		NSMenuItem* wrap = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(toggleSoftWrap:) keyEquivalent:@"w"];
		OAK_ASSERT([(id<NSMenuItemValidation>)controller validateMenuItem:wrap] && workspace.softWrap == editor.softWrap);
		OAK_ASSERT([wrap.title isEqual:editor.softWrap ? @"Disable Soft Wrap" : @"Enable Soft Wrap"]);
		OAK_ASSERT(NSEqualRects(window.frame, windowFrame) && NSMinX(modes.frame) == NSMinX(controlFrame) && NSWidth(controlFrame) > 60);
		checkGitTitleBar(YES);
		OAK_ASSERT(editor.isHiddenOrHasHiddenAncestor && !workspace.view.hidden);
		navigation = [workspace valueForKey:@"navigation"];
		changes = [[workspace valueForKey:@"workingCopy"] valueForKey:@"table"];
		patch = [[workspace valueForKey:@"diff"] valueForKey:@"textView"];
	});
	waitForUI(^BOOL{ return changes.numberOfRows == 2 && navigation.numberOfRows >= 10 && [[workspace valueForKey:@"stashShortcut"] title].integerValue == 2; });
	NSMenu* (^rightClickRow)(NSTableView*, NSInteger) = ^NSMenu*(NSTableView* table, NSInteger row){
		NSRect rect = [table rectOfRow:row];
		NSPoint point = [table convertPoint:NSMakePoint(NSMidX(rect), NSMidY(rect)) toView:nil];
		NSEvent* event = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:point modifierFlags:0 timestamp:0
			windowNumber:table.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
		NSMenu* menu = [table menuForEvent:event];
		[menu.delegate menuNeedsUpdate:menu];
		return menu;
	};
	NSMenu* (^rightClickWorkingCopyRow)(NSInteger) = ^NSMenu*(NSInteger row){ return rightClickRow(changes, row); };
	dispatch_sync(dispatch_get_main_queue(), ^{
		[controller.window.contentView layoutSubtreeIfNeeded];
		[changes selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)] byExtendingSelection:NO];
		NSMenu* menu = rightClickWorkingCopyRow(1);
		OAK_ASSERT(changes.numberOfSelectedRows == 2);
		OAK_ASSERT([[[workspace valueForKey:@"emptyTitle"] stringValue] isEqual:@"Multiple files selected"]);
		OAK_ASSERT([menu itemWithTitle:@"Stage 2 Items"].enabled && ![menu itemWithTitle:@"Unstage 2 Items"].enabled);
		OAK_ASSERT([menu itemWithTitle:@"Untrack 2 Items"].enabled && ![menu itemWithTitle:@"Move…"].enabled);
		OAK_ASSERT([menu itemWithTitle:@"Snapshot 2 Items…"].enabled && [menu itemWithTitle:@"Compare"].hasSubmenu);
		[changes selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
		menu = rightClickWorkingCopyRow(1);
		OAK_ASSERT(changes.selectedRow == 1 && changes.numberOfSelectedRows == 1);
		NSMenuItem* stage = [menu itemWithTitle:@"Stage"];
		OAK_ASSERT(stage.enabled && [NSApp sendAction:stage.action to:stage.target from:stage]);
	});
	waitForUI(^BOOL{ return [rightClickWorkingCopyRow(1) itemWithTitle:@"Unstage"].enabled; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSMenuItem* unstage = [rightClickWorkingCopyRow(1) itemWithTitle:@"Unstage"];
		OAK_ASSERT([NSApp sendAction:unstage.action to:unstage.target from:unstage]);
	});
	waitForUI(^BOOL{ return [rightClickWorkingCopyRow(1) itemWithTitle:@"Stage"].enabled; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		[changes deselectAll:nil];
		NSSplitView* split = [workspace valueForKey:@"split"];
		[controller.window.contentView layoutSubtreeIfNeeded];
		NSView* chrome = controller.window.contentView.superview;
		NSBitmapImageRep* image = [chrome bitmapImageRepForCachingDisplayInRect:chrome.bounds];
		[chrome cacheDisplayInRect:chrome.bounds toBitmapImageRep:image];
		NSRect modeRegion = [modes convertRect:modes.bounds toView:chrome];
		// The switch can still respond to hit testing when a repaint covers it.
		OAK_ASSERT(region_has_ink(image, chrome.bounds.size, NSInsetRect(modeRegion, 2, 2)));
		OAK_ASSERT([[[workspace valueForKey:@"emptyTitle"] stringValue] isEqual:@"No file selected"]);
		OAK_ASSERT(split.subviews.count == 3 && NSWidth(split.subviews[0].frame) >= 155 && NSWidth(split.subviews[1].frame) >= 225 && NSWidth(split.subviews[2].frame) >= 265);
		CGFloat originalDivider = NSMaxX(split.subviews.firstObject.frame);
		[split setPosition:originalDivider+12 ofDividerAtIndex:0];
		OAK_ASSERT(NSMaxX(split.subviews.firstObject.frame) > originalDivider);
		checkGitTitleBar(YES);
		NSSearchField* search = [workspace valueForKey:@"search"];
		search.stringValue = @"readme";
		[search sendAction:search.action to:search.target];
		OAK_ASSERT(changes.numberOfRows == 1);
		[changes selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	});
	waitForUI(^BOOL{ return [patch.string containsString:@"2 chunks, 3 insertions, 3 deletions"] && [patch.string containsString:@"Line 26 has a second edit."]; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		[[workspace valueForKey:@"ignoreDiffWhitespace"] performClick:nil];
		OAK_ASSERT([patch.string containsString:@"2 chunks, 3 insertions, 3 deletions"]);
	});
	waitForUI(^BOOL{ return [patch.string containsString:@"2 chunks, 2 insertions, 2 deletions"]; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		[[workspace valueForKey:@"ignoreDiffWhitespace"] performClick:nil];
		[[workspace valueForKey:@"showCompleteDiff"] performClick:nil];
	});
	waitForUI(^BOOL{ return [patch.string containsString:@"1 chunk, 3 insertions, 3 deletions"] && [patch.string containsString:@"Line 48 remains unchanged."]; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSPopUpButton* context = [workspace valueForKey:@"diffContext"];
		OAK_ASSERT(context.selectedTag == 7 && !context.enabled);
		[[workspace valueForKey:@"showCompleteDiff"] performClick:nil];
		OAK_ASSERT(context.enabled);
		[context selectItemWithTag:4];
		[context sendAction:context.action to:context.target];
	});
	waitForUI(^BOOL{ return [patch.string containsString:@"Line 22 remains unchanged."] && ![patch.string containsString:@"Line 21 remains unchanged."]; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		[controller.window.contentView layoutSubtreeIfNeeded];
		NSView* diff = [workspace valueForKey:@"diff"];
		NSDictionary<NSNumber*, NSStackView*>* controls = [diff valueForKey:@"chunkControls"];
		NSButton* stageSecond = (NSButton*)controls[@1].arrangedSubviews.lastObject;
		OAK_ASSERT(controls.count == 2 && [stageSecond.title isEqual:@"Stage Chunk"]);
		NSPoint buttonPoint = [stageSecond convertPoint:NSMakePoint(NSMidX(stageSecond.bounds), NSMidY(stageSecond.bounds)) toView:diff.superview];
		OAK_ASSERT([[diff hitTest:buttonPoint] isDescendantOf:stageSecond]);
		[stageSecond sendAction:stageSecond.action to:stageSecond.target];
	});
	NSDate* stageDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
	NSString* stagedPatch;
	do {
		stagedPatch = GitWorkspaceText(GitRepositoryCommand(directory, @[@"diff", @"--cached"]));
		if([stagedPatch containsString:@"has a second edit"]) break;
		[NSThread sleepForTimeInterval:0.01];
	} while(stageDeadline.timeIntervalSinceNow > 0);
	OAK_ASSERT([stagedPatch containsString:@"has a second edit"] && ![stagedPatch containsString:@"Working copy edit"]);
	dispatch_sync(dispatch_get_main_queue(), ^{
		navigate(@"history");
		NSButton* back = [workspace valueForKey:@"back"];
		NSButton* forward = [workspace valueForKey:@"forward"];
		OAK_ASSERT(back.enabled && !forward.enabled);
		[back performClick:nil];
		OAK_ASSERT([[[navigation itemAtRow:navigation.selectedRow] objectForKey:@"id"] isEqual:@"working"] && forward.enabled);
		[forward performClick:nil];
		OAK_ASSERT([[[navigation itemAtRow:navigation.selectedRow] objectForKey:@"id"] isEqual:@"history"]);
	});
	waitForUI(^BOOL{ return [[workspace valueForKey:@"historyTable"] numberOfRows] == 5; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSTableView* history = [workspace valueForKey:@"historyTable"];
		id<NSTableViewDelegate> delegate = history.delegate;
		OAK_ASSERT([delegate tableView:history isGroupRow:0] && [delegate tableView:history isGroupRow:3]);
		OAK_ASSERT(![delegate tableView:history isGroupRow:1] && ![delegate tableView:history isGroupRow:2]);
		OAK_ASSERT(![delegate tableView:history shouldSelectRow:0] && ![delegate tableView:history shouldSelectRow:3]);
		OAK_ASSERT([[[workspace valueForKey:@"historyStatus"] stringValue] isEqual:@"3 commits"]);
		NSStackView* commitRow = (NSStackView*)[history viewAtColumn:0 row:1 makeIfNecessary:YES];
		GitGraphTracksView* tracks = (GitGraphTracksView*)commitRow.arrangedSubviews.firstObject;
		OAK_ASSERT([tracks isKindOfClass:GitGraphTracksView.class] && !tracks.hidden && tracks.head && tracks.tracks[@"node"]);
		[history selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
		NSMenu* historyMenu = rightClickRow(history, 1);
		NSDictionary* clickedCommit = [historyMenu itemWithTitle:@"Copy Commit Hash to Clipboard"].representedObject;
		OAK_ASSERT(history.selectedRow == 2 && [clickedCommit[@"commit"][@"head"] boolValue]);
		OAK_ASSERT([historyMenu itemWithTitle:@"Copy Commit Info to Clipboard"].enabled);
		NSString* down = [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey];
		[history keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagFunction
			timestamp:0 windowNumber:history.window.windowNumber context:nil characters:down charactersIgnoringModifiers:down isARepeat:NO keyCode:125]];
		OAK_ASSERT(history.selectedRow == 4);
		OAK_ASSERT([history rowViewAtRow:4 makeIfNecessary:YES].selected && ![history rowViewAtRow:3 makeIfNecessary:YES].selected);
	});
	waitForUI(^BOOL{
		NSView* inspector = [workspace valueForKey:@"revisionInspector"];
		return !inspector.hidden && [[inspector valueForKey:@"message"] stringValue].length > 0 && [[[inspector valueForKey:@"details"] objectForKey:@"message"] containsString:@"Original fixture body"];
	});
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSView* inspector = [workspace valueForKey:@"revisionInspector"];
		NSOutlineView* entries = [inspector valueForKey:@"outline"];
		[controller.window.contentView layoutSubtreeIfNeeded];
		OAK_ASSERT(entries.numberOfRows == 2 && [[[entries itemAtRow:1] objectForKey:@"path"] isEqual:@"README.md"]);
		NSTextField* message = [inspector valueForKey:@"message"];
		NSView* metadata = [inspector valueForKey:@"metadata"];
		NSView* header = [inspector valueForKey:@"header"];
		NSClipView* clip = entries.enclosingScrollView.contentView;
		OAK_ASSERT(message.enclosingScrollView == entries.enclosingScrollView && metadata.enclosingScrollView == entries.enclosingScrollView);
		OAK_ASSERT(NSHeight(message.frame) > NSHeight(clip.bounds) && [message.stringValue containsString:@"Line 36"]);
		NSButton* toggleMetadata = [inspector valueForKey:@"toggleMetadata"];
		NSPoint togglePoint = [toggleMetadata convertPoint:NSMakePoint(NSMidX(toggleMetadata.bounds), NSMidY(toggleMetadata.bounds)) toView:inspector.superview];
		OAK_ASSERT([[inspector hitTest:togglePoint] isDescendantOf:toggleMetadata]);
		NSRect messageBefore = [message convertRect:message.bounds toView:inspector];
		NSRect metadataBefore = [metadata convertRect:metadata.bounds toView:inspector];
		NSRect headerBefore = [header convertRect:header.bounds toView:inspector];
		[entries scrollRowToVisible:1];
		OAK_ASSERT(NSContainsRect(clip.documentVisibleRect, [entries rectOfRow:1]));
		NSMenu* fileMenu = rightClickRow(entries, 1);
		NSDictionary* fileAction = [fileMenu itemWithTitle:@"Copy Relative File Path"].representedObject;
		OAK_ASSERT([fileAction[@"file"][@"path"] isEqual:@"README.md"] && fileMenu.numberOfItems == 11);
		OAK_ASSERT(!NSEqualRects([message convertRect:message.bounds toView:inspector], messageBefore));
		OAK_ASSERT(!NSEqualRects([metadata convertRect:metadata.bounds toView:inspector], metadataBefore));
		OAK_ASSERT(NSEqualRects([header convertRect:header.bounds toView:inspector], headerBefore));
		[entries expandItem:[entries itemAtRow:1]];
		OAK_ASSERT(entries.numberOfRows == 3);
		[entries scrollRowToVisible:2];
	});
	waitForUI(^BOOL{
		NSOutlineView* entries = [[workspace valueForKey:@"revisionInspector"] valueForKey:@"outline"];
		NSView* diff = [entries viewAtColumn:0 row:2 makeIfNecessary:YES].subviews.firstObject;
		return [diff isKindOfClass:GitDiffView.class] && [[[diff valueForKey:@"textView"] string] containsString:@"Line 48 remains unchanged."];
	});
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSOutlineView* entries = [[workspace valueForKey:@"revisionInspector"] valueForKey:@"outline"];
		[entries layoutSubtreeIfNeeded];
		NSRect inlinePatch = [entries rectOfRow:2];
		NSScrollView* list = entries.enclosingScrollView;
		OAK_ASSERT(NSHeight(inlinePatch) > NSHeight(list.contentView.bounds));
		[list.contentView scrollToPoint:NSMakePoint(0, NSMaxY(inlinePatch)-NSHeight(list.contentView.bounds))];
		[list reflectScrolledClipView:list.contentView];
		NSView* diff = [entries viewAtColumn:0 row:2 makeIfNecessary:NO].subviews.firstObject;
		OAK_ASSERT([diff isKindOfClass:GitDiffView.class]);
		NSTextView* inlineText = [diff valueForKey:@"textView"];
		OAK_ASSERT(inlineText && !inlineText.enclosingScrollView.hasVerticalScroller);
		[inlineText.layoutManager ensureLayoutForTextContainer:inlineText.textContainer];
		NSRect lastLine = [inlineText.layoutManager usedRectForTextContainer:inlineText.textContainer];
		NSPoint end = [inlineText convertPoint:NSMakePoint(0, NSMaxY(lastLine)-2) toView:entries];
		OAK_ASSERT(NSMinY(list.documentVisibleRect) <= end.y && end.y < NSMaxY(list.documentVisibleRect));
		NSSearchField* search = [workspace valueForKey:@"search"];
		OAK_ASSERT(search.enabled && [search.placeholderString isEqual:@"Search for Message"] && search.searchMenuTemplate.numberOfItems == 4);
		search.stringValue = @"Original fixture body";
		[search sendAction:search.action to:search.target];
	});
	waitForUI(^BOOL{
		NSTableView* history = [workspace valueForKey:@"historyTable"];
		return history.numberOfRows == 2 && history.selectedRow == 1 && [[[workspace valueForKey:@"selectedCommit"] objectForKey:@"subject"] isEqual:@"Initial commit"];
	});
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSButton* quick = [workspace valueForKey:@"quickActionsButton"];
		[quick sendAction:quick.action to:quick.target];
		NSWindow* panel = controller.window.childWindows.lastObject;
		OAK_ASSERT(panel.isVisible && [panel isKindOfClass:NSPanel.class]);
		OAK_ASSERT((panel.styleMask & NSWindowStyleMaskTitled) == 0);
		OAK_ASSERT(panel.sheetParent == nil && panel.parentWindow == controller.window);
#if !HAVE_OAK_SWIFTUI
		NSWindowController* chooser = [workspace valueForKey:@"quickActions"];
		[chooser setValue:@"topic/ui" forKey:@"filterString"];
		NSArray* entries = [chooser valueForKey:@"items"];
		OAK_ASSERT([entries.firstObject[@"checkout"] isEqual:@"refs/heads/topic/ui"]);
#endif
		[quick sendAction:quick.action to:quick.target];
		OAK_ASSERT(!panel.isVisible && panel.parentWindow == nil);
	});
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSButton* stashes = [workspace valueForKey:@"stashShortcut"];
		[stashes performClick:nil];
		NSButton* save = [workspace valueForKey:@"operationButtons"][@(GitRepositorySaveStash)];
		OAK_ASSERT(save.enabled);
	});
	waitForUI(^BOOL{ return [[[[workspace valueForKey:@"revisionInspector"] valueForKey:@"details"] objectForKey:@"message"] containsString:@"Stashed draft"]; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSView* inspector = [workspace valueForKey:@"revisionInspector"];
		NSTableView* list = [workspace valueForKey:@"historyTable"];
		NSOutlineView* entries = [inspector valueForKey:@"outline"];
		NSRect overview = [entries rectOfRow:0];
		[list selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
		OAK_ASSERT([[[inspector valueForKey:@"message"] stringValue] containsString:@"Stashed draft"]);
		OAK_ASSERT(NSEqualRects([entries rectOfRow:0], overview) && entries.numberOfRows == 2);
		OAK_ASSERT(![[inspector valueForKey:@"stashActionButtons"][GitStashApply] isEnabled]);
	});
	waitForUI(^BOOL{ return [[[[workspace valueForKey:@"revisionInspector"] valueForKey:@"details"] objectForKey:@"message"] containsString:@"Older draft"]; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSTableView* list = [workspace valueForKey:@"historyTable"];
		[list selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	});
	waitForUI(^BOOL{ return [[[[workspace valueForKey:@"revisionInspector"] valueForKey:@"details"] objectForKey:@"message"] containsString:@"Stashed draft"]; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSView* inspector = [workspace valueForKey:@"revisionInspector"];
		NSTableView* list = [workspace valueForKey:@"historyTable"];
		OAK_ASSERT(list.numberOfRows == 2 && list.selectedRow == 0);
		NSMenu* stashMenu = rightClickRow(list, 1);
		NSDictionary* clickedStash = [stashMenu itemWithTitle:@"Apply Stash…"].representedObject;
		OAK_ASSERT(list.selectedRow == 0 && [clickedStash[@"subject"] containsString:@"Older draft"]);
		OAK_ASSERT([[workspace valueForKey:@"historyFooter"] isHidden]);
		NSArray<NSButton*>* actions = [inspector valueForKey:@"stashActionButtons"];
		NSButton* apply = actions[GitStashApply];
		OAK_ASSERT(!apply.isHiddenOrHasHiddenAncestor && apply.enabled && actions[GitStashDelete].enabled);
		[controller.window.contentView layoutSubtreeIfNeeded];
		NSPoint point = [apply convertPoint:NSMakePoint(NSMidX(apply.bounds), NSMidY(apply.bounds)) toView:inspector.superview];
		OAK_ASSERT([[inspector hitTest:point] isDescendantOf:apply]);
		NSOutlineView* entries = [inspector valueForKey:@"outline"];
		OAK_ASSERT(entries.numberOfRows == 2 && [[[entries itemAtRow:1] objectForKey:@"path"] isEqual:@"README.md"]);
		NSSegmentedControl* tabs = [inspector valueForKey:@"tabs"];
		tabs.selectedSegment = 1;
		[tabs sendAction:tabs.action to:tabs.target];
	});
	waitForUI(^BOOL{
		NSOutlineView* entries = [[workspace valueForKey:@"revisionInspector"] valueForKey:@"outline"];
		return entries.numberOfRows == 2 && [[[entries itemAtRow:1] objectForKey:@"kind"] isEqual:@"blob"];
	});
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSButton* back = [workspace valueForKey:@"back"];
		[back performClick:nil];
		navigate(@"branchesReview");
	});
	waitForUI(^BOOL{
		id review = [workspace valueForKey:@"branchesReview"];
		NSArray* rows = [review valueForKey:@"rows"];
		return rows.count == 1 && [[rows.firstObject objectForKey:@"name"] isEqual:@"topic/ui"]
			&& [[[review valueForKey:@"comparison"] valueForKey:@"entries"] count] == 1;
	});
	git(@[@"branch", @"review/preview"]);
	dispatch_sync(dispatch_get_main_queue(), ^{ [workspace refresh:nil]; });
	waitForUI(^BOOL{ return [[[[workspace valueForKey:@"branchesReview"] valueForKey:@"table"] valueForKey:@"numberOfRows"] integerValue] == 2; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		id review = [workspace valueForKey:@"branchesReview"];
		NSSegmentedControl* tabs = [review valueForKey:@"tabs"];
		tabs.selectedSegment = 1;
		[tabs sendAction:tabs.action to:tabs.target];
	});
	waitForUI(^BOOL{ return [[[[workspace valueForKey:@"branchesReview"] valueForKey:@"comparison"] valueForKey:@"comparison"] objectForKey:@"range"] != nil; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		id review = [workspace valueForKey:@"branchesReview"];
		NSTableView* branches = [review valueForKey:@"table"];
		NSView* comparison = [review valueForKey:@"comparison"];
		NSString* title = [[review valueForKey:@"detailTitle"] stringValue];
		[branches selectRowIndexes:[NSIndexSet indexSetWithIndex:1-branches.selectedRow] byExtendingSelection:NO];
		OAK_ASSERT([[review valueForKey:@"tabs"] selectedSegment] == 1 && !comparison.hidden);
		OAK_ASSERT([[[review valueForKey:@"detailTitle"] stringValue] isEqual:title]);
	});
	waitForUI(^BOOL{ return [[[[workspace valueForKey:@"branchesReview"] valueForKey:@"detailTitle"] stringValue] hasPrefix:@"review/preview"]; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSTableView* branches = [[workspace valueForKey:@"branchesReview"] valueForKey:@"table"];
		[branches selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
		NSMenu* menu = rightClickRow(branches, 1);
		NSArray* titles = [[menu.itemArray filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSMenuItem* item, NSDictionary* bindings){ return !item.isSeparatorItem; }]] valueForKey:@"title"];
		OAK_ASSERT(titles.count == 21 && [titles.firstObject isEqual:@"Check Out “topic/ui”"] && [titles.lastObject isEqual:@"Copy Branch Name to Clipboard"]);
		OAK_ASSERT([menu itemWithTitle:@"Track Parent Branch"].submenu.numberOfItems >= 3);
		OAK_ASSERT(![menu itemWithTitle:@"Force Push with Lease…"].enabled && ![menu itemWithTitle:@"Create New Pull Request from “topic/ui”…"].enabled);
		NSMenuItem* pin = [menu itemWithTitle:@"Pin “topic/ui”"];
		OAK_ASSERT(branches.selectedRow == 0 && pin.enabled && [NSApp sendAction:pin.action to:pin.target from:pin]);
	});
	waitForUI(^BOOL{
		NSArray* branches = [[workspace valueForKey:@"branchesReview"] valueForKey:@"rows"];
		return [branches.firstObject[@"name"] isEqual:@"topic/ui"] && [branches.firstObject[@"prefs"][@"pinned"] boolValue];
	});
	OAK_ASSERT([GitWorkspaceConfig(directory, @"branch.topic/ui.textmatePinned") isEqual:@"true"] && !GitWorkspaceConfig(directory, @"branch.review/preview.textmatePinned"));
	dispatch_sync(dispatch_get_main_queue(), ^{
		navigate(@"pullRequests");
	});
	waitForUI(^BOOL{ return [[[[workspace valueForKey:@"pullRequests"] valueForKey:@"status"] stringValue] containsString:@"Add a GitHub remote"]; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		navigate(@"settings");
	});
	waitForUI(^BOOL{
		id settings = [workspace valueForKey:@"repositorySettings"];
		return [[settings valueForKey:@"fields"] objectForKey:@"user.email"] != nil;
	});
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSViewController* settings = [workspace valueForKey:@"repositorySettings"];
		[controller.window.contentView layoutSubtreeIfNeeded];
		NSTextField* field = [settings valueForKey:@"fields"][@"textmate.issueTrackerURL"];
		NSTextField* description = [settings valueForKey:@"descriptionField"];
		NSButton* identity = [settings valueForKey:@"identityEdit"];
		NSSegmentedControl* tabs = [settings valueForKey:@"tabs"];
		OAK_ASSERT(settings.view.window == controller.window && !settings.view.isHiddenOrHasHiddenAncestor && NSHeight(field.frame) > 8);
		OAK_ASSERT(identity.window == controller.window && [[settings valueForKey:@"footer"] isHidden]);
		NSSize originalSize = controller.window.contentView.bounds.size;
		for(NSNumber* width in @[@1440, @560]) {
			[controller.window setContentSize:NSMakeSize(width.doubleValue, 840)];
			[controller.window.contentView layoutSubtreeIfNeeded];
			NSRect tabFrame = [tabs convertRect:tabs.bounds toView:settings.view];
			NSRect descriptionFrame = [description convertRect:description.bounds toView:settings.view];
			NSRect issueFrame = [field convertRect:field.bounds toView:settings.view];
			OAK_ASSERT(NSWidth(issueFrame) > 44 && NSWidth(descriptionFrame) > 44 && fabs(NSMinX(issueFrame)-NSMinX(descriptionFrame)) <= 1);
			OAK_ASSERT(NSContainsRect(settings.view.bounds, tabFrame) && NSMaxX(descriptionFrame) < NSWidth(settings.view.bounds));
			OAK_ASSERT(NSMaxY(settings.view.bounds)-NSMaxY(descriptionFrame) < 230);
		}
		[controller.window setContentSize:originalSize];
		field.stringValue = @"https://example.invalid/issues/{id}";
		[[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:field];
		NSButton* save = [settings valueForKey:@"save"];
		OAK_ASSERT(save.enabled);
		[save performClick:nil];
	});
	waitForUI(^BOOL{ return [GitWorkspaceConfig(directory, @"textmate.issueTrackerURL") isEqual:@"https://example.invalid/issues/{id}"]; });
	dispatch_sync(dispatch_get_main_queue(), ^{
		navigate(@"history");
		modes.selectedSegment = 0;
		[modes sendAction:modes.action to:modes.target];
		OAK_ASSERT(!workspace.isActive && workspace.view.hidden && !editor.isHiddenOrHasHiddenAncestor);
		OAK_ASSERT(!workspace.titleBarItems.superview);
		OAK_ASSERT(controller.selectedDocument == document && [editor.selectionString isEqual:@"1:4"]);
		OAK_ASSERT(controller.window.firstResponder == editor);
		[document beginUndoGrouping];
		document.content = @"Unsaved editor content\n";
		[document endUndoGrouping];
		[controller.window setContentSize:NSMakeSize(560, 320)];
		[controller showGitWorkspace:nil];
		NSSplitView* split = [workspace valueForKey:@"split"];
		OAK_ASSERT(modes.selectedSegment == 1 && workspace.isActive);
		OAK_ASSERT(NSMaxX(split.subviews.lastObject.frame) == NSWidth(split.bounds));
		checkGitTitleBar(YES);
		OakTabBarView* bar = (OakTabBarView*)modes.superview;
		CGFloat originalInset = bar.leadingContentInset;
		bar.leadingContentInset = 0; // As in full screen, where the traffic lights are hidden.
		checkGitTitleBar(NO);
		OAK_ASSERT(NSMinX(modes.frame) < originalInset);
		bar.leadingContentInset = originalInset;
		OAK_ASSERT([[[navigation itemAtRow:navigation.selectedRow] objectForKey:@"id"] isEqual:@"history"]);
		[controller showGitWorkspace:nil];
		OAK_ASSERT(modes.selectedSegment == 0 && controller.selectedDocument == document && document.isDocumentEdited);
		OAK_ASSERT([document.content isEqual:@"Unsaved editor content\n"]);
		[controller close];
		[DocumentWindowController enableSessionSave];
	});
	OAK_ASSERT([files removeItemAtPath:fixture error:nil]);
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
