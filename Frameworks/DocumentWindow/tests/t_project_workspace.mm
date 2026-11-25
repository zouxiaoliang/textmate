#import <Cocoa/Cocoa.h>
#import "../src/DocumentWindowController.h"
#import "../src/ProjectWorkspace.h"
#import <FileBrowser/FileBrowserViewController.h>
#import <FileBrowser/FileItem.h>
#import <document/OakDocument.h>
#import <document/OakDocumentController.h>
#import <objc/message.h>

static NSURL* WorkspaceFixtureDirectory()
{
	NSURL* url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:NO attributes:nil error:nil]);
	return url.URLByResolvingSymlinksInPath;
}

static NSURL* AddWorkspaceFixtureFolder(NSURL* parent, NSString* name)
{
	NSURL* url = [parent URLByAppendingPathComponent:name isDirectory:YES];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:NO attributes:nil error:nil]);
	return url;
}

void test_workspace_jsonc_reads_roots_and_preserves_other_configuration ()
{
	NSURL* directory = WorkspaceFixtureDirectory();
	NSURL* api = AddWorkspaceFixtureFolder(directory, @"api");
	NSURL* worker = AddWorkspaceFixtureFolder(directory, @"worker");
	NSURL* config = [directory URLByAppendingPathComponent:@"Team.code-workspace"];
	NSString* prefix = @"{\n // Project settings\n \"settings\": {\"url\": \"https://x.test/[,]/\\\"/*\", \"folders\": [1,],},\n \"f\\u006flders\": ";
	NSString* suffix = @",\n /* Keep launch config */ \"launch\": {\"configurations\": []},\n}\n";
	NSString* source = [NSString stringWithFormat:@"%@[{\"path\":\"api\",\"name\":\"Service\",}, {\"uri\":\"remote://host/\",},]%@", prefix, suffix];
	OAK_ASSERT([source writeToURL:config atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	NSError* error;
	ProjectWorkspace* workspace = [ProjectWorkspace workspaceAtURL:config error:&error];
	OAK_ASSERT(workspace && !error);
	OAK_ASSERT([workspace.name isEqual:@"Team"]);
	OAK_ASSERT([workspace.folders isEqual:@[ (@{ @"path": api.path, @"name": @"Service" }) ]]);
	OAK_ASSERT(([workspace addFolderPaths:@[ worker.path, worker.path, api.path ] error:&error]));
	OAK_ASSERT(workspace.folders.count == 2);
	OAK_ASSERT([workspace removeFolderAtPath:api.path error:&error]);
	NSString* saved = [NSString stringWithContentsOfURL:config encoding:NSUTF8StringEncoding error:&error];
	OAK_ASSERT([saved hasPrefix:prefix] && [saved hasSuffix:suffix]);
	OAK_ASSERT([saved containsString:@"remote://host/"]);
	OAK_ASSERT([NSFileManager.defaultManager fileExistsAtPath:api.path]);
	ProjectWorkspace* reopened = [ProjectWorkspace workspaceAtURL:config error:&error];
	OAK_ASSERT([reopened.folders isEqual:@[ (@{ @"path": worker.path, @"name": @"worker" }) ]]);
	[NSFileManager.defaultManager removeItemAtURL:directory error:nil];
}

void test_workspace_uses_deepest_root_and_checks_for_concurrent_folder_changes ()
{
	NSURL* directory = WorkspaceFixtureDirectory();
	NSURL* api = AddWorkspaceFixtureFolder(directory, @"api");
	NSURL* child = AddWorkspaceFixtureFolder(api, @"tool");
	NSURL* config = [directory URLByAppendingPathComponent:@"Team.code-workspace"];
	ProjectWorkspace* workspace = [ProjectWorkspace createAtURL:config folderPaths:@[ api.path, child.path ] error:nil];
	OAK_ASSERT(workspace != nil);
	OAK_ASSERT([[workspace folderContainingPath:[child URLByAppendingPathComponent:@"main.go"].path] isEqual:child.path]);
	OAK_ASSERT(![workspace folderContainingPath:[directory URLByAppendingPathComponent:@"api-other/main.go"].path]);
	OAK_ASSERT([[workspace availableFolderPreferringPath:child.path] isEqual:child.path]);
	OAK_ASSERT(![ProjectWorkspace createAtURL:config folderPaths:@[] error:nil]);

	ProjectWorkspace* anotherWindow = [ProjectWorkspace workspaceAtURL:config error:nil];
	OAK_ASSERT([anotherWindow removeFolderAtPath:api.path error:nil]);
	NSError* error;
	OAK_ASSERT(![workspace removeFolderAtPath:child.path error:&error] && error != nil);
	OAK_ASSERT([ProjectWorkspace workspaceAtURL:config error:nil].folders.count == 1);
	OAK_ASSERT([@"{\"folders\":[],\"folders\":[]}" writeToURL:config atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	OAK_ASSERT(![ProjectWorkspace workspaceAtURL:config error:nil]);
	[NSFileManager.defaultManager removeItemAtURL:directory error:nil];
}

static FileItem* WorkspaceRootItem(FileBrowserViewController* browser, NSURL* url)
{
	for(NSInteger row = 0; row < browser.outlineView.numberOfRows; ++row)
	{
		FileItem* item = [browser.outlineView itemAtRow:row];
		if([browser.outlineView levelForRow:row] == 0 && [item.URL.path isEqual:url.path])
			return item;
	}
	return nil;
}

void test_workspace_restores_independent_root_expansion_and_folder_context ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSURL* directory = WorkspaceFixtureDirectory();
		NSURL* api = AddWorkspaceFixtureFolder(directory, @"api");
		NSURL* worker = AddWorkspaceFixtureFolder(api, @"worker");
		NSURL* config = [directory URLByAppendingPathComponent:@"Team.code-workspace"];
		ProjectWorkspace* workspace = [ProjectWorkspace createAtURL:config folderPaths:@[ api.path, worker.path ] error:nil];
		OAK_ASSERT(workspace != nil);

		DocumentWindowController* controller = [DocumentWindowController new];
		auto restore = (void(*)(id, SEL, NSDictionary*, BOOL))objc_msgSend;
		restore(controller, @selector(setupControllerForProject:skipMissingFiles:), @{ @"workspacePath": config.path, @"fileBrowserVisible": @YES }, NO);
		FileBrowserViewController* browser = [controller valueForKey:@"fileBrowser"];
		FileItem* apiItem = WorkspaceRootItem(browser, api);
		FileItem* workerItem = WorkspaceRootItem(browser, worker);
		OAK_ASSERT(apiItem && workerItem);
		OAK_ASSERT([browser.outlineView isItemExpanded:apiItem] && [browser.outlineView isItemExpanded:workerItem]);
		[browser.outlineView collapseItem:apiItem];
		OAK_ASSERT(![browser.outlineView isItemExpanded:apiItem] && [browser.outlineView isItemExpanded:workerItem]);
		OAK_ASSERT([controller.projectPath isEqual:api.path]);

		NSMenuItem* fallback = [NSMenuItem new];
		fallback.representedObject = worker.path;
		[controller takeWorkspaceFolderFrom:fallback];
		OAK_ASSERT([[controller valueForKey:@"terminalStartDirectory"] isEqual:worker.path]);
		NSDictionary* state = ((NSDictionary*(*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(sessionInfoIncludingUntitledDocuments:), NO);
		OAK_ASSERT([state[@"workspacePath"] isEqual:config.path] && !state[@"projectPath"]);

		DocumentWindowController* restored = [DocumentWindowController new];
		restore(restored, @selector(setupControllerForProject:skipMissingFiles:), state, NO);
		FileBrowserViewController* restoredBrowser = [restored valueForKey:@"fileBrowser"];
		FileItem* restoredAPI = WorkspaceRootItem(restoredBrowser, api);
		FileItem* restoredWorker = WorkspaceRootItem(restoredBrowser, worker);
		OAK_ASSERT(restoredAPI && restoredWorker);
		OAK_ASSERT(![restoredBrowser.outlineView isItemExpanded:restoredAPI]);
		OAK_ASSERT([restoredBrowser.outlineView isItemExpanded:restoredWorker]);
		OAK_ASSERT([[restored valueForKey:@"terminalStartDirectory"] isEqual:worker.path]);
		[restored showWindow:nil];
		for(NSURL* root in @[ api, worker ])
		{
			NSURL* file = [root URLByAppendingPathComponent:@"main.txt"];
			OAK_ASSERT([@"fixture" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);
			[OakDocumentController.sharedInstance showDocument:[OakDocument documentWithPath:file.path] inProject:restored.identifier bringToFront:YES];
			NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
			while(![restored.selectedDocument.path isEqual:file.path] && deadline.timeIntervalSinceNow > 0)
				[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
			OAK_ASSERT([restored.selectedDocument.path isEqual:file.path]);
			OAK_ASSERT([[restored valueForKey:@"terminalStartDirectory"] isEqual:root.path]);
		}
		OAK_ASSERT(restored.documents.count == 2);
		NSDictionary* withTabs = ((NSDictionary*(*)(id, SEL, BOOL))objc_msgSend)(restored, @selector(sessionInfoIncludingUntitledDocuments:), NO);
		[restored close];
		[controller close];

		DocumentWindowController* reopened = [DocumentWindowController new];
		restore(reopened, @selector(setupControllerForProject:skipMissingFiles:), withTabs, YES);
		OAK_ASSERT(reopened.documents.count == 2);
		OAK_ASSERT([reopened.projectWorkspaceURL isEqual:config]);
		[reopened close];
		[NSFileManager.defaultManager removeItemAtURL:directory error:nil];
		[DocumentWindowController enableSessionSave];
	});
}
