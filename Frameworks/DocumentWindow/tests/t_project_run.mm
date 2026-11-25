#import <Cocoa/Cocoa.h>
#import "../src/DocumentWindowController.h"
#import "../src/ProjectDebugSession.h"
#import "../src/ProjectRun.h"
#import "../src/ProjectRunSession.h"
#import "../src/FloatingPanel.h"
#import "../src/RunPanelController.h"
#import "../src/ProjectLayoutView.h"
#import "../src/TerminalPanelViewController.h"
#import <MenuBuilder/MenuBuilder.h>
#import <QuartzCore/QuartzCore.h>
#import <document/OakDocument.h>
#import <objc/message.h>
#import "RunConfigurationMenuProbe.h"

static void MoveOutputPointer(FloatingPanel* panel, NSPoint point)
{
	SEL move = NSSelectorFromString(@"pointerMovedTo:");
	((void(*)(id, SEL, NSPoint))objc_msgSend)(panel, move, point);
}

static void ReleaseOutputDrag(FloatingPanel* panel, NSScreen* screen, NSRect bounds, NSPoint point)
{
	if(screen)
		[panel endDragAtPoint:point];
	else
	{
		SEL release = NSSelectorFromString(@"endDragInVisibleFrame:atPoint:");
		((void(*)(id, SEL, NSRect, NSPoint))objc_msgSend)(panel, release, bounds, point);
	}
}

static BOOL MoveOutputOnDisplay(FloatingPanel* panel, NSSize offset, NSRect bounds)
{
	SEL move = NSSelectorFromString(@"moveBy:inVisibleFrame:");
	return ((BOOL(*)(id, SEL, NSSize, NSRect))objc_msgSend)(panel, move, offset, bounds);
}

static void PrepareOutputDisplay(FloatingPanel* panel, NSNumber* displayNumber)
{
	SEL prepare = NSSelectorFromString(@"prepareDisplayNumber:");
	((BOOL(*)(id, SEL, NSNumber*))objc_msgSend)(panel, prepare, displayNumber);
}

static void WaitForOutputGenie(FloatingPanel* panel)
{
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:1];
	while([panel valueForKey:@"genieWindow"] && deadline.timeIntervalSinceNow > 0)
		[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
	OAK_ASSERT(![panel valueForKey:@"genieWindow"]);
}

static NSEvent* OutputDragEvent(NSWindow* window, NSEventType type, NSPoint point, NSInteger clickCount = 1)
{
	return [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:0 windowNumber:window.windowNumber
		context:nil eventNumber:0 clickCount:clickCount pressure:1];
}

void test_empty_project_window_ignores_document_bundle_commands ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		DocumentWindowController* controller = [DocumentWindowController new];
		OAK_ASSERT(controller.selectedDocument == nil);
		auto bundle = std::make_shared<bundles::item_t>(oak::uuid_t().generate(), bundles::item_ptr(), bundles::kItemTypeBundle);
		OAK_ASSERT(bundle->initialize({ { "name", "Test Bundle" } }));
		auto command = std::make_shared<bundles::item_t>(oak::uuid_t().generate(), bundle, bundles::kItemTypeCommand);
		OAK_ASSERT(command->initialize({ { "name", "Test Document Command" }, { "command", "exit 0" } }));
		[controller performBundleItem:command];
		OAK_ASSERT(controller.selectedDocument == nil);
		[controller close];
		[DocumentWindowController enableSessionSave];
	});
}

static NSURL* RunFixtureDirectory()
{
	NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil]);
	return directory.URLByResolvingSymlinksInPath;
}

static NSURL* RunFixtureFolder(NSURL* base, NSString* name, NSString* tasks, NSString* launch)
{
	NSURL* folder = [base URLByAppendingPathComponent:name isDirectory:YES];
	NSURL* settings = [folder URLByAppendingPathComponent:@".vscode" isDirectory:YES];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:settings withIntermediateDirectories:YES attributes:nil error:nil]);
	if(tasks)
		OAK_ASSERT([tasks writeToURL:[settings URLByAppendingPathComponent:@"tasks.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	if(launch)
		OAK_ASSERT([launch writeToURL:[settings URLByAppendingPathComponent:@"launch.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	return folder;
}

void test_run_shortcut_opens_configuration_panel_without_guessing_a_program ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSURL* base = RunFixtureDirectory();
		NSURL* launch = [base URLByAppendingPathComponent:@".vscode/launch.json"];
		DocumentWindowController* controller = [DocumentWindowController new];
		controller.defaultProjectPath = base.path;
		NSMenu* menu = MBCreateMenu({
			{ @"Run", .submenu = {
				{ @"Start Debugging / Continue", @selector(debugSelectedConfiguration:), .modifierFlags = 0, .target = controller, .key = NSF5FunctionKey },
			} },
		});
		NSString* key = [NSString stringWithFormat:@"%C", (unichar)NSF5FunctionKey];
		NSEvent* event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagFunction timestamp:0
		                             windowNumber:0 context:nil characters:key charactersIgnoringModifiers:key isARepeat:NO keyCode:96];
		OAK_ASSERT(MBPerformRunMenuKeyEquivalent(menu, event));
		RunPanelController* panel = [controller valueForKey:@"runPanelController"];
		OAK_ASSERT(panel.view.superview && !panel.isRunning && ![NSFileManager.defaultManager fileExistsAtPath:launch.path]);
		OAK_ASSERT([[(NSTextField*)[panel valueForKey:@"status"] stringValue] containsString:@"create a launch.json"]);

		[controller configureRunPanel:nil];
		NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
		while(![controller.selectedDocument.path isEqual:launch.path] && deadline.timeIntervalSinceNow > 0)
			[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
		OAK_ASSERT([controller.selectedDocument.path isEqual:launch.path]);
		ProjectRunConfiguration* selected = [panel valueForKey:@"selectedConfiguration"];
		OAK_ASSERT(selected.supportsDebugging && [selected.root isEqual:base.path] && !panel.isRunning);
		[controller close];
		[NSFileManager.defaultManager removeItemAtURL:base error:nil];
		[DocumentWindowController enableSessionSave];
	});
}

void test_opening_launch_configuration_preserves_existing_jsonc ()
{
	NSURL* base = RunFixtureDirectory();
	NSString* existing = @"{\n// Do not rewrite my VS Code configuration.\n\"version\":\"0.2.0\", \"configurations\":[],\n}\n";
	NSURL* folder = RunFixtureFolder(base, @"worker", nil, existing);
	NSError* error = nil;
	NSURL* launch = [ProjectRunConfiguration openOrCreateLaunchConfigurationInFolder:folder.path error:&error];
	OAK_ASSERT(launch && !error);
	OAK_ASSERT([[NSString stringWithContentsOfURL:launch encoding:NSUTF8StringEncoding error:nil] isEqual:existing]);
	[NSFileManager.defaultManager removeItemAtURL:base error:nil];
}

void test_run_rereads_launch_json_and_does_not_silently_switch_configurations ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSURL* base = RunFixtureDirectory();
		NSURL* folder = RunFixtureFolder(base, @"app", nil, @"{\"configurations\":[{\"name\":\"Old\",\"type\":\"textmate-process\",\"request\":\"launch\",\"program\":\"/bin/echo\"}]}");
		DocumentWindowController* controller = [DocumentWindowController new];
		controller.defaultProjectPath = folder.path;
		[controller showRunPanel:nil];
		NSURL* launch = [folder URLByAppendingPathComponent:@".vscode/launch.json"];
		OAK_ASSERT([@"{\"configurations\":[{\"name\":\"Replacement\",\"type\":\"textmate-process\",\"request\":\"launch\",\"program\":\"/bin/echo\"}]}" writeToURL:launch atomically:YES encoding:NSUTF8StringEncoding error:nil]);
		[controller runSelectedConfiguration:nil];
		RunPanelController* panel = [controller valueForKey:@"runPanelController"];
		OAK_ASSERT(!panel.isRunning && !controller.window.attachedSheet);
		OAK_ASSERT([[(NSTextField*)[panel valueForKey:@"status"] stringValue] containsString:@"selected configuration changed"]);
		[controller close];
		[NSFileManager.defaultManager removeItemAtURL:base error:nil];
		[DocumentWindowController enableSessionSave];
	});
}

