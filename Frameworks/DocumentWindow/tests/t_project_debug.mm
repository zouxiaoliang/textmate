#import "../src/DebugAdapterFraming.h"
#import "../src/DocumentWindowController.h"
#import "../src/ProjectDebugSessionProtocol.h"
#import "../src/ProjectRun.h"
#import "../src/RunPanelController.h"
#import <OakTextView/OakDocumentView.h>
#import <document/OakDocument.h>
#import <document/OakDocumentController.h>
#include <signal.h>

void test_debug_framing_preserves_byte_lengths_and_handles_coalesced_frames ()
{
	NSDictionary* first = @{ @"type": @"event", @"event": @"output", @"body": @{ @"output": @"你好\n" } };
	NSDictionary* second = @{ @"type": @"event", @"event": @"stopped" };
	NSMutableData* wire = [DebugAdapterEncodeMessage(first) mutableCopy];
	[wire appendData:DebugAdapterEncodeMessage(second)];
	DebugAdapterFraming* parser = [DebugAdapterFraming new];
	NSMutableArray* messages = [NSMutableArray array];
	for(NSUInteger offset = 0; offset < wire.length; ++offset)
	{
		NSError* error = nil;
		NSArray* decoded = [parser consumeData:[wire subdataWithRange:NSMakeRange(offset, 1)] error:&error];
		OAK_ASSERT(decoded && !error);
		[messages addObjectsFromArray:decoded];
	}
	OAK_ASSERT(([messages isEqual:@[first, second]]));
	OAK_ASSERT(([[parser consumeData:wire error:nil] isEqual:@[first, second]]));
}

void test_debug_framing_rejects_bad_headers_and_invalid_messages ()
{
	for(NSString* wire in @[ @"Content-Length: -1\r\n\r\n", @"Content-Length: 9000000\r\n\r\n",
	                        @"Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}", @"Content-Length: 2\r\n\r\n[]",
	                        [@"" stringByPaddingToLength:4100 withString:@"X" startingAtIndex:0] ])
	{
		NSError* error = nil;
		OAK_ASSERT(![[DebugAdapterFraming new] consumeData:[wire dataUsingEncoding:NSASCIIStringEncoding] error:&error]);
		OAK_ASSERT(error != nil);
	}
}

static NSArray<NSDictionary*>* TakeDebugRequests(ProjectDebugSession* session)
{
	NSData* bytes = [session pendingRequestBytes];
	NSError* error = nil;
	NSArray* decoded = [[DebugAdapterFraming new] consumeData:bytes error:&error];
	OAK_ASSERT(decoded && !error);
	[session didWriteRequestBytes:bytes.length];
	return decoded;
}

static NSDictionary* ExpectDebugRequest(ProjectDebugSession* session, NSString* command)
{
	NSArray* requests = TakeDebugRequests(session);
	OAK_ASSERT(requests.count == 1 && [requests.firstObject[@"command"] isEqual:command]);
	return requests.firstObject;
}

static void DebugEvent(ProjectDebugSession* session, NSString* event, NSDictionary* body)
{
	[session receiveBytes:DebugAdapterEncodeMessage(@{ @"type": @"event", @"event": event, @"body": body ?: @{} })];
}

static void DebugReplyWithBody(ProjectDebugSession* session, NSDictionary* request, NSDictionary* body)
{
	[session receiveBytes:DebugAdapterEncodeMessage(@{ @"type": @"response", @"request_seq": request[@"seq"], @"command": request[@"command"],
	                                                   @"success": @YES, @"body": body ?: @{} })];
}

static NSButton* DebugButtonWithTitle(NSView* view, NSString* title)
{
	if([view isKindOfClass:NSButton.class] && [[(NSButton*)view title] isEqual:title])
		return (NSButton*)view;
	for(NSView* child in view.subviews)
	{
		if(NSButton* button = DebugButtonWithTitle(child, title))
			return button;
	}
	return nil;
}

void test_debug_protocol_configures_breakpoints_and_can_inspect_step_and_stop_without_a_process ()
{
	ProjectDebugSession* session = [ProjectDebugSession new];
	NSString* source = @"/example/main.go";
	NSDictionary* launch = @{ @"mode": @"debug", @"program": @".", @"stopOnEntry": @YES };
	NSDictionary* conditional = @{ @"line": @5, @"condition": @"value > 0", @"hitCondition": @">= 3" };
	NSDictionary* logpoint = @{ @"line": @10, @"logMessage": @"value = {value}" };
	[session beginSessionWithLaunchArguments:launch breakpoints:@{ source: @[ conditional, @{ @"line": @9, @"enabled": @NO }, logpoint ] }];
	[session transportDidConnect];
	NSDictionary* initialize = ExpectDebugRequest(session, @"initialize");
	OAK_ASSERT([initialize[@"arguments"][@"linesStartAt1"] isEqual:@YES]);
	DebugReplyWithBody(session, @{ @"seq": @9000, @"command": @"initialize" }, @{ @"supportsConfigurationDoneRequest": @YES });
	OAK_ASSERT(TakeDebugRequests(session).count == 0);
	DebugReplyWithBody(session, initialize, @{ @"supportsConfigurationDoneRequest": @YES });
	NSDictionary* start = ExpectDebugRequest(session, @"launch");
	OAK_ASSERT([start[@"arguments"] isEqual:launch] && session.state == ProjectDebugStarting);

	DebugEvent(session, @"initialized", nil);
	DebugReplyWithBody(session, start, nil);
	NSArray* configuration = TakeDebugRequests(session);
	OAK_ASSERT(configuration.count == 2 && [configuration[0][@"command"] isEqual:@"setBreakpoints"] && [configuration[1][@"command"] isEqual:@"configurationDone"]);
	OAK_ASSERT([configuration[0][@"arguments"][@"source"][@"path"] isEqual:source]);
	OAK_ASSERT(([configuration[0][@"arguments"][@"breakpoints"] isEqual:@[ conditional, logpoint ]]));
	DebugReplyWithBody(session, configuration[0], @{ @"breakpoints": @[ @{ @"verified": @YES, @"line": @5 } ] });

	DebugEvent(session, @"stopped", @{ @"reason": @"entry", @"threadId": @1 });
	OAK_ASSERT(session.state == ProjectDebugPaused && !session.canStep && TakeDebugRequests(session).count == 0);
	DebugReplyWithBody(session, configuration[1], nil);
	NSDictionary* stack = ExpectDebugRequest(session, @"stackTrace");
	OAK_ASSERT(session.canStep && [stack[@"arguments"][@"threadId"] isEqual:@1]);
	NSDictionary* frame = @{ @"id": @10, @"line": @5, @"source": @{ @"path": source }, @"name": @"main.main" };
	DebugReplyWithBody(session, stack, @{ @"stackFrames": @[ frame ] });
	OAK_ASSERT([session.frames.firstObject isEqual:frame]);

	__block NSArray* variables = nil;
	session.didChangeVariables = ^(NSArray* values){ variables = values; };
	[session selectFrame:frame];
	NSDictionary* scopes = ExpectDebugRequest(session, @"scopes");
	OAK_ASSERT([scopes[@"arguments"][@"frameId"] isEqual:@10]);
	DebugReplyWithBody(session, scopes, @{ @"scopes": @[ @{ @"name": @"Locals", @"variablesReference": @20 } ] });
	NSDictionary* values = ExpectDebugRequest(session, @"variables");
	OAK_ASSERT([values[@"arguments"][@"variablesReference"] isEqual:@20]);
	DebugReplyWithBody(session, values, @{ @"variables": @[ @{ @"name": @"value", @"value": @"41", @"variablesReference": @21 } ] });
	OAK_ASSERT(variables.count == 1 && [variables.firstObject[@"value"] isEqual:@"41"]);

	__block NSDictionary* watchValue = nil;
	[session evaluateWatchExpression:@" value + 1 " completion:^(NSDictionary* value, NSString* error){
		OAK_ASSERT(!error);
		watchValue = value;
	}];
	NSDictionary* evaluate = ExpectDebugRequest(session, @"evaluate");
	OAK_ASSERT(([evaluate[@"arguments"] isEqual:@{ @"expression": @"value + 1", @"frameId": @10, @"context": @"watch" }]));
	DebugReplyWithBody(session, evaluate, @{ @"result": @"42" });
	OAK_ASSERT([watchValue[@"result"] isEqual:@"42"]);
	__block NSString* rejected = nil;
	for(NSString* expression in @[ @"call f()", @" dlv\tconfig " ])
	{
		[session evaluateWatchExpression:expression completion:^(NSDictionary* value, NSString* error){ rejected = error; }];
		OAK_ASSERT(rejected.length && !TakeDebugRequests(session).count);
		rejected = nil;
	}
	[session loadChildrenOfVariable:variables.firstObject[@"variablesReference"] completion:^(NSArray* children, NSString* error){
		OAK_ASSERT(!error && [children.firstObject[@"name"] isEqual:@"field"]);
	}];
	NSDictionary* children = ExpectDebugRequest(session, @"variables");
	OAK_ASSERT([children[@"arguments"][@"variablesReference"] isEqual:@21]);
	DebugReplyWithBody(session, children, @{ @"variables": @[ @{ @"name": @"field", @"value": @"41" } ] });
	[session evaluateWatchExpression:@"value" completion:^(NSDictionary* value, NSString* error){ OAK_ASSERT(false); }];
	NSDictionary* staleWatch = ExpectDebugRequest(session, @"evaluate");
	__block NSArray* goroutines = nil;
	[session loadThreads:^(NSArray* threads, NSString* error){ goroutines = threads; }];
	NSDictionary* threadsRequest = ExpectDebugRequest(session, @"threads");
	DebugReplyWithBody(session, threadsRequest, @{ @"threads": @[ @{ @"id": @1, @"name": @"main" }, @{ @"id": @2, @"name": @"worker" } ] });
	OAK_ASSERT(goroutines.count == 2);
	[session selectThread:goroutines.lastObject[@"id"]];
	NSDictionary* workerStack = ExpectDebugRequest(session, @"stackTrace");
	OAK_ASSERT([workerStack[@"arguments"][@"threadId"] isEqual:@2] && [session.stoppedThreadID isEqual:@1] && !variables.count);
	DebugReplyWithBody(session, staleWatch, @{ @"result": @"41" });
	NSDictionary* workerFrame = @{ @"id": @11, @"line": @12, @"source": @{ @"path": source }, @"name": @"main.worker" };
	DebugReplyWithBody(session, workerStack, @{ @"stackFrames": @[ workerFrame ] });
	OAK_ASSERT([session.frames.firstObject isEqual:workerFrame]);
	[session selectFrame:workerFrame];
	OAK_ASSERT([ExpectDebugRequest(session, @"scopes")[@"arguments"][@"frameId"] isEqual:@11]);
	[session evaluateWatchExpression:@"value" completion:^(NSDictionary* value, NSString* error){ OAK_ASSERT(false); }];
	NSDictionary* workerWatch = ExpectDebugRequest(session, @"evaluate");
	OAK_ASSERT([workerWatch[@"arguments"][@"frameId"] isEqual:@11]);
	[session stepOver];
	NSDictionary* step = ExpectDebugRequest(session, @"next");
	OAK_ASSERT(session.state == ProjectDebugRunning && session.canPause && !variables.count && !session.frames.count);
	OAK_ASSERT([step[@"arguments"][@"threadId"] isEqual:@2]);
	DebugReplyWithBody(session, workerWatch, @{ @"result": @"43" });
	DebugReplyWithBody(session, step, nil);
	[session pause];
	NSDictionary* pause = ExpectDebugRequest(session, @"pause");
	OAK_ASSERT(!session.canPause && [pause[@"arguments"][@"threadId"] isEqual:@1]);
	DebugReplyWithBody(session, pause, nil);
	DebugEvent(session, @"stopped", @{ @"reason": @"pause", @"threadId": @1 });
	ExpectDebugRequest(session, @"stackTrace");
	OAK_ASSERT(session.canStep);

	[session setBreakpoints:@[] forPath:source];
	NSDictionary* clear = ExpectDebugRequest(session, @"setBreakpoints");
	OAK_ASSERT([clear[@"arguments"][@"breakpoints"] count] == 0);
	[session stop];
	NSDictionary* disconnect = ExpectDebugRequest(session, @"disconnect");
	OAK_ASSERT(session.state == ProjectDebugStopping && [disconnect[@"arguments"][@"terminateDebuggee"] isEqual:@YES]);
	DebugEvent(session, @"stopped", @{ @"threadId": @1 });
	OAK_ASSERT(session.state == ProjectDebugStopping && !session.canStep && TakeDebugRequests(session).count == 0);
}