void test_run_configuration_resolves_prelaunch_and_working_directory_in_its_own_folder ()
{
	NSURL* base = RunFixtureDirectory();
	NSString* launch = @"{ // Select each root independently\n \"configurations\": [{\"name\":\"Dev\",\"type\":\"textmate-process\",\"request\":\"launch\",\"program\":\"echo\",\"preLaunchTask\":\"Prepare\",\"args\":[\"${workspaceFolder}\",\"${workspaceFolder:API}\",\"two words\",],},],}";
	NSURL* api = RunFixtureFolder(base, @"api", @"{\"tasks\":[{\"label\":\"Prepare\",\"type\":\"process\",\"command\":\"echo\",\"args\":[\"api\"]}]}", launch);
	NSURL* worker = RunFixtureFolder(base, @"worker", @"{\"tasks\":[{\"label\":\"Prepare\",\"type\":\"process\",\"command\":\"echo\",\"args\":[\"worker\"],\"options\":{\"env\":{\"RUN_ROOT\":\"${workspaceFolder}\"}}}]}", launch);
	NSMutableArray* errors = [NSMutableArray array];
	NSArray* folders = @[ @{ @"path":api.path, @"name":@"API" }, @{ @"path":worker.path, @"name":@"Worker" } ];
	NSArray<ProjectRunConfiguration*>* configs = [ProjectRunConfiguration configurationsForFolders:folders errors:errors];
	OAK_ASSERT(errors.count == 0 && configs.count == 4);

	ProjectRunConfiguration* selected = configs[2];
	OAK_ASSERT([selected.title isEqual:@"Dev — Worker"]);
	NSArray<ProjectRunCommand*>* commands = [selected commandsForFile:[api URLByAppendingPathComponent:@"main.go"].path environment:@{ @"PATH": @"/bin:/usr/bin" } error:nil];
	OAK_ASSERT(commands.count == 2);
	OAK_ASSERT([commands[0].directory isEqual:worker.path] && [commands[1].directory isEqual:worker.path]);
	OAK_ASSERT([commands[0].environment[@"RUN_ROOT"] isEqual:worker.path]);
	OAK_ASSERT([commands[0].arguments.firstObject isEqual:@"worker"]);
	OAK_ASSERT(([commands[1].arguments isEqual:@[ worker.path, api.path, @"two words" ]]));
	OAK_ASSERT(![configs[0].identifier isEqual:selected.identifier]);
	[NSFileManager.defaultManager removeItemAtURL:base error:nil];
}

void test_run_configuration_rejects_unsupported_tasks_before_execution ()
{
	NSURL* base = RunFixtureDirectory();
	NSString* tasks = @"{\"tasks\":[{\"label\":\"Build\",\"type\":\"shell\",\"command\":\"echo\"},{\"label\":\"Bad\",\"type\":\"process\",\"command\":\"echo\",\"isBackground\":{}}]}";
	NSString* launch = @"{\"configurations\":[{\"name\":\"App\",\"type\":\"textmate-process\",\"request\":\"launch\",\"program\":\"/bin/echo\",\"preLaunchTask\":\"Build\"}]}";
	NSURL* project = RunFixtureFolder(base, @"app", tasks, launch);
	NSArray<ProjectRunConfiguration*>* configs = [ProjectRunConfiguration configurationsForFolders:@[ @{ @"path":project.path, @"name":@"App" } ] errors:nil];
	OAK_ASSERT(configs.count == 2);
	for(ProjectRunConfiguration* config in configs)
	{
		NSError* error;
		OAK_ASSERT(![config commandsForFile:nil environment:@{} error:&error]);
		OAK_ASSERT([error.localizedDescription containsString:@"foreground process"]);
	}
	[NSFileManager.defaultManager removeItemAtURL:base error:nil];
}

static void PumpRunSession(ProjectRunSession* session)
{
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:4];
	while(session.isRunning && deadline.timeIntervalSinceNow > 0)
		[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
	OAK_ASSERT(!session.isRunning);
}

static NSColor* RunOutputForeground(NSTextView* output, NSString* text)
{
	NSUInteger index = [output.string rangeOfString:text].location;
	OAK_ASSERT(index != NSNotFound);
	return [output.textStorage attribute:NSForegroundColorAttributeName atIndex:index effectiveRange:nil];
}

void test_run_panel_renders_wails_ansi_colors ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		RunPanelController* panel = [RunPanelController new];
		OAK_ASSERT(panel.view != nil);
		ProjectRunSession* session = [panel valueForKey:@"session"];
		NSTextView* output = [panel valueForKey:@"output"];

		session.didReadOutput([@"\033[0;92mWails CLI\033[0m \033[0;31mv2.12.0\033[0m\n\n\033"
		                         dataUsingEncoding:NSUTF8StringEncoding]);
		OAK_ASSERT([output.string isEqual:@"Wails CLI v2.12.0\n\n"]);
		NSColor* titleColor = [RunOutputForeground(output, @"Wails CLI") colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
		NSColor* versionColor = [RunOutputForeground(output, @"v2.12.0") colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
		OAK_ASSERT(titleColor && titleColor.greenComponent > titleColor.redComponent);
		OAK_ASSERT(versionColor && versionColor.redComponent > versionColor.greenComponent);
		session.didReadOutput([@"[0;9" dataUsingEncoding:NSUTF8StringEncoding]);
		NSData* chunk = [@"2mExecuting: go mod tidy\033[0m\n • 正在编译\n" dataUsingEncoding:NSUTF8StringEncoding];
		NSUInteger split = [@"2mExecuting: go mod tidy\033[0m\n " length] + 1;
		session.didReadOutput([chunk subdataWithRange:NSMakeRange(0, split)]);
		session.didReadOutput([chunk subdataWithRange:NSMakeRange(split, chunk.length-split)]);
		OAK_ASSERT([output.string isEqual:@"Wails CLI v2.12.0\n\nExecuting: go mod tidy\n • 正在编译\n"]);
		OAK_ASSERT([RunOutputForeground(output, @"Executing:") isEqual:RunOutputForeground(output, @"Wails CLI")]);
		OAK_ASSERT([RunOutputForeground(output, @"•") isEqual:NSColor.textColor]);
	});
}

void test_run_panel_discards_incomplete_ansi_at_output_boundaries ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		RunPanelController* panel = [RunPanelController new];
		OAK_ASSERT(panel.view != nil);
		ProjectRunSession* session = [panel valueForKey:@"session"];
		ProjectDebugSession* debugger = [panel valueForKey:@"debugger"];
		NSTextView* output = [panel valueForKey:@"output"];

		session.didReadOutput([@"\033[91mRun\033[0;" dataUsingEncoding:NSUTF8StringEncoding]);
		session.didFinish(0, NO, nil);
		debugger.didReadOutput(@"Debugger \033[3");
		debugger.didReadOutput(@"2mrea");
		debugger.didReadOutput(@"dy\033[");
		debugger.didChangeState(ProjectDebugIdle, @"Ended");
		debugger.didReadOutput(@"Done");
		OAK_ASSERT([output.string isEqual:@"Run\nExited with code 0\nDebugger ready\nEnded\nDone"]);
		OAK_ASSERT(![RunOutputForeground(output, @"ready") isEqual:NSColor.textColor]);
		OAK_ASSERT([RunOutputForeground(output, @"dy") isEqual:RunOutputForeground(output, @"ready")]);
		OAK_ASSERT([RunOutputForeground(output, @"Debugger") isEqual:NSColor.textColor]);
		OAK_ASSERT([RunOutputForeground(output, @"Done") isEqual:NSColor.textColor]);
	});
}

void test_run_panel_renders_indexed_and_rgb_ansi_foreground_colors ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		RunPanelController* panel = [RunPanelController new];
		OAK_ASSERT(panel.view != nil);
		ProjectRunSession* session = [panel valueForKey:@"session"];
		NSTextView* output = [panel valueForKey:@"output"];

		session.didReadOutput([@"\033[38;5;196mIndexed \033[48;5;34;38;2;12;34;56mRGB \033[39mDefault"
		                         dataUsingEncoding:NSUTF8StringEncoding]);
		OAK_ASSERT([output.string isEqual:@"Indexed RGB Default"]);
		OAK_ASSERT([RunOutputForeground(output, @"Indexed") isEqual:[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1]]);
		OAK_ASSERT([RunOutputForeground(output, @"RGB") isEqual:[NSColor colorWithSRGBRed:12/255.0 green:34/255.0 blue:56/255.0 alpha:1]]);
		OAK_ASSERT([RunOutputForeground(output, @"Default") isEqual:NSColor.textColor]);
	});
}

void test_run_node_terminal_launch_resolves_gbot_hot_reload_without_a_shell ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSURL* base = RunFixtureDirectory();
		NSString* launch = @"{\"configurations\":[{\"name\":\"gui: gbot (热刷新开发)\",\"type\":\"node-terminal\",\"request\":\"launch\","
		                     "\"command\":\"cd ${workspaceFolder}/app/gbot-gui && wails dev\","
		                     "\"env\":{\"https_proxy\":\"http://127.0.0.1:6152\"}}]}";
		NSURL* project = RunFixtureFolder(base, @"project with spaces", nil, launch);
		NSURL* gui = [project URLByAppendingPathComponent:@"app/gbot-gui" isDirectory:YES];
		OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:gui withIntermediateDirectories:YES attributes:nil error:nil]);
		NSURL* wails = [base URLByAppendingPathComponent:@"wails"];
		OAK_ASSERT([@"#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$1\" \"$https_proxy\"\n" writeToURL:wails atomically:YES encoding:NSUTF8StringEncoding error:nil]);
		OAK_ASSERT([NSFileManager.defaultManager setAttributes:@{ NSFilePosixPermissions: @0700 } ofItemAtPath:wails.path error:nil]);
		ProjectRunConfiguration* config = [ProjectRunConfiguration configurationsForFolders:@[ @{ @"path": project.path, @"name": @"gbot" } ] errors:nil].firstObject;
		NSError* error = nil;
		NSArray<ProjectRunCommand*>* commands = [config commandsForFile:nil environment:@{ @"PATH": base.path } error:&error];
		OAK_ASSERT(commands.count == 1 && !error && !config.supportsDebugging);
		ProjectRunCommand* command = commands.firstObject;
		OAK_ASSERT([command.executable isEqual:wails.path] && [command.directory isEqual:gui.path]);
		OAK_ASSERT(([command.arguments isEqual:@[ @"dev" ]]));
		OAK_ASSERT([command.environment[@"https_proxy"] isEqual:@"http://127.0.0.1:6152"]);

		ProjectRunSession* session = [ProjectRunSession new];
		NSMutableData* output = [NSMutableData data];
		__block int exitCode = -1;
		__block NSError* runError = nil;
		session.didReadOutput = ^(NSData* data){ [output appendData:data]; };
		session.didFinish = ^(int code, BOOL stopped, NSError* error){
			exitCode = code;
			runError = error;
		};
		[session runCommands:commands];
		PumpRunSession(session);
		OAK_ASSERT(!runError && exitCode == 0);
		NSString* text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
		NSArray<NSString*>* lines = [text componentsSeparatedByString:@"\n"];
		OAK_ASSERT(lines.count == 4);
		OAK_ASSERT([lines[0].stringByResolvingSymlinksInPath isEqual:gui.path.stringByResolvingSymlinksInPath]);
		OAK_ASSERT([lines[1] isEqual:@"dev"] && [lines[2] isEqual:@"http://127.0.0.1:6152"] && !lines[3].length);
		[NSFileManager.defaultManager removeItemAtURL:base error:nil];
	});
}

void test_run_node_terminal_accepts_quoted_words_but_rejects_other_shell_syntax ()
{
	NSURL* base = RunFixtureDirectory();
	NSArray* values = @[ @"echo \"${workspaceFolder}/two words\" '' 'literal; and &&'", @"echo one | echo two",
	                    @"echo $(pwd)", @"echo one && echo two", @"cd . && echo two > out", @"echo \"missing" ];
	for(NSUInteger index = 0; index < values.count; ++index)
	{
		NSData* json = [NSJSONSerialization dataWithJSONObject:@{ @"configurations": @[
			@{ @"name": @"Terminal", @"type": @"node-terminal", @"request": @"launch", @"command": values[index] },
		] } options:0 error:nil];
		NSURL* project = RunFixtureFolder(base, [@(index) stringValue], nil, [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
		ProjectRunConfiguration* config = [ProjectRunConfiguration configurationsForFolders:@[ @{ @"path": project.path, @"name": @"Project" } ] errors:nil].firstObject;
		NSError* error = nil;
		NSArray<ProjectRunCommand*>* commands = [config commandsForFile:nil environment:@{ @"PATH": @"/bin:/usr/bin" } error:&error];
		if(index == 0)
		{
			OAK_ASSERT(commands.count == 1 && !error);
			OAK_ASSERT(([commands.firstObject.arguments isEqual:@[ [project.path stringByAppendingPathComponent:@"two words"], @"", @"literal; and &&" ]]));
		}
		else
			OAK_ASSERT(!commands && [error.localizedDescription containsString:@"simple command"]);
	}
	[NSFileManager.defaultManager removeItemAtURL:base error:nil];
}

void test_run_session_reports_output_and_does_not_launch_after_failed_task ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSURL* base = RunFixtureDirectory();
		NSString* tasks = @"{\"tasks\":[{\"label\":\"Fail\",\"type\":\"process\",\"command\":\"/usr/bin/false\"},{\"label\":\"Print\",\"type\":\"process\",\"command\":\"/bin/pwd\"}]}";
		NSString* launch = @"{\"configurations\":[{\"name\":\"Not Started\",\"type\":\"textmate-process\",\"request\":\"launch\",\"program\":\"/bin/echo\",\"args\":[\"should not be printed\"],\"preLaunchTask\":\"Fail\"}]}";
		NSURL* project = RunFixtureFolder(base, @"app", tasks, launch);
		NSArray<ProjectRunConfiguration*>* configs = [ProjectRunConfiguration configurationsForFolders:@[ @{ @"path":project.path, @"name":@"App" } ] errors:nil];
		ProjectRunSession* session = [ProjectRunSession new];
		NSMutableData* output = [NSMutableData data];
		__block NSUInteger started = 0;
		__block int exitCode = -1;
		__block NSError* runError = nil;
		session.didStartCommand = ^(ProjectRunCommand* command){ ++started; };
		session.didReadOutput = ^(NSData* data){ [output appendData:data]; };
		session.didFinish = ^(int status, BOOL stopped, NSError* error){
			exitCode = status;
			runError = error;
		};

		[session runCommands:[configs[0] commandsForFile:nil environment:@{} error:nil]];
		PumpRunSession(session);
		OAK_ASSERT(!runError && exitCode == 1 && started == 1 && output.length == 0);

		[session runCommands:[configs[2] commandsForFile:nil environment:@{} error:nil]];
		PumpRunSession(session);
		OAK_ASSERT(!runError && exitCode == 0 && started == 2);
		NSString* text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
		NSString* printedPath = [text stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
		OAK_ASSERT([text hasSuffix:@"\n"] && [printedPath.stringByResolvingSymlinksInPath isEqual:project.path.stringByResolvingSymlinksInPath]);
		[NSFileManager.defaultManager removeItemAtURL:base error:nil];
	});
}

void test_run_session_can_stop_a_running_program ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSURL* base = RunFixtureDirectory();
		NSURL* project = RunFixtureFolder(base, @"app", @"{\"tasks\":[{\"label\":\"Wait\",\"type\":\"process\",\"command\":\"/bin/sleep\",\"args\":[\"30\"]}]}", nil);
		ProjectRunConfiguration* config = [ProjectRunConfiguration configurationsForFolders:@[ @{ @"path":project.path, @"name":@"App" } ] errors:nil].firstObject;
		ProjectRunSession* session = [ProjectRunSession new];
		__block BOOL stopped = NO;
		session.didFinish = ^(int status, BOOL wasStopped, NSError* error){ stopped = wasStopped && !error; };
		[session runCommands:[config commandsForFile:nil environment:@{} error:nil]];
		OAK_ASSERT(session.isRunning);
		[session stop];
		PumpRunSession(session);
		OAK_ASSERT(stopped);
		[NSFileManager.defaultManager removeItemAtURL:base error:nil];
	});
}