static NSString* DebugFixture(NSDictionary* launch)
{
	NSString* path = [[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] stringByResolvingSymlinksInPath];
	NSString* configuration = [path stringByAppendingPathComponent:@".vscode"];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:configuration withIntermediateDirectories:YES attributes:nil error:nil]);
	path = path.stringByResolvingSymlinksInPath;
	OAK_ASSERT([[NSJSONSerialization dataWithJSONObject:@{ @"configurations": @[ launch ] } options:0 error:nil] writeToFile:[configuration stringByAppendingPathComponent:@"launch.json"] atomically:YES]);
	return path;
}

static ProjectRunConfiguration* DebugConfiguration(NSString* root)
{
	return [ProjectRunConfiguration configurationsForFolders:@[ @{ @"name": @"Fixture", @"path": root } ] errors:nil].firstObject;
}

void test_debug_plan_resolves_its_own_paths_and_rejects_unsupported_fields ()
{
	NSString* root = DebugFixture(@{ @"name": @"App", @"type": @"go", @"request": @"launch", @"program": @"${workspaceFolder}",
	                                @"stopOnEntry": @YES, @"args": @[ @"${workspaceFolderBasename}", @"two words" ],
	                                @"env": @{ @"DEBUG_ROOT": @"${workspaceFolder}" }, @"preLaunchTask": @"Prepare" });
	NSString* adapter = [root stringByAppendingPathComponent:@"dlv"];
	NSString* tasks = [root stringByAppendingPathComponent:@".vscode/tasks.json"];
	OAK_ASSERT([@"" writeToFile:adapter atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	OAK_ASSERT([NSFileManager.defaultManager setAttributes:@{ NSFilePosixPermissions: @0700 } ofItemAtPath:adapter error:nil]);
	OAK_ASSERT([@"{\"tasks\":[{\"label\":\"Prepare\",\"type\":\"process\",\"command\":\"/bin/echo\",\"args\":[\"${workspaceFolder}\"]}]}" writeToFile:tasks atomically:YES encoding:NSUTF8StringEncoding error:nil]);

	ProjectRunConfiguration* configuration = DebugConfiguration(root);
	NSError* error = nil;
	ProjectDebugPlan* plan = [configuration debugPlanForFile:nil environment:@{ @"PATH": root } error:&error];
	OAK_ASSERT(!error && configuration.supportsDebugging && plan.tasks.count == 1);
	OAK_ASSERT([plan.tasks.firstObject.arguments.firstObject isEqual:root]);
	OAK_ASSERT([plan.adapter.executable isEqual:adapter] && [plan.adapter.environment[@"DEBUG_ROOT"] isEqual:root]);
	OAK_ASSERT([plan.launchArguments[@"program"] isEqual:@"."] && [plan.launchArguments[@"cwd"] isEqual:root]);
	OAK_ASSERT(([plan.launchArguments[@"args"] isEqual:@[ root.lastPathComponent, @"two words" ]]));
	OAK_ASSERT([plan.launchArguments[@"stopOnEntry"] isEqual:@YES]);
	[NSFileManager.defaultManager removeItemAtPath:root error:nil];

	for(NSDictionary* config in @[ @{ @"request": @"attach" }, @{ @"mode": @"remote" },
	                                @{ @"host": @"localhost" }, @{ @"stopOnEntry": @1 } ])
	{
		NSMutableDictionary* launch = [@{ @"name": @"App", @"type": @"go", @"request": @"launch", @"program": @"." } mutableCopy];
		[launch addEntriesFromDictionary:config];
		root = DebugFixture(launch);
		error = nil;
		OAK_ASSERT(![DebugConfiguration(root) debugPlanForFile:nil environment:@{} error:&error] && error);
		[NSFileManager.defaultManager removeItemAtPath:root error:nil];
	}
}

void test_go_build_flags_resolve_for_gbot_style_run_and_debug_launches ()
{
	for(id setting in @[ @"-tags dev '-ldflags=-X main.Title=Some words' '-overlay=${workspaceFolder}/debug overlay.json'",
	                     @[ @"-tags", @"dev", @"-ldflags=-X main.Title=Some words", @"-overlay=${workspaceFolder}/debug overlay.json" ] ])
	{
		NSString* root = DebugFixture(@{ @"name": @"GUI", @"type": @"go", @"request": @"launch", @"mode": @"debug",
		                                 @"program": @"${workspaceFolder}/app/gbot-gui", @"buildFlags": setting, @"args": @[ @"--windowed" ] });
		NSFileManager* files = NSFileManager.defaultManager;
		NSString* subdirectory = [root stringByAppendingPathComponent:@"app/gbot-gui"];
		OAK_ASSERT([files createDirectoryAtPath:subdirectory withIntermediateDirectories:YES attributes:nil error:nil]);
		for(NSString* executable in @[ @"go", @"dlv" ])
			OAK_ASSERT([files createSymbolicLinkAtPath:[root stringByAppendingPathComponent:executable] withDestinationPath:@"/usr/bin/true" error:nil]);
		NSString* overlay = [@"-overlay=" stringByAppendingString:[root stringByAppendingPathComponent:@"debug overlay.json"]];
		NSArray* flags = @[ @"-tags", @"dev", @"-ldflags=-X main.Title=Some words", overlay ];
		ProjectRunConfiguration* config = DebugConfiguration(root);
		NSError* error = nil;
		ProjectRunCommand* run = [config commandsForFile:nil environment:@{ @"PATH": root } error:&error].lastObject;
		NSArray* runArguments = [[@[ @"run" ] arrayByAddingObjectsFromArray:flags] arrayByAddingObjectsFromArray:@[ @".", @"--windowed" ]];
		OAK_ASSERT(!error && [run.arguments isEqual:runArguments] && [run.directory isEqual:subdirectory]);
		ProjectDebugPlan* debug = [config debugPlanForFile:nil environment:@{ @"PATH": root } error:&error];
		OAK_ASSERT(!error && [debug.launchArguments[@"buildFlags"] isEqual:flags] && [debug.launchArguments[@"cwd"] isEqual:subdirectory]);
		OAK_ASSERT(([debug.launchArguments[@"args"] isEqual:@[ @"--windowed" ]]));
		[files removeItemAtPath:root error:nil];
	}

	for(id invalid in @[ @12, @[ @12 ], @"-tags dev && echo unwanted", @"-tags 'unclosed" ])
	{
		NSString* root = DebugFixture(@{ @"name": @"App", @"type": @"go", @"request": @"launch", @"program": @".", @"buildFlags": invalid });
		NSError* error = nil;
		ProjectRunConfiguration* config = DebugConfiguration(root);
		OAK_ASSERT(![config commandsForFile:nil environment:@{} error:&error] && error);
		OAK_ASSERT(![config debugPlanForFile:nil environment:@{} error:&error] && error);
		OAK_ASSERT(![error.localizedDescription containsString:@"not found"]);
		[NSFileManager.defaultManager removeItemAtPath:root error:nil];
	}
}

static BOOL WaitForDebug(BOOL (^condition)(void), NSTimeInterval seconds)
{
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
	while(!condition() && deadline.timeIntervalSinceNow > 0)
		[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
	return condition();
}

static void StartDebugFixture(RunPanelController* panel, ProjectRunConfiguration* configuration, ProjectDebugPlan* plan)
{
	SEL start = NSSelectorFromString(@"startCommands:configuration:debugPlan:");
	((void(*)(id, SEL, id, id, id))objc_msgSend)(panel, start, nil, configuration, plan);
}

void test_debug_adapter_failure_reports_output_and_cleans_its_private_directory ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSString* root = DebugFixture(@{ @"name": @"App", @"type": @"go", @"request": @"launch", @"program": @"." });
		NSString* adapter = [root stringByAppendingPathComponent:@"dlv"];
		OAK_ASSERT([@"#!/bin/sh\nprintf '%s\\n' \"$3\"\nexit 3\n" writeToFile:adapter atomically:YES encoding:NSUTF8StringEncoding error:nil]);
		OAK_ASSERT([NSFileManager.defaultManager setAttributes:@{ NSFilePosixPermissions: @0700 } ofItemAtPath:adapter error:nil]);
		ProjectDebugPlan* plan = [DebugConfiguration(root) debugPlanForFile:nil environment:@{ @"PATH": root } error:nil];
		OAK_ASSERT(plan != nil);
		ProjectDebugSession* session = [ProjectDebugSession new];
		NSMutableString* output = [NSMutableString string];
		__block NSString* status = nil;
		session.didChangeState = ^(ProjectDebugState state, NSString* message){ status = message; };
		session.didReadOutput = ^(NSString* text){ [output appendString:text]; };
		[session start:plan breakpoints:@{}];
		OAK_ASSERT(session.state == ProjectDebugStarting);
		OAK_ASSERT(WaitForDebug(^BOOL{ return session.state == ProjectDebugIdle; }, 4));
		OAK_ASSERT([status containsString:@"code 3"] && [output hasPrefix:@"unix:/private/tmp/textmate-dap."]);
		NSString* path = [[output substringFromIndex:@"unix:".length] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
		OAK_ASSERT(![NSFileManager.defaultManager fileExistsAtPath:path.stringByDeletingLastPathComponent]);
		[NSFileManager.defaultManager removeItemAtPath:root error:nil];
	});
}

void test_debug_restart_reaps_the_old_adapter_before_launching_and_resending_breakpoints ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		NSString* root = DebugFixture(@{ @"name": @"App", @"type": @"go", @"request": @"launch", @"program": @"." });
		NSString* adapter = [root stringByAppendingPathComponent:@"dlv"];
		OAK_ASSERT([@"#!/bin/sh\nexec /bin/sleep 30\n" writeToFile:adapter atomically:YES encoding:NSUTF8StringEncoding error:nil]);
		OAK_ASSERT([NSFileManager.defaultManager setAttributes:@{ NSFilePosixPermissions: @0700 } ofItemAtPath:adapter error:nil]);
		ProjectRunConfiguration* configuration = DebugConfiguration(root);
		ProjectDebugPlan* plan = [configuration debugPlanForFile:nil environment:@{ @"PATH": root } error:nil];
		OAK_ASSERT(plan);
		NSString* source = [root stringByAppendingPathComponent:@"main.go"];
		NSDictionary* breakpoint = @{ @"line": @3, @"condition": @"value > 0" };
		RunPanelController* panel = [RunPanelController new];
		(void)panel.view;
		panel.breakpointsProvider = ^{ return @{ source: @[ breakpoint ] }; };
		ProjectDebugSession* session = [panel valueForKey:@"debugger"];
		pid_t (^adapterPID)(void) = ^{ return [(NSNumber*)[[session valueForKey:@"adapter"] valueForKey:@"child"] intValue]; };
		NSButton* restart = [panel valueForKey:@"debugRestartButton"];
		StartDebugFixture(panel, configuration, plan);
		pid_t firstAdapter = adapterPID();
		OAK_ASSERT(firstAdapter > 1 && restart.enabled);
		[restart performClick:nil];
		OAK_ASSERT(session.state == ProjectDebugStopping && adapterPID() == firstAdapter && !restart.enabled);
		OAK_ASSERT(WaitForDebug(^BOOL{ return session.state == ProjectDebugStarting && adapterPID() != firstAdapter; }, 4));
		pid_t secondAdapter = adapterPID();
		OAK_ASSERT(secondAdapter > 1 && kill(firstAdapter, 0) == -1 && errno == ESRCH && restart.enabled);

		[session transportDidConnect];
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"initialize"), @{ @"supportsConfigurationDoneRequest": @YES });
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"launch"), nil);
		DebugEvent(session, @"initialized", nil);
		NSArray* requests = TakeDebugRequests(session);
		OAK_ASSERT(requests.count == 2 && [requests[0][@"command"] isEqual:@"setBreakpoints"] && [requests[1][@"command"] isEqual:@"configurationDone"]);
		OAK_ASSERT([requests[0][@"arguments"][@"source"][@"path"] isEqual:source] && [requests[0][@"arguments"][@"breakpoints"] isEqual:@[ breakpoint ]]);
		DebugReplyWithBody(session, requests[1], nil);
		[panel stop:nil];
		OAK_ASSERT([ExpectDebugRequest(session, @"disconnect")[@"arguments"][@"terminateDebuggee"] isEqual:@YES]);
		OAK_ASSERT(kill(secondAdapter, SIGTERM) == 0);
		OAK_ASSERT(WaitForDebug(^BOOL{ return !panel.isRunning; }, 4));
		[panel invalidate];
		[NSFileManager.defaultManager removeItemAtPath:root error:nil];
	});
}