void test_showing_run_panel_lists_tasks_without_starting_them ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSURL* base = RunFixtureDirectory();
		NSURL* project = RunFixtureFolder(base, @"app", @"{\"tasks\":[{\"label\":\"Create Marker\",\"type\":\"process\",\"command\":\"/usr/bin/touch\",\"args\":[\"run-marker\"]}]}", nil);
		DocumentWindowController* controller = [DocumentWindowController new];
		controller.defaultProjectPath = project.path;
		[controller showRunPanel:nil];
		[controller.window.contentView layoutSubtreeIfNeeded];

		RunPanelController* panel = [controller valueForKey:@"runPanelController"];
		ProjectRunConfiguration* selected = [panel valueForKey:@"selectedConfiguration"];
		ProjectLayoutView* layout = [controller valueForKey:@"layoutView"];
		OAK_ASSERT(layout.runAndDebugView == panel.view && [panel.view isDescendantOf:layout] && !panel.outputView.superview);
		OAK_ASSERT([selected.name isEqual:@"Create Marker"] && [selected.root isEqual:project.path]);
		OAK_ASSERT(!panel.isRunning && ![NSFileManager.defaultManager fileExistsAtPath:[project.path stringByAppendingPathComponent:@"run-marker"]]);

		[controller close];
		[NSFileManager.defaultManager removeItemAtURL:base error:nil];
		[DocumentWindowController enableSessionSave];
	});
}

void test_restarting_a_configuration_waits_for_the_current_process_and_reuses_its_plan ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSURL* base = RunFixtureDirectory();
		NSURL* project = RunFixtureFolder(base, @"app", @"{\"tasks\":[{\"label\":\"Wait\",\"type\":\"process\",\"command\":\"/bin/sleep\",\"args\":[\"30\"]}]}", nil);
		DocumentWindowController* controller = [DocumentWindowController new];
		controller.defaultProjectPath = project.path;
		[controller showRunPanel:nil];
		RunPanelController* panel = [controller valueForKey:@"runPanelController"];
		ProjectRunSession* session = [panel valueForKey:@"session"];
		ProjectRunConfiguration* config = [panel valueForKey:@"selectedConfiguration"];
		NSArray<ProjectRunCommand*>* commands = [config commandsForFile:nil environment:@{} error:nil];
		OAK_ASSERT(commands.count == 1 && !panel.canRestart);
		NSMutableArray* launched = [NSMutableArray array];
		session.didStartCommand = ^(ProjectRunCommand* command){ [launched addObject:command]; };

		SEL start = NSSelectorFromString(@"startCommands:configuration:debugPlan:");
		((void(*)(id, SEL, id, id, id))objc_msgSend)(panel, start, commands, config, nil);
		OAK_ASSERT(panel.canRestart && launched.count == 1);
		[controller restartRunConfiguration:nil];
		OAK_ASSERT(session.isStopping && !panel.canRestart && launched.count == 1);
		NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:4];
		while(launched.count < 2 && [deadline timeIntervalSinceNow] > 0)
			[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
		OAK_ASSERT(launched.count == 2 && launched.firstObject == launched.lastObject && panel.canRestart && panel.isRunning);

		[panel restart:nil];
		[panel stop:nil];
		PumpRunSession(session);
		OAK_ASSERT(launched.count == 2 && !panel.isRunning);
		[panel resetTrust];
		OAK_ASSERT(!panel.canRestart);
		[controller close];
		[NSFileManager.defaultManager removeItemAtURL:base error:nil];
		[DocumentWindowController enableSessionSave];
	});
}

void test_run_sidebar_and_output_open_independently_at_minimum_window_size ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSURL* base = RunFixtureDirectory();
		NSURL* project = RunFixtureFolder(base, @"app", @"{\"tasks\":[{\"label\":\"Print\",\"type\":\"process\",\"command\":\"/bin/echo\",\"args\":[\"hello from the subprocess\"]}]}", nil);
		DocumentWindowController* controller = [DocumentWindowController new];
		controller.defaultProjectPath = project.path;
		controller.fileBrowserVisible = YES;
		controller.outlineVisible = YES;
		NSWindow* window = controller.window;
		[window orderFront:nil];
		ProjectLayoutView* layout = [controller valueForKey:@"layoutView"];
		NSView* files = layout.fileBrowserView;
		NSView* outline = layout.outlineView;
		NSView* sidebar = files.superview;
		TerminalPanelViewController* dock = [controller valueForKey:@"terminalPanelController"];
		dock.panelPosition = kTerminalPanelPositionRight;
		dock.panelVisible = YES;
		NSView* terminal = [dock valueForKey:@"panelView"];
		[window setContentSize:window.contentMinSize];
		[window layoutIfNeeded];
		NSRect mainFrame = window.frame;
		[controller showRunPanel:nil];
		RunPanelController* panel = [controller valueForKey:@"runPanelController"];
		NSButton* projectHeader = [layout valueForKey:@"fileBrowserHeader"];
		NSButton* outlineHeader = [layout valueForKey:@"outlineHeader"];
		NSButton* runHeader = [layout valueForKey:@"runAndDebugHeader"];
		[window layoutIfNeeded];
		OAK_ASSERT(sidebar && files.superview == sidebar && outline.superview == sidebar && panel.view.superview == sidebar);
		OAK_ASSERT(projectHeader.superview == sidebar && outlineHeader.superview == sidebar && runHeader.superview == sidebar);
		OAK_ASSERT(NSMinX(projectHeader.frame) == NSMinX(outlineHeader.frame) && NSMinX(outlineHeader.frame) == NSMinX(runHeader.frame));
		OAK_ASSERT(NSMinY(outline.frame) >= NSMaxY(runHeader.frame));
		OAK_ASSERT(layout.runAndDebugView == panel.view && !panel.outputView.superview && terminal.superview == dock.view);
		NSButton* launch = [panel valueForKey:@"runButton"];
		OAK_ASSERT(launch.enabled && launch.window == window && [launch.toolTip containsString:@"Run Without Debugging"]);
		ProjectRunConfiguration* configuration = [panel valueForKey:@"selectedConfiguration"];
		NSArray<ProjectRunCommand*>* commands = [configuration commandsForFile:nil environment:@{} error:nil];
		OAK_ASSERT(commands.count == 1);
		SEL start = NSSelectorFromString(@"startCommands:configuration:debugPlan:");
		using StartCommands = void (*)(RunPanelController*, SEL, NSArray<ProjectRunCommand*>*, ProjectRunConfiguration*, ProjectDebugPlan*);
		auto startCommands = reinterpret_cast<StartCommands>([panel methodForSelector:start]);
		startCommands(panel, start, commands, configuration, nil);
		NSWindow* outputWindow = panel.outputView.window;
		OAK_ASSERT(outputWindow && outputWindow != window && outputWindow.parentWindow == window && outputWindow.isVisible);
		NSButton* pin = [panel valueForKey:@"outputPinButton"];
		[pin performClick:nil];
		OAK_ASSERT(pin.state == NSControlStateValueOn && !outputWindow.parentWindow && ![(NSPanel*)outputWindow hidesOnDeactivate]);
		[pin performClick:nil];
		OAK_ASSERT(pin.state == NSControlStateValueOff && outputWindow.parentWindow == window && [(NSPanel*)outputWindow hidesOnDeactivate]);
		[outputWindow layoutIfNeeded];
		NSView* bar = [panel valueForKey:@"outputDragBar"];
		NSPoint handle = NSMakePoint(NSMinX(bar.frame) + 15, NSMidY(bar.frame));
		OAK_ASSERT([bar hitTest:handle] == bar);
		NSPoint from = [bar.superview convertPoint:handle toView:nil];
		NSEvent* down = OutputDragEvent(outputWindow, NSEventTypeLeftMouseDown, from);
		NSRect beforeDrag = outputWindow.frame;
		OAK_ASSERT([bar acceptsFirstMouse:down]);
		[bar mouseDown:down];
		[bar mouseDragged:OutputDragEvent(outputWindow, NSEventTypeLeftMouseDragged, NSMakePoint(from.x + 12, from.y + 8))];
		OAK_ASSERT_EQ(NSMinX(outputWindow.frame), NSMinX(beforeDrag) + 12);
		OAK_ASSERT_EQ(NSMinY(outputWindow.frame), NSMinY(beforeDrag) + 8);
		[bar mouseDragged:OutputDragEvent(outputWindow, NSEventTypeLeftMouseDragged, NSMakePoint(from.x - 12, from.y - 8))];
		[bar mouseUp:OutputDragEvent(outputWindow, NSEventTypeLeftMouseUp, from)];
		PumpRunSession([panel valueForKey:@"session"]);
		NSTextView* output = [panel valueForKey:@"output"];
		OAK_ASSERT([output.string containsString:@"\nhello from the subprocess\n"] && [output.string containsString:@"Exited with code 0"]);
		[window layoutIfNeeded];
		OAK_ASSERT(panel.outputView.window == outputWindow && terminal.superview == dock.view);
		OAK_ASSERT_GE(NSHeight(panel.outputView.frame), 100);
		OAK_ASSERT_GT(NSHeight(files.frame), 0);
		OAK_ASSERT_GT(NSHeight(outline.frame), 0);
		OAK_ASSERT(NSEqualRects(window.frame, mainFrame));
		[runHeader performClick:nil];
		OAK_ASSERT(layout.runAndDebugCollapsed && layout.runAndDebugView == panel.view && !panel.view.superview);
		OAK_ASSERT(files.superview == sidebar && outline.superview == sidebar && runHeader.superview == sidebar && outputWindow.isVisible);
		[controller showRunPanel:nil];
		OAK_ASSERT(!layout.runAndDebugCollapsed && panel.view.superview == sidebar);
		for(NSUInteger attempt = 0; attempt < 2; ++attempt)
		{
			panel.hideHandler();
			OAK_ASSERT(!panel.view.superview && !runHeader.superview && outputWindow.isVisible);
			OAK_ASSERT(files.superview == sidebar && outline.superview == sidebar);
			[controller showRunPanel:nil];
			[outputWindow cancelOperation:nil];
			[window layoutIfNeeded];
			OAK_ASSERT([panel.view isDescendantOf:layout] && !outputWindow.isVisible && !outputWindow.parentWindow && terminal.superview == dock.view);
			[controller showRunOutput:nil];
			[window layoutIfNeeded];
			OAK_ASSERT(outputWindow.isVisible && panel.outputView.window == outputWindow && [output.string containsString:@"hello from the subprocess"]);
			OAK_ASSERT(NSEqualRects(window.frame, mainFrame));
		}
		[controller close];
		OAK_ASSERT(!outputWindow.isVisible && !outputWindow.parentWindow);
		[NSFileManager.defaultManager removeItemAtURL:base error:nil];
		[DocumentWindowController enableSessionSave];
	});
}