void test_debug_panel_exposes_breakpoint_toggle_without_launching_a_program ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSString* root = DebugFixture(@{ @"name": @"App", @"type": @"go", @"request": @"launch", @"program": @"." });
		NSString* source = [root stringByAppendingPathComponent:@"main.go"];
		OAK_ASSERT([@"lspEnabled = false\n" writeToFile:[root stringByAppendingPathComponent:@".tm_properties"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
		OAK_ASSERT([@"package main\n\nfunc main() {}\n" writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:nil]);
		DocumentWindowController* controller = [DocumentWindowController new];
		controller.defaultProjectPath = root;
		[controller showRunPanel:nil];
		[OakDocumentController.sharedInstance showDocument:[OakDocument documentWithPath:source] inProject:controller.identifier bringToFront:NO];
		OAK_ASSERT(WaitForDebug(^BOOL{ return [controller.selectedDocument.path isEqual:source]; }, 3));
		RunPanelController* panel = [controller valueForKey:@"runPanelController"];
		NSButton* launch = [panel valueForKey:@"runButton"];
		OAK_ASSERT(launch.enabled && [launch.toolTip containsString:@"Start Debugging"] && !panel.isRunning);
		controller.textView.selectionString = @"3:1";
		[controller toggleProjectBreakpoint:nil];
		OAK_ASSERT([panel.breakpointsProvider()[source].firstObject[@"line"] isEqual:@3]);
		NSStackView* breakpoints = [panel valueForKey:@"breakpointRows"];
		NSButton* row = (NSButton*)breakpoints.arrangedSubviews.firstObject;
		OAK_ASSERT([row.title isEqual:@"main.go:3"]);
		[row.menu performActionForItemAtIndex:0];
		OAK_ASSERT([panel.breakpointsProvider()[source].firstObject[@"enabled"] isEqual:@NO]);
		row = (NSButton*)breakpoints.arrangedSubviews.firstObject;
		OAK_ASSERT([row.toolTip containsString:@"Disabled"]);
		[row.menu performActionForItemAtIndex:0];
		OAK_ASSERT([panel.breakpointsProvider()[source].firstObject[@"enabled"] isEqual:@YES]);
		OakDocumentView* editor = [controller valueForKey:@"documentView"];
		OAK_ASSERT(editor.toggleBreakpointAtLine != nil);
		row = (NSButton*)breakpoints.arrangedSubviews.firstObject;
		[row.menu performActionForItemAtIndex:2];
		OAK_ASSERT(!panel.breakpointsProvider().count);
		editor.toggleBreakpointAtLine(3);
		OAK_ASSERT([panel.breakpointsProvider()[source].firstObject[@"line"] isEqual:@3]);
		editor.toggleBreakpointAtLine(3);
		OAK_ASSERT(panel.breakpointsProvider().count == 0 && !panel.isRunning);

		editor.toggleBreakpointAtLine(3);
		ProjectDebugSession* session = [panel valueForKey:@"debugger"];
		[session beginSessionWithLaunchArguments:@{ @"program": @"." } breakpoints:panel.breakpointsProvider()];
		[session transportDidConnect];
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"initialize"), @{ @"supportsConfigurationDoneRequest": @YES });
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"launch"), nil);
		DebugEvent(session, @"initialized", nil);
		NSArray* initial = TakeDebugRequests(session);
		OAK_ASSERT(initial.count == 2 && [initial[0][@"command"] isEqual:@"setBreakpoints"] && [initial[1][@"command"] isEqual:@"configurationDone"]);
		row = (NSButton*)breakpoints.arrangedSubviews.firstObject;
		OAK_ASSERT([row.toolTip containsString:@"Waiting for Delve"] && [panel isBreakpointUnverifiedAtPath:source line:3]);
		OAK_ASSERT([(NSIndexSet*)[editor valueForKey:@"unverifiedDebugBreakpoints"] containsIndex:3]);
		panel.updateBreakpoint(source, 3, @{ @"condition": @"badExpression" });
		NSDictionary* edit = ExpectDebugRequest(session, @"setBreakpoints");
		DebugReplyWithBody(session, initial[0], @{ @"breakpoints": @[ @{ @"verified": @YES, @"line": @3 } ] });
		OAK_ASSERT([panel isBreakpointUnverifiedAtPath:source line:3] && ![session breakpointResultAtPath:source line:3]);
		DebugReplyWithBody(session, edit, @{ @"breakpoints": @[ @{ @"verified": @NO, @"message": @"Invalid condition" } ] });
		row = (NSButton*)breakpoints.arrangedSubviews.firstObject;
		OAK_ASSERT([row.toolTip containsString:@"Invalid condition"] && [row.accessibilityHelp isEqual:row.toolTip]);
		panel.updateBreakpoint(source, 3, @{});
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"setBreakpoints"), @{ @"breakpoints": @[ @{ @"verified": @YES, @"line": @4 } ] });
		DebugReplyWithBody(session, initial[1], nil);
		row = (NSButton*)breakpoints.arrangedSubviews.firstObject;
		OAK_ASSERT([row.toolTip containsString:@"Verified at line 4"] && ![panel isBreakpointUnverifiedAtPath:source line:3]);
		OAK_ASSERT(![(NSIndexSet*)[editor valueForKey:@"unverifiedDebugBreakpoints"] containsIndex:3]);
		__block NSUInteger revealed = 0;
		panel.showFrame = ^(NSString* path, NSUInteger line, BOOL executionLine){ if([path isEqual:source] && !executionLine) revealed = line; };
		[row performClick:nil];
		OAK_ASSERT(revealed == 4);
		[controller close];
		[NSFileManager.defaultManager removeItemAtPath:root error:nil];
		[DocumentWindowController enableSessionSave];
	});
}

void test_debug_pause_and_stack_frames_preserve_window_and_editor_width ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[DocumentWindowController disableSessionSave];
		NSString* root = DebugFixture(@{ @"name": @"Launch Package", @"type": @"go", @"request": @"launch", @"program": @"." });
		NSString* source = [root stringByAppendingPathComponent:@"main.go"];
		OAK_ASSERT([@"lspEnabled = false\n" writeToFile:[root stringByAppendingPathComponent:@".tm_properties"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
		OAK_ASSERT([@"package main\n\nfunc main() {}\n" writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:nil]);
		DocumentWindowController* controller = [DocumentWindowController new];
		controller.defaultProjectPath = root;
		[OakDocumentController.sharedInstance showDocument:[OakDocument documentWithPath:source] inProject:controller.identifier bringToFront:NO];
		OAK_ASSERT(WaitForDebug(^BOOL{ return [controller.selectedDocument.path isEqual:source]; }, 3));
		[controller showRunPanel:nil];
		NSWindow* window = controller.window;
		NSRect requested = window.frame;
		requested.size = NSMakeSize(620, 440);
		[window setFrame:requested display:NO];
		[window layoutIfNeeded];
		NSRect original = window.frame;
		OakDocumentView* editor = [controller valueForKey:@"documentView"];
		CGFloat editorWidth = NSWidth(editor.frame);
		RunPanelController* panel = [controller valueForKey:@"runPanelController"];
		ProjectDebugSession* session = [panel valueForKey:@"debugger"];
		NSStackView* frames = [panel valueForKey:@"frameRows"];
		NSButton* goroutines = [panel valueForKey:@"goroutinesButton"];
		NSStackView* variables = [panel valueForKey:@"variableRows"];
		NSBox* toolbar = [panel valueForKey:@"debugToolbar"];
		NSButton* primary = [panel valueForKey:@"debugActionButton"];
		NSButton* stop = [panel valueForKey:@"debugStopButton"];
		OAK_ASSERT(toolbar.hidden && toolbar.superview == editor.superview && ![toolbar isDescendantOf:panel.view]);

		[session beginSessionWithLaunchArguments:@{ @"program": @"." } breakpoints:@{}];
		[window layoutIfNeeded];
		OAK_ASSERT(NSEqualRects(original, window.frame) && !toolbar.hidden && !primary.enabled && stop.enabled);
		[session transportDidConnect];
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"initialize"), @{ @"supportsConfigurationDoneRequest": @YES });
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"launch"), nil);
		DebugEvent(session, @"initialized", nil);
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"configurationDone"), nil);
		DebugEvent(session, @"stopped", @{ @"reason": @"breakpoint", @"threadId": @1 });
		NSDictionary* stack = ExpectDebugRequest(session, @"stackTrace");
		NSString* longName = [@"main." stringByPaddingToLength:300 withString:@"longFunction" startingAtIndex:0];
		DebugReplyWithBody(session, stack, @{ @"stackFrames": @[
			@{ @"id": @10, @"name": longName, @"line": @3, @"source": @{ @"path": source } },
		] });
		[window layoutIfNeeded];
		OAK_ASSERT(NSEqualRects(original, window.frame) && NSWidth(editor.frame) == editorWidth);
		OAK_ASSERT([frames isDescendantOf:panel.view] && [variables isDescendantOf:panel.view]);
		OAK_ASSERT(goroutines.enabled && [goroutines.title isEqual:@"Goroutine 1"]);
		NSButton* frameRow = (NSButton*)frames.arrangedSubviews.firstObject;
		OAK_ASSERT([frameRow.title containsString:@"main.go:3"] && frameRow.isAccessibilitySelected);
		NSRect rowFrame = [frameRow convertRect:frameRow.bounds toView:panel.view];
		OAK_ASSERT_GT(NSWidth(rowFrame), 0);
		OAK_ASSERT_LE(NSMaxX(rowFrame), NSWidth(panel.view.bounds) + 1);
		OAK_ASSERT(NSWidth(toolbar.frame) > 150 && NSHeight(toolbar.frame) >= 30 && fabs(NSMidX(toolbar.frame) - NSMidX(editor.frame)) < 1);
		OAK_ASSERT(primary.enabled && [primary.toolTip isEqual:@"Continue (F5)"]);

		NSStackView* actions = (NSStackView*)toolbar.contentView.subviews.firstObject;
		NSPanGestureRecognizer* drag = (NSPanGestureRecognizer*)actions.arrangedSubviews.firstObject.gestureRecognizers.firstObject;
		CGFloat center = NSMidX(toolbar.frame);
		[drag setTranslation:NSMakePoint(1000, 0) inView:toolbar.superview];
		OAK_ASSERT([NSApp sendAction:drag.action to:drag.target from:drag]);
		OAK_ASSERT(NSMidX(toolbar.frame) > center && NSMaxX(toolbar.frame) <= NSMaxX(toolbar.superview.bounds)-7);

		DebugReplyWithBody(session, ExpectDebugRequest(session, @"scopes"), @{ @"scopes": @[ @{ @"name": @"Locals", @"variablesReference": @20 } ] });
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"variables"), @{ @"variables": @[ @{ @"name": @"value", @"value": @"41", @"variablesReference": @21 } ] });
		NSButton* valueNode = DebugButtonWithTitle(variables, @"value = 41");
		OAK_ASSERT(valueNode);
		[valueNode performClick:nil];
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"variables"), @{ @"variables": @[ @{ @"name": @"field", @"value": @"41" } ] });
		OAK_ASSERT(DebugButtonWithTitle(variables, @"field = 41"));

		NSButton* watchHeader = [[panel valueForKey:@"watchSection"] valueForKey:@"heading"];
		[watchHeader performClick:nil];
		NSTextField* watchInput = [panel valueForKey:@"watchInput"];
		watchInput.stringValue = @"value + 1";
		OAK_ASSERT([NSApp sendAction:watchInput.action to:watchInput.target from:watchInput]);
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"evaluate"), @{ @"result": @"42" });
		NSStackView* watchRows = [panel valueForKey:@"watchRows"];
		NSButton* watch = DebugButtonWithTitle(watchRows, @"value + 1 = 42");
		OAK_ASSERT(watch && panel.watchExpressions.count == 1);

		[panel stepOver:nil];
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"next"), nil);
		OAK_ASSERT(!DebugButtonWithTitle(watchRows, @"value + 1 = 42") && session.state == ProjectDebugRunning);
		NSTextView* output = [panel valueForKey:@"output"];
		DebugEvent(session, @"output", @{ @"category": @"console", @"output": @"fixture log: 42\n" });
		OAK_ASSERT([output.string containsString:@"fixture log: 42"] && session.state == ProjectDebugRunning);
		DebugEvent(session, @"stopped", @{ @"reason": @"step", @"threadId": @1 });
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"stackTrace"), @{ @"stackFrames": @[
			@{ @"id": @11, @"name": @"main.main", @"line": @4, @"source": @{ @"path": source } },
		] });
		NSArray* inspection = TakeDebugRequests(session);
		OAK_ASSERT(inspection.count == 2 && [inspection[0][@"command"] isEqual:@"scopes"] && [inspection[1][@"command"] isEqual:@"evaluate"]);
		OAK_ASSERT([inspection[1][@"arguments"][@"frameId"] isEqual:@11]);
		DebugReplyWithBody(session, inspection[0], nil);
		DebugReplyWithBody(session, inspection[1], @{ @"result": @"43" });
		watch = DebugButtonWithTitle(watchRows, @"value + 1 = 43");
		OAK_ASSERT(watch);
		[watch.menu performActionForItemAtIndex:0];
		watchInput.stringValue = @"unknown";
		OAK_ASSERT([NSApp sendAction:watchInput.action to:watchInput.target from:watchInput]);
		NSDictionary* failedWatch = ExpectDebugRequest(session, @"evaluate");
		[session receiveBytes:DebugAdapterEncodeMessage(@{ @"type": @"response", @"request_seq": failedWatch[@"seq"], @"command": @"evaluate", @"success": @NO, @"message": @"Unknown variable" })];
		watch = DebugButtonWithTitle(watchRows, @"unknown = Unknown variable");
		OAK_ASSERT(watch && session.canStep);
		[watch.menu performActionForItemAtIndex:1];
		OAK_ASSERT(!panel.watchExpressions.count);
		NSView* layout = [controller valueForKey:@"layoutView"];
		NSButton* runHeader = [layout valueForKey:@"runAndDebugHeader"];
		[runHeader performClick:nil];
		OAK_ASSERT(!panel.view.superview && runHeader.superview && session.canStep && !toolbar.hidden);
		[controller showRunPanel:nil];
		OAK_ASSERT(panel.view.superview == runHeader.superview && session.canStep);
		panel.hideHandler();
		[window layoutIfNeeded];
		NSRect hiddenFrame = window.frame;
		[controller showRunPanel:nil];
		[window layoutIfNeeded];
		OAK_ASSERT([frames isDescendantOf:panel.view] && NSEqualRects(hiddenFrame, window.frame));
		panel.hideHandler();
		[controller debugSelectedConfiguration:nil];
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"continue"), nil);
		OAK_ASSERT(!panel.view.superview && !toolbar.hidden && primary.enabled && [primary.toolTip isEqual:@"Pause"]);
		[primary performClick:nil];
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"pause"), nil);
		DebugEvent(session, @"stopped", @{ @"reason": @"pause", @"threadId": @1 });
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"stackTrace"), @{ @"stackFrames": @[
			@{ @"id": @10, @"name": @"main.main", @"line": @3, @"source": @{ @"path": source } },
		] });
		OAK_ASSERT(!panel.view.superview && !toolbar.hidden && primary.enabled);
		DebugReplyWithBody(session, ExpectDebugRequest(session, @"scopes"), nil);
		[stop performClick:nil];
		ExpectDebugRequest(session, @"disconnect");
		OAK_ASSERT(!stop.enabled && !primary.enabled);
		[controller close];
		OAK_ASSERT(!toolbar.superview);
		[NSFileManager.defaultManager removeItemAtPath:root error:nil];
		[DocumentWindowController enableSessionSave];
	});
}