#if HAVE_OAK_SWIFTUI
void test_floating_terminal_reuses_sessions_on_tuck_hide_and_dock ()
{
	if(!TEXTMATE_ENABLE_FLOATING_TERMINAL)
		return;
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		DocumentWindowController* controller = [DocumentWindowController new];
		TerminalPanelViewController* terminal = [controller valueForKey:@"terminalPanelController"];
		terminal.panelPosition = kTerminalPanelPositionFloating;
		terminal.terminalShellPath = @"/bin/sh";
		terminal.terminalShellArguments = @[];
		NSWindow* owner = controller.window;
		[owner setContentSize:NSMakeSize(1000, 700)];

		terminal.panelVisible = YES;
		[terminal startTerminal];
		[controller showWindow:nil];
		[owner layoutIfNeeded];
		NSView* editor = [controller valueForKey:@"layoutView"];
		NSRect editorFrame = editor.frame;
		NSRect ownerFrame = owner.frame;
		NSView* terminalView = [terminal valueForKey:@"panelView"];
		NSPanel* window = (NSPanel*)terminalView.window;
		NSArray<NSUUID*>* sessions = terminal.terminalSessionIdentifiers;
		OAK_ASSERT_EQ(sessions.count, 1);
		OAK_ASSERT(window && window != owner && window.parentWindow == owner && window.isVisible);
		NSView* tabs = [[terminal valueForKey:@"terminalTabBarController"] valueForKey:@"tabBar"];
		NSButton* addTab = [tabs valueForKey:@"createNewTabButton"];
		FloatingPanelDragBar* controls = [terminal valueForKey:@"floatingDragBar"];
		NSBox* surface = [terminal valueForKey:@"floatingSurface"];
		[window.contentView layoutSubtreeIfNeeded];
		OAK_ASSERT(tabs.window == window && ![tabs isDescendantOf:terminalView]);
		OAK_ASSERT_EQ(NSHeight(tabs.frame), 24);
		OAK_ASSERT_EQ(NSMaxY(surface.contentView.bounds) - NSMaxY(controls.frame), 6);
		OAK_ASSERT_EQ(NSMaxX(tabs.superview.frame), NSMinX(controls.frame));
		OAK_ASSERT_EQ(NSMinY(controls.frame), NSMaxY(terminalView.superview.frame));
		OAK_ASSERT(controls.arrangedSubviews.count == 2);
		OAK_ASSERT_EQ(NSMaxX(addTab.frame), NSMaxX(tabs.bounds));

		NSPoint gap = NSMakePoint(NSMinX(addTab.frame) - 12, NSMidY(tabs.bounds));
		OAK_ASSERT([tabs hitTest:[tabs convertPoint:gap toView:tabs.superview]] == tabs);
		NSPoint dragStart = [tabs convertPoint:gap toView:nil];
		[tabs mouseDown:OutputDragEvent(window, NSEventTypeLeftMouseDown, dragStart, 2)];
		[tabs mouseUp:OutputDragEvent(window, NSEventTypeLeftMouseUp, dragStart, 2)];
		OAK_ASSERT([terminal.terminalSessionIdentifiers isEqualToArray:sessions]);

		[addTab performClick:nil];
		OAK_ASSERT_EQ(terminal.terminalSessionIdentifiers.count, 2);
		OAK_ASSERT_EQ(NSMaxX(addTab.frame), NSMaxX(tabs.bounds));
		[window.contentView layoutSubtreeIfNeeded];
		auto alignmentCenterY = [](NSView* view) -> CGFloat {
			NSRect alignment = [view alignmentRectForFrame:view.frame];
			return [view.superview convertPoint:NSMakePoint(NSMidX(alignment), NSMidY(alignment)) toView:nil].y;
		};
		CGFloat headerCenterY = alignmentCenterY(controls);
		for(NSView* control in [controls.arrangedSubviews arrayByAddingObject:addTab])
			OAK_ASSERT_LE(fabs(alignmentCenterY(control) - headerCenterY), 0.5);
		NSUInteger centeredTitles = 0;
		for(NSView* tab in tabs.subviews)
		{
			if(![tab.accessibilityRole isEqualToString:NSAccessibilityRadioButtonRole])
				continue;
			NSView* title = [tab valueForKey:@"textField"];
			OAK_ASSERT_LE(fabs(alignmentCenterY(title) - headerCenterY), 0.5);
			++centeredTitles;
		}
		OAK_ASSERT_EQ(centeredTitles, 2);
		[terminal closeTerminalSessions:@[ terminal.terminalSessionIdentifiers.lastObject ]];
		OAK_ASSERT([terminal.terminalSessionIdentifiers isEqualToArray:sessions]);
		NSColor* background = [NSColor colorWithWhite:0.1 alpha:1];
		[terminal applyTerminalBackground:background foreground:NSColor.whiteColor caret:NSColor.whiteColor
			selection:NSColor.selectedTextBackgroundColor syntaxColors:@[]];
		OAK_ASSERT([surface.fillColor isEqual:background]);
		OAK_ASSERT([surface.appearance.name isEqualToString:NSAppearanceNameDarkAqua]);

		FloatingPanel* panel = [terminal valueForKey:@"floatingPanel"];
		SEL toggle = NSSelectorFromString(@"toggleTerminalPanel:");
		OAK_ASSERT(panel.keepsOpenWhileKey);
		NSScreen* screen = window.screen ?: NSScreen.mainScreen;
		NSRect bounds = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
		[tabs mouseDown:OutputDragEvent(window, NSEventTypeLeftMouseDown, dragStart)];
		[tabs mouseDragged:OutputDragEvent(window, NSEventTypeLeftMouseDragged, NSMakePoint(dragStart.x - 10, dragStart.y))];
		OAK_ASSERT([[panel valueForKey:@"dragging"] boolValue]);
		[tabs mouseUp:OutputDragEvent(window, NSEventTypeLeftMouseUp, dragStart)];
		OAK_ASSERT(![[panel valueForKey:@"dragging"] boolValue]);

		[panel beginDrag];
		NSPoint dropPoint = NSMakePoint(NSMinX(bounds) + 24, NSMidY(bounds));
		OAK_ASSERT(MoveOutputOnDisplay(panel, NSMakeSize(NSMinX(bounds) + 4 - NSMinX(window.frame), NSMidY(bounds) - NSMidY(window.frame)), bounds));
		ReleaseOutputDrag(panel, screen, bounds, dropPoint);
		OAK_ASSERT(terminal.isPanelTucked && terminal.panelVisible && !window.isVisible);
		OAK_ASSERT([NSApp sendAction:toggle to:controller from:nil]);
		OAK_ASSERT(!terminal.isPanelTucked && terminal.panelVisible && window.isVisible);
		if(window.isKeyWindow)
		{
			MoveOutputPointer(panel, NSMakePoint(NSMaxX(window.frame) + 100, NSMidY(window.frame)));
			OAK_ASSERT(![panel valueForKey:@"tuckTimer"]);
		}

		[window cancelOperation:nil];
		OAK_ASSERT(!terminal.panelVisible && !window.isVisible && terminalView.window == window);
		OAK_ASSERT([NSApp sendAction:toggle to:controller from:nil]);
		OAK_ASSERT(window.isVisible && [terminal.terminalSessionIdentifiers isEqualToArray:sessions]);
		terminal.panelPosition = kTerminalPanelPositionBottom;
		OAK_ASSERT(terminalView.window == owner && !window.isVisible);
		OAK_ASSERT(tabs.superview == terminalView);
		terminal.panelPosition = kTerminalPanelPositionFloating;
		[owner layoutIfNeeded];
		OAK_ASSERT(terminalView.window == window && [terminal.terminalSessionIdentifiers isEqualToArray:sessions]);
		OAK_ASSERT(tabs.window == window && ![tabs isDescendantOf:terminalView]);
		OAK_ASSERT(NSEqualRects(editor.frame, editorFrame));
		OAK_ASSERT(NSEqualRects(owner.frame, ownerFrame));

		NSButton* pin = (NSButton*)controls.arrangedSubviews.firstObject;
		[pin performClick:nil];
		OAK_ASSERT(panel.isPinned && pin.state == NSControlStateValueOn);
		OAK_ASSERT(window.isVisible && !window.parentWindow && !window.hidesOnDeactivate);
		[controller close];
		OAK_ASSERT(!window.isVisible && terminal.terminalSessionIdentifiers.count == 0);
		[DocumentWindowController enableSessionSave];
	});
}
#endif

void test_run_output_snaps_to_screen_edges_and_reveals_from_its_grip ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		NSScreen* screen = NSScreen.mainScreen;
		NSRect bounds = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
		NSWindow* owner = [[NSWindow alloc] initWithContentRect:NSMakeRect(NSMidX(bounds)-300, NSMidY(bounds)-200, 600, 400)
			styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
		owner.releasedWhenClosed = NO;
		[owner orderFront:nil];
		NSView* content = [NSView new];
		FloatingPanel* panel = [[FloatingPanel alloc] initWithContentView:content title:@"Output"];
		[panel showInWindow:owner];
		NSWindow* output = content.window;
		NSWindow* grip = [panel valueForKey:@"gripWindow"];
		NSRect initial = output.frame;
		OAK_ASSERT(output.parentWindow == owner && !grip.parentWindow);

		NSPoint middle = NSMakePoint(NSMidX(bounds), NSMidY(bounds));
		NSPoint targets[] = {
			NSMakePoint(NSMinX(bounds) + 4, middle.y - NSHeight(initial) / 2),
			NSMakePoint(NSMaxX(bounds) - NSWidth(initial) - 4, middle.y - NSHeight(initial) / 2),
			NSMakePoint(middle.x - NSWidth(initial) / 2, NSMinY(bounds) + 4),
			NSMakePoint(middle.x - NSWidth(initial) / 2, NSMaxY(bounds) - NSHeight(initial) - 4),
		};
		NSPoint grips[] = {
			NSMakePoint(NSMinX(bounds) + 4, middle.y), NSMakePoint(NSMaxX(bounds) - 4, middle.y),
			NSMakePoint(middle.x, NSMinY(bounds) + 4), NSMakePoint(middle.x, NSMaxY(bounds) - 4),
		};
		for(NSUInteger index = 0; index < 4; ++index)
		{
			[panel beginDrag];
			NSPoint start = output.frame.origin;
			OAK_ASSERT(MoveOutputOnDisplay(panel, NSMakeSize(targets[index].x - start.x, targets[index].y - start.y), bounds));
			OAK_ASSERT(output.parentWindow == owner && !grip.parentWindow);
			switch(index)
			{
				case 0: OAK_ASSERT_EQ(NSMinX(output.frame), NSMinX(bounds)); break;
				case 1: OAK_ASSERT_EQ(NSMaxX(output.frame), NSMaxX(bounds)); break;
				case 2: OAK_ASSERT_EQ(NSMinY(output.frame), NSMinY(bounds)); break;
				case 3: OAK_ASSERT_EQ(NSMaxY(output.frame), NSMaxY(bounds)); break;
			}
			ReleaseOutputDrag(panel, screen, bounds, grips[index]);
			OAK_ASSERT(grip.parentWindow == owner && !output.parentWindow && !output.isVisible);
			OAK_ASSERT(NSPointInRect(grips[index], grip.frame) && NSContainsRect(bounds, grip.frame));
			OAK_ASSERT(index < 2 ? NSWidth(grip.frame) == 8 : NSHeight(grip.frame) == 8);
			NSView* snapshot = nil;
			if(NSWindow* animation = [panel valueForKey:@"genieWindow"])
			{
				OAK_ASSERT(animation.ignoresMouseEvents && NSEqualRects(animation.frame, output.frame));
				snapshot = animation.contentView;
				OAK_ASSERT(snapshot.wantsLayer && snapshot.layer.sublayers.count);
				CALayer* mesh = snapshot.layer.sublayers.firstObject;
				OAK_ASSERT_EQ(index < 2 ? mesh.anchorPoint.x : mesh.anchorPoint.y, index % 2);
				OAK_ASSERT(mesh.sublayers.count > 1 && mesh.sublayers.firstObject.contents && mesh.sublayers.firstObject.contents == mesh.sublayers.lastObject.contents);
				CAKeyframeAnimation* depth = (CAKeyframeAnimation*)[mesh animationForKey:@"genie"];
				CAKeyframeAnimation* near = (CAKeyframeAnimation*)[mesh.sublayers.firstObject animationForKey:@"genie"];
				CAKeyframeAnimation* far = (CAKeyframeAnimation*)[mesh.sublayers.lastObject animationForKey:@"genie"];
				OAK_ASSERT(depth.values.count > 2 && near.values.count == depth.values.count && far.values.count == depth.values.count);
				NSUInteger middleSample = depth.values.count / 2;
				OAK_ASSERT([near.values[middleSample] doubleValue] < [far.values[middleSample] doubleValue]);
				CGFloat depthRatio = index < 2 ? NSWidth(grip.frame) / NSWidth(output.frame) : NSHeight(grip.frame) / NSHeight(output.frame);
				OAK_ASSERT(fabs([depth.values.lastObject doubleValue] - depthRatio) < 0.001);
			}

			MoveOutputPointer(panel, grips[index]);
			OAK_ASSERT(grip.parentWindow == owner);
			WaitForOutputGenie(panel);
			MoveOutputPointer(panel, middle);
			MoveOutputPointer(panel, grips[index]);
			if(snapshot)
				OAK_ASSERT([(NSWindow*)[panel valueForKey:@"genieWindow"] contentView] == snapshot);
			WaitForOutputGenie(panel);
			OAK_ASSERT(output.parentWindow == owner && !grip.parentWindow && !grip.isVisible);
			OAK_ASSERT(NSEqualSizes(output.frame.size, initial.size) && NSContainsRect(bounds, output.frame));
			OAK_ASSERT(NSPointInRect(grips[index], output.frame) && content.window == output);
		}
		NSPoint pointer = NSEvent.mouseLocation;
		NSUInteger edge = pointer.x < middle.x ? 1 : 0;
		[panel beginDrag];
		MoveOutputOnDisplay(panel, NSMakeSize(targets[edge].x - NSMinX(output.frame), targets[edge].y - NSMinY(output.frame)), bounds);
		ReleaseOutputDrag(panel, screen, bounds, middle);
		MoveOutputPointer(panel, grips[edge]);
		WaitForOutputGenie(panel);
		MoveOutputPointer(panel, pointer);
		if(!NSPointInRect(pointer, output.frame) && !NSEvent.pressedMouseButtons)
		{
			NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:1];
			while(!grip.parentWindow && deadline.timeIntervalSinceNow > 0)
				[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
			OAK_ASSERT(grip.parentWindow == owner && !output.parentWindow);
		}
		[panel showInWindow:owner];
		OAK_ASSERT(output.parentWindow == owner && !grip.parentWindow);
		[panel beginDrag];
		MoveOutputOnDisplay(panel, NSMakeSize(middle.x - NSMidX(output.frame), middle.y - NSMidY(output.frame)), bounds);
		ReleaseOutputDrag(panel, screen, bounds, middle);
		OAK_ASSERT(output.parentWindow == owner && !grip.parentWindow);
		[owner close];
		OAK_ASSERT(!output.parentWindow && !grip.parentWindow);
	});
}