void test_debug_delve_local_condition_logpoint_watch_steps_restart_and_disconnect ()
{
	if(![NSProcessInfo.processInfo.environment[@"TEXTMATE_TEST_DELVE"] isEqual:@"1"])
		return;
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		NSString* root = DebugFixture(@{ @"name": @"App", @"type": @"go", @"request": @"launch", @"program": @"${workspaceFolder}", @"buildFlags": @"-tags textmate_fixture" });
		NSString* main = [root stringByAppendingPathComponent:@"main.go"];
		OAK_ASSERT([@"module example.com/fixture\n\ngo 1.20\n" writeToFile:[root stringByAppendingPathComponent:@"go.mod"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
		OAK_ASSERT([@"//go:build textmate_fixture\n\npackage main\nconst initialValue = 41\n" writeToFile:[root stringByAppendingPathComponent:@"fixture.go"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
		NSString* program = @"package main\n"
		                     "import (\"time\"; \"os\"; \"strconv\")\n"
		                     "func main() {\n"
		                     "\tif err := os.WriteFile(\"fixture.pid\", []byte(strconv.Itoa(os.GetPid())), 0600); err != nil { panic(err) }\n"
		                     "\tvalue := initialValue\n"
		                     "\tfor iteration := 0; iteration < 2; iteration++ {\n"
		                     "\t\tprintln(value)\n"
		                     "\t\tvalue++\n"
		                     "\t\tprintln(\"stepped\", value)\n"
		                     "\t}\n"
		                     "\ttime.Sleep(30 * time.Second)\n"
		                     "}\n";
		OAK_ASSERT([program writeToFile:main atomically:YES encoding:NSUTF8StringEncoding error:nil]);
		NSMutableDictionary* environment = [ProjectRunDefaultEnvironment() mutableCopy];
		environment[@"GOCACHE"] = [NSTemporaryDirectory() stringByAppendingPathComponent:@"textmate-delve-test-cache"];
		environment[@"GOTOOLCHAIN"] = @"local";
		environment[@"GOPROXY"] = @"off";
		environment[@"GOWORK"] = @"off";
		NSError* error = nil;
		ProjectRunConfiguration* configuration = DebugConfiguration(root);
		ProjectDebugPlan* plan = [configuration debugPlanForFile:main environment:environment error:&error];
		OAK_ASSERT(plan != nil);
		RunPanelController* panel = [RunPanelController new];
		(void)panel.view;
		panel.watchExpressions = @[ @"value + 1" ];
		panel.breakpointsProvider = ^{
			return @{ main: @[ @{ @"line": @7, @"logMessage": @"fixture log: {value}" },
			                   @{ @"line": @8, @"condition": @"value == 42" } ] };
		};
		ProjectDebugSession* session = [panel valueForKey:@"debugger"];
		NSTextView* output = [panel valueForKey:@"output"];
		NSStackView* watchRows = [panel valueForKey:@"watchRows"];
		NSStackView* variables = [panel valueForKey:@"variableRows"];
		NSButton* restart = [panel valueForKey:@"debugRestartButton"];
		NSString* pidFile = [root stringByAppendingPathComponent:@"fixture.pid"];
		pid_t (^targetPID)(void) = ^{ return [NSString stringWithContentsOfFile:pidFile encoding:NSUTF8StringEncoding error:nil].intValue; };
		BOOL (^reachedCondition)(void) = ^{
			return [session.frames.firstObject[@"line"] isEqual:@8] &&
			       DebugButtonWithTitle(variables, @"value = 42") && DebugButtonWithTitle(watchRows, @"value + 1 = 43") &&
			       [output.string containsString:@"fixture log: 41"] && [output.string containsString:@"fixture log: 42"];
		};
		StartDebugFixture(panel, configuration, plan);
		BOOL hit = WaitForDebug(^BOOL{ return reachedCondition() || !panel.isRunning; }, 75) && reachedCondition();
		pid_t firstTarget = targetPID();
		[panel stepOver:nil];
		BOOL stepped = hit && WaitForDebug(^BOOL{
			return [session.frames.firstObject[@"line"] isEqual:@9] && DebugButtonWithTitle(watchRows, @"value + 1 = 44");
		}, 8);
		[session continueExecution];
		BOOL resumed = stepped && WaitForDebug(^BOOL{ return [output.string containsString:@"stepped 43"]; }, 5);
		[session pause];
		BOOL paused = resumed && WaitForDebug(^BOOL{ return session.state == ProjectDebugPaused; }, 5);
		[restart performClick:nil];
		BOOL restarting = session.state == ProjectDebugStopping && !restart.enabled;
		BOOL restarted = restarting && WaitForDebug(^BOOL{ return reachedCondition() || !panel.isRunning; }, 25) && reachedCondition();
		pid_t secondTarget = targetPID();
		BOOL replaced = restarted && firstTarget > 1 && secondTarget > 1 && firstTarget != secondTarget &&
		                kill(firstTarget, 0) == -1 && errno == ESRCH;
		[panel stop:nil];
		BOOL stopped = WaitForDebug(^BOOL{ return !panel.isRunning; }, 5);
		BOOL cleaned = stopped && secondTarget > 1 && WaitForDebug(^BOOL{ return kill(secondTarget, 0) == -1 && errno == ESRCH; }, 4);
		if(!hit || !paused || !replaced || !cleaned)
			fprintf(stderr, "Delve fixture: hit=%d stepped=%d resumed=%d paused=%d restarting=%d restarted=%d replaced=%d cleaned=%d\n%s\n",
			        hit, stepped, resumed, paused, restarting, restarted, replaced, cleaned, output.string.UTF8String);
		[panel invalidate];
		[NSFileManager.defaultManager removeItemAtPath:root error:nil];
		OAK_ASSERT(hit && stepped && resumed && paused && replaced && cleaned);
	});
}