void test_run_output_magnet_holds_through_overshoot_and_releases_after_an_inward_pull ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		NSRect bounds = NSMakeRect(0, 0, 1440, 900);
		NSWindow* owner = [[NSWindow alloc] initWithContentRect:NSMakeRect(420, 250, 600, 400)
			styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
		owner.releasedWhenClosed = NO;
		NSView* content = [NSView new];
		FloatingPanel* panel = [[FloatingPanel alloc] initWithContentView:content title:@"Output"];
		[panel showInWindow:owner];
		NSWindow* output = content.window;
		[output setFrameOrigin:NSMakePoint(60, 280)];
		[panel beginDrag];
		NSView* indicator = [panel valueForKey:@"magnetIndicator"];
		OAK_ASSERT(!MoveOutputOnDisplay(panel, NSMakeSize(-25, 0), bounds));
		OAK_ASSERT_GT(NSMinX(output.frame), 0);
		OAK_ASSERT_LT(NSMinX(output.frame), 35);
		OAK_ASSERT(!indicator.isHidden && indicator.alphaValue > 0 && indicator.alphaValue < 1);
		OAK_ASSERT(MoveOutputOnDisplay(panel, NSMakeSize(-23, 0), bounds));
		OAK_ASSERT_EQ(indicator.alphaValue, 1);
		OAK_ASSERT_EQ(NSMinX(output.frame), 0);
		OAK_ASSERT(!MoveOutputOnDisplay(panel, NSMakeSize(12, 20), bounds));
		OAK_ASSERT_EQ(NSMinX(output.frame), 0);
		OAK_ASSERT_EQ(NSMinY(output.frame), 300);
		OAK_ASSERT(!MoveOutputOnDisplay(panel, NSMakeSize(-80, 0), bounds));
		OAK_ASSERT(!MoveOutputOnDisplay(panel, NSMakeSize(32, 0), bounds));
		OAK_ASSERT_EQ(NSMinX(output.frame), 0);
		OAK_ASSERT(!MoveOutputOnDisplay(panel, NSMakeSize(4, 0), bounds));
		OAK_ASSERT_GT(NSMinX(output.frame), 0);
		OAK_ASSERT(MoveOutputOnDisplay(panel, NSMakeSize(-90, 0), bounds));
		OAK_ASSERT_EQ(NSMinX(output.frame), 0);
		ReleaseOutputDrag(panel, nil, bounds, NSMakePoint(2, 400));
		OAK_ASSERT(!output.parentWindow && indicator.isHidden);
		[owner close];
	});
}

void test_run_output_crosses_displays_without_tucking_at_the_seam ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		NSRect left = NSMakeRect(-1440, 120, 1440, 900);
		NSRect right = NSMakeRect(0, 0, 1600, 1000);
		NSWindow* owner = [[NSWindow alloc] initWithContentRect:NSMakeRect(-950, 350, 600, 400)
			styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
		owner.releasedWhenClosed = NO;
		[owner orderFront:nil];
		NSView* content = [NSView new];
		FloatingPanel* panel = [[FloatingPanel alloc] initWithContentView:content title:@"Output"];
		[panel showInWindow:owner];
		NSWindow* output = content.window;
		NSWindow* grip = [panel valueForKey:@"gripWindow"];
		CGFloat width = NSWidth(output.frame);
		[output setFrameOrigin:NSMakePoint(-width-70, 350)];
		[panel beginDrag];
		OAK_ASSERT(!MoveOutputOnDisplay(panel, NSZeroSize, left));
		OAK_ASSERT(MoveOutputOnDisplay(panel, NSMakeSize(62, 0), left));
		OAK_ASSERT_EQ(NSMaxX(output.frame), 0);

		PrepareOutputDisplay(panel, @(-1));
		OAK_ASSERT(!output.parentWindow && (output.collectionBehavior & NSWindowCollectionBehaviorCanJoinAllSpaces));
		OAK_ASSERT(!MoveOutputOnDisplay(panel, NSMakeSize(40, 15), right));
		OAK_ASSERT_EQ(NSMinX(output.frame), 32 - width);
		OAK_ASSERT(!MoveOutputOnDisplay(panel, NSMakeSize(width - 24, 0), right));
		OAK_ASSERT_EQ(NSMinX(output.frame), 8);
		ReleaseOutputDrag(panel, nil, right, NSMakePoint(width / 2, 650));
		OAK_ASSERT(output.isVisible && !output.parentWindow && !grip.isVisible && NSContainsRect(right, output.frame));

		[panel beginDrag];
		OAK_ASSERT(!MoveOutputOnDisplay(panel, NSMakeSize(180, 20), right));
		OAK_ASSERT(MoveOutputOnDisplay(panel, NSMakeSize(4 - NSMinX(output.frame), 10), right));
		OAK_ASSERT_EQ(NSMinX(output.frame), 0);
		OAK_ASSERT_EQ(NSMinY(output.frame), 395);
		ReleaseOutputDrag(panel, nil, right, NSMakePoint(width / 2, 675));
		OAK_ASSERT(!output.isVisible && grip.isVisible && !grip.parentWindow && NSContainsRect(right, grip.frame));
		MoveOutputPointer(panel, NSMakePoint(NSMidX(grip.frame), NSMidY(grip.frame)));
		WaitForOutputGenie(panel);
		OAK_ASSERT(output.isVisible && !output.parentWindow && !grip.isVisible && NSContainsRect(right, output.frame));

		[panel beginDrag];
		PrepareOutputDisplay(panel, owner.screen.deviceDescription[@"NSScreenNumber"]);
		OAK_ASSERT(MoveOutputOnDisplay(panel, NSMakeSize(NSMinX(left) + 6, 0), left));
		OAK_ASSERT_EQ(NSMinX(output.frame), NSMinX(left));
		ReleaseOutputDrag(panel, nil, left, NSMakePoint(NSMinX(left) + 30, 675));
		OAK_ASSERT(grip.parentWindow == owner && NSContainsRect(left, grip.frame));
		[panel showInWindow:owner];
		PrepareOutputDisplay(panel, @(-1));
		[panel showInWindow:owner];
		OAK_ASSERT(output.isVisible && !output.parentWindow);
		[owner close];
		OAK_ASSERT(!output.isVisible && !grip.isVisible && ![panel valueForKey:@"genieWindow"]);
	});
}

void test_run_output_pin_keeps_a_docked_panel_expanded_and_unpin_restores_tucking ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		NSScreen* screen = NSScreen.mainScreen;
		NSRect bounds = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
		NSWindow* owner = [[NSWindow alloc] initWithContentRect:NSMakeRect(NSMidX(bounds)-300, NSMidY(bounds)-200, 600, 400)
			styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
		owner.releasedWhenClosed = NO;
		[owner orderFront:nil];
		NSView* content = [NSView new];
		FloatingPanel* panel = [[FloatingPanel alloc] initWithContentView:content title:@"Output"];
		[panel showInWindow:owner];
		NSPanel* output = (NSPanel*)content.window;
		NSWindow* grip = [panel valueForKey:@"gripWindow"];
		NSPoint middle = NSMakePoint(NSMidX(bounds), NSMidY(bounds));
		[panel beginDrag];
		OAK_ASSERT(MoveOutputOnDisplay(panel, NSMakeSize(NSMinX(bounds) + 4 - NSMinX(output.frame), middle.y - NSMidY(output.frame)), bounds));
		ReleaseOutputDrag(panel, screen, bounds, middle);
		OAK_ASSERT(grip.isVisible && !output.isVisible);

		panel.pinned = YES;
		OAK_ASSERT(output.isVisible && !grip.isVisible && !output.parentWindow && !output.hidesOnDeactivate);
		OAK_ASSERT(![panel valueForKey:@"genieWindow"]);
		OAK_ASSERT_EQ(output.level, NSFloatingWindowLevel);
		OAK_ASSERT(output.collectionBehavior & NSWindowCollectionBehaviorCanJoinAllSpaces);
		[panel beginDrag];
		MoveOutputOnDisplay(panel, NSMakeSize(0, 15), bounds);
		ReleaseOutputDrag(panel, screen, bounds, middle);
		MoveOutputPointer(panel, middle);
		OAK_ASSERT_EQ(NSMinX(output.frame), NSMinX(bounds));
		OAK_ASSERT(output.isVisible && !grip.isVisible && ![panel valueForKey:@"tuckTimer"]);

		panel.pinned = NO;
		OAK_ASSERT(output.parentWindow == owner && output.hidesOnDeactivate && !(output.collectionBehavior & NSWindowCollectionBehaviorCanJoinAllSpaces));
		[panel beginDrag];
		ReleaseOutputDrag(panel, screen, bounds, middle);
		OAK_ASSERT(grip.isVisible && !output.isVisible);
		[owner close];
		OAK_ASSERT(!output.isVisible && !grip.isVisible && ![panel valueForKey:@"genieWindow"]);
	});
}

void test_run_configuration_menu_opens_below_button_and_keeps_selection_on_reload ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		NSURL* base = RunFixtureDirectory();
		NSString* launch = @"{\"configurations\":[{\"name\":\"Launch the GUI with a long configuration name\",\"type\":\"go\",\"request\":\"launch\"}]}";
		NSString* tasks = @"{\"tasks\":[{\"label\":\"Build\",\"type\":\"process\",\"command\":\"echo\"}]}";
		NSURL* app = RunFixtureFolder(base, @"app", tasks, launch);
		NSURL* worker = RunFixtureFolder(base, @"worker", nil, launch);
		__block NSArray* folders = @[ @{ @"path": app.path, @"name": @"App" } ];
		RunPanelController* panel = [RunPanelController new];
		panel.foldersProvider = ^{ return folders; };
		NSRect frame = NSMakeRect(0, 0, 180, 400);
		NSWindow* window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		window.releasedWhenClosed = NO;
		window.contentView = panel.view;
		RunConfigurationMenuProbe* menu = [RunConfigurationMenuProbe new];
		[panel setValue:menu forKey:@"configurationMenu"];
		[panel refresh:nil];
		[window setContentSize:frame.size];
		[window layoutIfNeeded];

		NSButton* button = [panel valueForKey:@"configurationButton"];
		NSButton* run = [panel valueForKey:@"runButton"];
		NSButton* gear = [panel valueForKey:@"configureButton"];
		NSRect buttonFrame = [button convertRect:button.bounds toView:panel.view];
		NSRect launchFrame = [run convertRect:run.bounds toView:panel.view];
		NSRect gearFrame = [gear convertRect:gear.bounds toView:panel.view];
		OAK_ASSERT_GT(NSWidth(buttonFrame), 0);
		OAK_ASSERT_LE(NSMaxX(launchFrame), NSMinX(buttonFrame));
		OAK_ASSERT_LE(NSMaxX(buttonFrame), NSMinX(gearFrame));
		OAK_ASSERT([button.title isEqual:@"Launch the GUI with a long configuration name"] && !button.bordered);
		[button performClick:nil];
		OAK_ASSERT(menu.opened && menu.numberOfItems == 2);
		[menu performActionForItemAtIndex:1];
		OAK_ASSERT([button.title isEqual:@"Build (Task)"] && menu.itemArray[1].state == NSControlStateValueOn);

		folders = [folders arrayByAddingObject:@{ @"path": worker.path, @"name": @"Worker" }];
		[panel refresh:nil];
		OAK_ASSERT([button.title isEqual:@"Build — App (Task)"] && menu.itemArray[1].state == NSControlStateValueOn);
		OAK_ASSERT([menu.itemArray[2].title hasSuffix:@" — Worker"] && !panel.isRunning);
		[window close];
		[NSFileManager.defaultManager removeItemAtURL:base error:nil];
	});
}

void test_run_sidebar_keeps_sections_at_top_and_scrolls_overflow ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		RunPanelController* panel = [RunPanelController new];
		NSMutableArray* breakpoints = [NSMutableArray array];
		for(NSUInteger line = 1; line <= 30; ++line)
			[breakpoints addObject:@{ @"line": @(line) }];
		panel.breakpointsProvider = ^{ return @{ @"/project/main.go": breakpoints }; };

		NSRect frame = NSMakeRect(0, 0, 250, 400);
		NSWindow* window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		window.releasedWhenClosed = NO;
		window.contentView = panel.view;
		[window setContentSize:frame.size];
		[window layoutIfNeeded];

		NSScrollView* scroll = nil;
		for(NSView* view in panel.view.subviews)
		{
			if([view isKindOfClass:NSScrollView.class])
				scroll = (NSScrollView*)view;
		}
		OAK_ASSERT(scroll);
		NSStackView* sections = (NSStackView*)scroll.documentView.subviews.firstObject;
		NSView* firstSection = sections.arrangedSubviews.firstObject;
		void (^checkCollapsedLayout)(void) = ^{
			NSRect firstFrame = [firstSection convertRect:firstSection.bounds toView:panel.view];
			OAK_ASSERT_EQ(NSMaxY(firstFrame), NSMaxY(scroll.frame));
			OAK_ASSERT_LE(NSHeight(scroll.documentView.frame), scroll.contentSize.height);
			OAK_ASSERT_EQ(scroll.contentSize.width, NSWidth(scroll.bounds));
		};
		checkCollapsedLayout();
		OAK_ASSERT(scroll.autohidesScrollers);
		OAK_ASSERT(scroll.scrollerStyle == NSScrollerStyleOverlay);

		NSView* breakpointSection = sections.arrangedSubviews[3];
		NSButton* heading = [breakpointSection valueForKey:@"heading"];
		[heading performClick:nil];
		[window layoutIfNeeded];
		OAK_ASSERT_GT(NSHeight(scroll.documentView.frame), scroll.contentSize.height);
		NSStackView* rows = [panel valueForKey:@"breakpointRows"];
		NSView* lastRow = rows.arrangedSubviews.lastObject;
		NSRect lastFrame = [lastRow convertRect:lastRow.bounds toView:scroll.documentView];
		OAK_ASSERT(!NSContainsRect(scroll.documentVisibleRect, lastFrame));
		[scroll.documentView scrollRectToVisible:lastFrame];
		OAK_ASSERT(NSContainsRect(scroll.documentVisibleRect, lastFrame));

		[heading performClick:nil];
		[window layoutIfNeeded];
		checkCollapsedLayout();
		[window close];
	});
}

void test_run_section_keeps_its_collapse_state_when_the_sidebar_is_hidden_and_restored ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		DocumentWindowController* controller = [DocumentWindowController new];
		controller.fileBrowserVisible = YES;
		controller.outlineVisible = YES;
		[controller showRunPanel:nil];
		ProjectLayoutView* layout = [controller valueForKey:@"layoutView"];
		NSView* run = layout.runAndDebugView;
		NSButton* runHeader = [layout valueForKey:@"runAndDebugHeader"];
		NSButton* sidebarButton = [controller valueForKey:@"sidebarButton"];
		[runHeader performClick:nil];
		[sidebarButton performClick:nil];
		OAK_ASSERT(!layout.fileBrowserView && !layout.outlineView && !layout.runAndDebugView);
		[sidebarButton performClick:nil];
		OAK_ASSERT(layout.fileBrowserView.superview && layout.outlineView.superview && runHeader.superview);
		OAK_ASSERT(layout.runAndDebugView == run && layout.runAndDebugCollapsed && !run.superview);

		RunPanelController* panel = [controller valueForKey:@"runPanelController"];
		panel.watchExpressions = @[ @"value + 1" ];
		NSDictionary* state = ((NSDictionary*(*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(sessionInfoIncludingUntitledDocuments:), YES);
		DocumentWindowController* restored = [DocumentWindowController new];
		((void(*)(id, SEL, NSDictionary*, BOOL))objc_msgSend)(restored, @selector(setupControllerForProject:skipMissingFiles:), state, NO);
		ProjectLayoutView* restoredLayout = [restored valueForKey:@"layoutView"];
		OAK_ASSERT(restoredLayout.runAndDebugView && restoredLayout.runAndDebugCollapsed && !restoredLayout.runAndDebugView.superview);
		OAK_ASSERT(([[(RunPanelController*)[restored valueForKey:@"runPanelController"] watchExpressions] isEqual:@[ @"value + 1" ]]));
		[restored showRunPanel:nil];
		OAK_ASSERT(restoredLayout.runAndDebugView.superview == restoredLayout.fileBrowserView.superview);
		OAK_ASSERT(restoredLayout.runAndDebugView.superview == restoredLayout.outlineView.superview);

		[restored close];
		[controller close];
		[DocumentWindowController enableSessionSave];
	});
}
