#import "ProjectDebugSessionProtocol.h"
#import "DebugAdapterFraming.h"
#import "ProjectRun.h"
#import "ProjectRunSession.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <signal.h>

typedef void (^DebugReply)(NSDictionary* body, NSString* error);

static NSString* DebugResponseError(NSDictionary* message)
{
	NSDictionary* body = [message[@"body"] isKindOfClass:NSDictionary.class] ? message[@"body"] : nil;
	NSDictionary* error = [body[@"error"] isKindOfClass:NSDictionary.class] ? body[@"error"] : nil;
	NSString* detail = error[@"format"];
	if([detail isKindOfClass:NSString.class] && detail.length)
		return detail;
	detail = message[@"message"];
	return [detail isKindOfClass:NSString.class] && detail.length ? detail : @"Delve rejected the request.";
}

static NSArray<NSDictionary*>* DebugValues(NSDictionary* body)
{
	NSArray* values = [body[@"variables"] isKindOfClass:NSArray.class] ? body[@"variables"] : @[];
	NSMutableArray* result = [NSMutableArray array];
	for(id value in values)
	{
		if([value isKindOfClass:NSDictionary.class] && [value[@"name"] isKindOfClass:NSString.class] && [value[@"value"] isKindOfClass:NSString.class])
			[result addObject:value];
		if(result.count == 250)
			break;
	}
	return result;
}

@implementation ProjectDebugSession
{
	ProjectRunSession* _adapter;
	NSDictionary* _launchArguments;
	DebugAdapterFraming* _framing;
	NSMutableData* _outgoing;
	NSMutableDictionary<NSNumber*, NSArray*>* _requests;
	NSMutableDictionary<NSString*, NSArray<NSDictionary*>*>* _breakpoints;
	NSMutableDictionary<NSString*, NSDictionary<NSNumber*, NSDictionary*>*>* _breakpointResults;
	NSMutableDictionary<NSString*, NSUUID*>* _breakpointRequests;
	NSTimer* _timer;
	NSString* _scratch;
	NSString* _result;
	NSNumber* _thread;
	NSNumber* _selectedThread;
	NSNumber* _inspectionFrameID;
	NSUInteger _sequence;
	NSUInteger _snapshot;
	NSUInteger _inspection;
	int _socket;
	NSTimeInterval _connectDeadline;
	NSTimeInterval _stopDeadline;
	BOOL _initialized;
	BOOL _configured;
	BOOL _pausePending;
	BOOL _connected;
}

- (instancetype)init
{
	if(self = [super init])
	{
		_socket = -1;
		_frames = @[];
	}
	return self;
}

- (BOOL)canPause { return _state == ProjectDebugRunning && _configured && !_pausePending; }
- (BOOL)canStep { return _state == ProjectDebugPaused && _configured && _thread != nil; }
- (NSNumber*)stoppedThreadID { return _thread; }
- (NSNumber*)selectedThreadID { return _selectedThread ?: _thread; }

- (void)changeState:(ProjectDebugState)state detail:(NSString*)detail
{
	_state = state;
	if(self.didChangeState)
		self.didChangeState(state, detail);
}

- (void)publishOutput:(NSString*)text
{
	if(text.length && self.didReadOutput)
		self.didReadOutput(text);
}

- (void)clearInspection
{
	++_snapshot;
	++_inspection;
	_inspectionFrameID = nil;
	_frames = @[];
	if(self.didChangeFrames)
		self.didChangeFrames(_frames);
	if(self.didChangeVariables)
		self.didChangeVariables(@[]);
}

- (void)start:(ProjectDebugPlan*)plan breakpoints:(NSDictionary<NSString*, NSArray<NSDictionary*>*>*)breakpoints
{
	if(self.state != ProjectDebugIdle || !plan)
		return;
	char directory[] = "/private/tmp/textmate-dap.XXXXXXXX";
	if(!mkdtemp(directory))
	{
		[self changeState:ProjectDebugIdle detail:[NSString stringWithFormat:@"Could not create a private Delve directory: %s", strerror(errno)]];
		return;
	}

	_scratch = @(directory);
	NSMutableDictionary* launch = [plan.launchArguments mutableCopy];
	launch[@"output"] = [_scratch stringByAppendingPathComponent:@"debuggee"];
	[self beginSessionWithLaunchArguments:launch breakpoints:breakpoints];
	_adapter = [ProjectRunSession new];

	__weak ProjectDebugSession* weakSelf = self;
	_adapter.didFinish = ^(int exitCode, BOOL stopped, NSError* error){
		ProjectDebugSession* session = weakSelf;
		if(!session)
			return;
		[session readMessages];
		[session finish:session->_result ?: error.localizedDescription ?: [NSString stringWithFormat:@"Delve exited with code %d.", exitCode]];
	};
	_adapter.didReadOutput = ^(NSData* data){
		[weakSelf publishOutput:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?:
		                        [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding]];
	};
	NSString* address = [@"unix:" stringByAppendingString:[self socketPath]];
	[_adapter runCommands:@[[plan.adapter commandWithArguments:@[ @"dap", @"--listen", address ]]]];
	if(_state != ProjectDebugStarting)
		return;
	_connectDeadline = NSProcessInfo.processInfo.systemUptime + 8;
	_timer = [NSTimer timerWithTimeInterval:0.025 repeats:YES block:^(NSTimer* timer){ [weakSelf poll]; }];
	_timer.tolerance = 0.005;
	[NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)beginSessionWithLaunchArguments:(NSDictionary*)arguments breakpoints:(NSDictionary<NSString*, NSArray<NSDictionary*>*>*)breakpoints
{
	_launchArguments = [arguments copy];
	_framing = [DebugAdapterFraming new];
	_outgoing = [NSMutableData data];
	_requests = [NSMutableDictionary dictionary];
	_breakpoints = [breakpoints mutableCopy] ?: [NSMutableDictionary dictionary];
	_breakpointResults = [NSMutableDictionary dictionary];
	_breakpointRequests = [NSMutableDictionary dictionary];
	_initialized = _configured = _pausePending = NO;
	_sequence = 0;
	_thread = nil;
	_selectedThread = nil;
	_result = nil;
	[self clearInspection];
	[self changeState:ProjectDebugStarting detail:@"Starting Delve…"];
}

- (NSString*)socketPath { return [_scratch stringByAppendingPathComponent:@"dap.sock"]; }

- (void)send:(NSString*)command arguments:(NSDictionary*)arguments timeout:(NSTimeInterval)timeout reply:(DebugReply)reply
{
	NSUInteger sequence = ++_sequence;
	NSData* data = DebugAdapterEncodeMessage(@{ @"seq": @(sequence), @"type": @"request", @"command": command, @"arguments": arguments ?: @{} });
	if(!data || _outgoing.length + data.length > 8 * 1024 * 1024)
	{
		[self endSession:@"The debug request is too large."];
		return;
	}
	_requests[@(sequence)] = @[ @(NSProcessInfo.processInfo.systemUptime + timeout), command, [reply copy] ];
	[_outgoing appendData:data];
}

- (void)connectToAdapter
{
	sockaddr_un address = {};
	address.sun_family = AF_UNIX;
	NSString* socketPath = [self socketPath];
	strlcpy(address.sun_path, socketPath.fileSystemRepresentation, sizeof(address.sun_path));
	address.sun_len = SUN_LEN(&address);
	int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
	if(descriptor == -1)
	{
		[self endSession:[NSString stringWithFormat:@"Could not open Delve's local connection: %s", strerror(errno)]];
		return;
	}
	int enabled = 1;
	if(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == -1 || fcntl(descriptor, F_SETFL, O_NONBLOCK) == -1 ||
	   setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) == -1 ||
	   connect(descriptor, (sockaddr*)&address, address.sun_len) == -1)
	{
		int error = errno;
		close(descriptor);
		if(error != ENOENT && error != ECONNREFUSED && error != EAGAIN && error != EINTR)
			[self endSession:[NSString stringWithFormat:@"Could not connect to Delve: %s", strerror(error)]];
		return;
	}

	_socket = descriptor;
	[self transportDidConnect];
}

- (void)transportDidConnect
{
	_connected = YES;
	__weak ProjectDebugSession* weakSelf = self;
	[self send:@"initialize" arguments:@{ @"adapterID": @"go", @"clientID": @"textmate", @"pathFormat": @"path",
	                                      @"linesStartAt1": @YES, @"columnsStartAt1": @YES }
	      timeout:10 reply:^(NSDictionary* body, NSString* error){
		ProjectDebugSession* session = weakSelf;
		if(!session || session.state == ProjectDebugStopping)
			return;
		if(error || ![body[@"supportsConfigurationDoneRequest"] isEqual:@YES])
		{
			[session endSession:error ?: @"This Delve adapter does not support configurationDone."];
			return;
		}
		[session changeState:ProjectDebugStarting detail:@"Building Go debug target…"];
		[session send:@"launch" arguments:session->_launchArguments timeout:180 reply:^(NSDictionary* body, NSString* launchError){
			if(launchError && weakSelf.state != ProjectDebugStopping)
				[weakSelf endSession:launchError];
		}];
	}];
}

- (void)poll
{
	NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
	if(self.state == ProjectDebugStopping)
	{
		if(now >= _stopDeadline)
		{
			[self closeConnection];
			[_adapter stop];
			return;
		}
	}
	else if(_socket < 0)
	{
		if(now >= _connectDeadline)
		{
			[self endSession:@"Timed out waiting for Delve's local connection."];
			return;
		}
		[self connectToAdapter];
	}
	if(_socket < 0)
		return;

	NSData* outgoing = [self pendingRequestBytes];
	if(outgoing.length)
	{
		ssize_t written = write(_socket, outgoing.bytes, outgoing.length);
		if(written > 0)
			[self didWriteRequestBytes:written];
		else if(written < 0 && errno != EAGAIN && errno != EINTR)
		{
			[self closeConnection];
			[self endSession:@"The connection to Delve closed."];
			return;
		}
	}
	[self readMessages];
	if(self.state == ProjectDebugStopping)
		return;
	for(NSNumber* key in _requests.allKeys)
	{
		NSArray* request = _requests[key];
		if(request && now >= [request[0] doubleValue])
		{
			NSString* command = request[1];
			NSString* error = [NSString stringWithFormat:@"Delve did not answer %@ in time.", command];
			if([@[ @"evaluate", @"variables", @"threads", @"setBreakpoints" ] containsObject:command])
			{
				DebugReply reply = request[2];
				[_requests removeObjectForKey:key];
				reply(@{}, error);
			}
			else
			{
				[self endSession:error];
				break;
			}
		}
	}
}

- (NSData*)pendingRequestBytes { return _outgoing; }

- (void)didWriteRequestBytes:(NSUInteger)length
{
	[_outgoing replaceBytesInRange:NSMakeRange(0, length) withBytes:nil length:0];
}

- (void)readMessages
{
	char bytes[8192];
	for(NSUInteger consumed = 0; _socket >= 0 && consumed < 128 * 1024;)
	{
		ssize_t count = read(_socket, bytes, sizeof(bytes));
		if(count == -1 && errno == EINTR)
			continue;
		if(count == -1 && errno == EAGAIN)
			break;
		if(count <= 0)
		{
			[self closeConnection];
			[self endSession:@"The connection to Delve closed."];
			return;
		}
		consumed += count;
		[self receiveBytes:[NSData dataWithBytes:bytes length:count]];
	}
}

- (void)receiveBytes:(NSData*)bytes
{
	NSError* error = nil;
	NSArray* messages = [_framing consumeData:bytes error:&error];
	if(!messages)
	{
		[self endSession:error.localizedDescription];
		return;
	}
	for(NSDictionary* message in messages)
		[self handleMessage:message];
}

- (void)handleMessage:(NSDictionary*)message
{
	NSDictionary* body = [message[@"body"] isKindOfClass:NSDictionary.class] ? message[@"body"] : @{};
	if([message[@"type"] isEqual:@"response"])
	{
		NSNumber* sequence = message[@"request_seq"];
		NSArray* request = [sequence isKindOfClass:NSNumber.class] ? _requests[sequence] : nil;
		if(request && [request[1] isEqual:message[@"command"]])
		{
			DebugReply reply = request[2];
			[_requests removeObjectForKey:sequence];
			if(self.state != ProjectDebugStopping)
				reply(body, [message[@"success"] isEqual:@YES] ? nil : DebugResponseError(message));
		}
		return;
	}
	if(![message[@"type"] isEqual:@"event"])
		return;
	id event = message[@"event"];
	if([event isEqual:@"output"])
	{
		if([body[@"output"] isKindOfClass:NSString.class])
			[self publishOutput:body[@"output"]];
		return;
	}
	if(_state == ProjectDebugStopping)
		return;
	if([event isEqual:@"initialized"] && !_initialized)
	{
		_initialized = YES;
		for(NSString* path in _breakpoints)
			[self sendBreakpointsForPath:path];
		__weak ProjectDebugSession* weakSelf = self;
		[self send:@"configurationDone" arguments:nil timeout:15 reply:^(NSDictionary* body, NSString* error){
			ProjectDebugSession* session = weakSelf;
			if(!session)
				return;
			if(error)
			{
				[session endSession:error];
				return;
			}
			session->_configured = YES;
			if(session.state == ProjectDebugPaused)
				[session loadStack];
			else
				[session changeState:ProjectDebugRunning detail:@"Debugging"];
		}];
	}
	else if([event isEqual:@"stopped"])
	{
		_pausePending = NO;
		_thread = [body[@"threadId"] isKindOfClass:NSNumber.class] && [body[@"threadId"] integerValue] > 0 ? body[@"threadId"] : nil;
		_selectedThread = nil;
		[self clearInspection];
		NSString* reason = [body[@"reason"] isKindOfClass:NSString.class] ? body[@"reason"] : @"paused";
		[self changeState:ProjectDebugPaused detail:[NSString stringWithFormat:@"Paused — %@", reason]];
		if(_configured)
			[self loadStack];
	}
	else if([event isEqual:@"exited"])
	{
		if([body[@"exitCode"] isKindOfClass:NSNumber.class])
			_result = [NSString stringWithFormat:@"Debug target exited with code %@.", body[@"exitCode"]];
	}
	else if([event isEqual:@"terminated"])
		[self endSession:_result ?: @"Debug session ended."];
}

- (void)setBreakpoints:(NSArray<NSDictionary*>*)breakpoints forPath:(NSString*)path
{
	if(!_launchArguments || _state == ProjectDebugStopping || !path.length)
		return;
	if(breakpoints.count)
		_breakpoints[path] = [breakpoints copy];
	else
		[_breakpoints removeObjectForKey:path];
	if(_initialized)
		[self sendBreakpointsForPath:path];
}

- (void)sendBreakpointsForPath:(NSString*)path
{
	NSMutableArray* requested = [NSMutableArray array];
	for(NSDictionary* breakpoint in _breakpoints[path])
	{
		if([breakpoint[@"enabled"] isEqual:@NO])
			continue;
		NSMutableDictionary* sourceBreakpoint = [NSMutableDictionary dictionaryWithObject:breakpoint[@"line"] forKey:@"line"];
		for(NSString* key in @[ @"condition", @"hitCondition", @"logMessage" ])
		{
			if([breakpoint[key] length])
				sourceBreakpoint[key] = breakpoint[key];
		}
		[requested addObject:sourceBreakpoint];
	}
	NSUUID* request = [NSUUID UUID];
	_breakpointRequests[path] = request;
	[_breakpointResults removeObjectForKey:path];
	if(self.didChangeBreakpointResults)
		self.didChangeBreakpointResults(path);
	__weak ProjectDebugSession* weakSelf = self;
	[self send:@"setBreakpoints" arguments:@{ @"source": @{ @"path": path }, @"breakpoints": requested } timeout:15 reply:^(NSDictionary* body, NSString* error){
		ProjectDebugSession* session = weakSelf;
		if(!session || session->_breakpointRequests[path] != request)
			return;
		[session->_breakpointRequests removeObjectForKey:path];
		NSArray* results = [body[@"breakpoints"] isKindOfClass:NSArray.class] ? body[@"breakpoints"] : @[];
		NSMutableDictionary* verifiedResults = [NSMutableDictionary dictionary];
		if(error)
			[session publishOutput:[NSString stringWithFormat:@"Could not set breakpoints in %@: %@\n", path.lastPathComponent, error]];
		for(NSUInteger index = 0; index < requested.count; ++index)
		{
			NSDictionary* result = index < results.count && [results[index] isKindOfClass:NSDictionary.class] ? results[index] : nil;
			NSNumber* line = requested[index][@"line"];
			BOOL verified = !error && [result[@"verified"] isEqual:@YES];
			NSNumber* resolvedLine = [result[@"line"] isKindOfClass:NSNumber.class] && [result[@"line"] integerValue] > 0 ? result[@"line"] : line;
			NSString* message = [result[@"message"] isKindOfClass:NSString.class] ? result[@"message"] : nil;
			if(!verified)
			{
				message = error ?: message ?: (result ? @"No executable code on this line." : @"Delve returned no verification result.");
				if(!error)
					[session publishOutput:[NSString stringWithFormat:@"Breakpoint %@:%@ was not verified: %@\n", path.lastPathComponent, line, message]];
			}
			else if(![resolvedLine isEqual:line])
				[session publishOutput:[NSString stringWithFormat:@"Breakpoint %@:%@ resolves to line %@.\n", path.lastPathComponent, line, resolvedLine]];
			verifiedResults[line] = @{ @"verified": @(verified), @"line": resolvedLine, @"message": message ?: @"" };
		}
		session->_breakpointResults[path] = verifiedResults.count ? [verifiedResults copy] : nil;
		if(session.didChangeBreakpointResults)
			session.didChangeBreakpointResults(path);
	}];
}

- (NSDictionary*)breakpointResultAtPath:(NSString*)path line:(NSUInteger)line
{
	return _breakpointResults[path][@(line)];
}

- (void)loadStack
{
	NSUInteger snapshot = _snapshot;
	__weak ProjectDebugSession* weakSelf = self;
	if(!_thread)
	{
		[self loadThreads:^(NSArray<NSDictionary*>* threads, NSString* error){
			ProjectDebugSession* session = weakSelf;
			if(!session)
				return;
			if(threads.count)
			{
				session->_thread = threads.firstObject[@"id"];
				[session loadStack];
			}
			else
				[session publishOutput:[NSString stringWithFormat:@"Could not find a paused goroutine: %@\n", error ?: @"no threads returned"]];
		}];
		return;
	}
	[self send:@"stackTrace" arguments:@{ @"threadId": self.selectedThreadID, @"startFrame": @0, @"levels": @40 } timeout:10 reply:^(NSDictionary* body, NSString* error){
		ProjectDebugSession* session = weakSelf;
		if(!session || session->_snapshot != snapshot)
			return;
		if(error)
			[session publishOutput:[NSString stringWithFormat:@"Could not read the call stack: %@\n", error]];
		NSArray* frames = [body[@"stackFrames"] isKindOfClass:NSArray.class] ? body[@"stackFrames"] : @[];
		session->_frames = [frames filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id frame, NSDictionary* bindings){
			return [frame isKindOfClass:NSDictionary.class] && [frame[@"id"] isKindOfClass:NSNumber.class];
		}]];
		if(session.didChangeFrames)
			session.didChangeFrames(session.frames);
	}];
}

- (void)loadThreads:(void (^)(NSArray<NSDictionary*>*, NSString*))completion
{
	if(self.state != ProjectDebugPaused || !_configured)
	{
		completion(@[], @"Pause debugging to inspect goroutines.");
		return;
	}
	NSUInteger snapshot = _snapshot;
	__weak ProjectDebugSession* weakSelf = self;
	[self send:@"threads" arguments:nil timeout:10 reply:^(NSDictionary* body, NSString* error){
		ProjectDebugSession* session = weakSelf;
		if(!session || session->_snapshot != snapshot)
			return;
		NSArray* threads = [body[@"threads"] isKindOfClass:NSArray.class] ? body[@"threads"] : @[];
		NSArray* valid = [threads filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id thread, NSDictionary* bindings){
			return [thread isKindOfClass:NSDictionary.class] && [thread[@"id"] isKindOfClass:NSNumber.class] && [thread[@"id"] integerValue] > 0;
		}]];
		completion(valid, error);
	}];
}

- (void)selectThread:(NSNumber*)thread
{
	if(!self.canStep || thread.integerValue <= 0 || [self.selectedThreadID isEqual:thread])
		return;
	_selectedThread = thread;
	[self clearInspection];
	[self loadStack];
}

- (void)selectFrame:(NSDictionary*)frame
{
	if(self.state != ProjectDebugPaused || ![_frames containsObject:frame])
		return;
	NSUInteger inspection = ++_inspection;
	_inspectionFrameID = frame[@"id"];
	if(self.didChangeVariables)
		self.didChangeVariables(@[]);
	__weak ProjectDebugSession* weakSelf = self;
	[self send:@"scopes" arguments:@{ @"frameId": frame[@"id"] } timeout:10 reply:^(NSDictionary* body, NSString* error){
		ProjectDebugSession* session = weakSelf;
		if(!session || session->_inspection != inspection)
			return;
		if(error)
			[session publishOutput:[NSString stringWithFormat:@"Could not read variable scopes: %@\n", error]];
		NSArray* scopes = [body[@"scopes"] isKindOfClass:NSArray.class] ? body[@"scopes"] : @[];
		NSMutableArray* selected = [NSMutableArray array];
		for(NSDictionary* scope in scopes)
		{
			if([scope isKindOfClass:NSDictionary.class] && ([scope[@"name"] isEqual:@"Locals"] || [scope[@"name"] isEqual:@"Arguments"]) &&
			   [scope[@"variablesReference"] isKindOfClass:NSNumber.class] && [scope[@"variablesReference"] integerValue] > 0)
				[selected addObject:scope];
		}
		NSMutableArray* variables = [NSMutableArray array];
		for(NSDictionary* scope in selected)
		{
			[session send:@"variables" arguments:@{ @"variablesReference": scope[@"variablesReference"] } timeout:10 reply:^(NSDictionary* body, NSString* variablesError){
				ProjectDebugSession* current = weakSelf;
				if(!current || current->_inspection != inspection)
					return;
				if(variablesError)
					[current publishOutput:[NSString stringWithFormat:@"Could not read %@: %@\n", scope[@"name"], variablesError]];
				for(NSDictionary* variable in DebugValues(body))
				{
					if(variables.count >= 250)
						break;
					NSMutableDictionary* entry = [variable mutableCopy];
					entry[@"scope"] = scope[@"name"];
					[variables addObject:entry];
				}
				if(current.didChangeVariables)
					current.didChangeVariables([variables copy]);
			}];
		}
	}];
}

- (void)evaluateWatchExpression:(NSString*)expression completion:(void (^)(NSDictionary*, NSString*))completion
{
	if(!self.canStep || !_inspectionFrameID)
	{
		completion(nil, @"Pause and select a stack frame to evaluate.");
		return;
	}
	expression = [expression stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSRange whitespace = [expression rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSString* command = whitespace.location != NSNotFound ? [expression substringToIndex:whitespace.location] : nil;
	if(!expression.length || expression.length > 1024 || [command isEqual:@"call"] || [command isEqual:@"dlv"])
	{
		completion(nil, @"Enter a Go expression, not a debugger command.");
		return;
	}
	NSUInteger inspection = _inspection;
	__weak ProjectDebugSession* weakSelf = self;
	[self send:@"evaluate" arguments:@{ @"expression": expression, @"frameId": _inspectionFrameID, @"context": @"watch" } timeout:10 reply:^(NSDictionary* body, NSString* error){
		ProjectDebugSession* session = weakSelf;
		if(session && session->_inspection == inspection)
		{
			BOOL hasValue = [body[@"result"] isKindOfClass:NSString.class];
			completion(!error && hasValue ? body : nil, error ?: (hasValue ? nil : @"No value returned."));
		}
	}];
}

- (void)loadChildrenOfVariable:(NSNumber*)reference completion:(void (^)(NSArray<NSDictionary*>*, NSString*))completion
{
	if(!self.canStep || !_inspectionFrameID || ![reference isKindOfClass:NSNumber.class] || reference.integerValue <= 0)
	{
		completion(@[], @"Value is no longer available.");
		return;
	}
	NSUInteger inspection = _inspection;
	__weak ProjectDebugSession* weakSelf = self;
	[self send:@"variables" arguments:@{ @"variablesReference": reference } timeout:10 reply:^(NSDictionary* body, NSString* error){
		ProjectDebugSession* session = weakSelf;
		if(session && session->_inspection == inspection)
			completion(DebugValues(body), error);
	}];
}

- (void)resumeWithCommand:(NSString*)command
{
	if(!self.canStep)
		return;
	[self clearInspection];
	[self changeState:ProjectDebugRunning detail:@"Debugging"];
	NSUInteger snapshot = _snapshot;
	__weak ProjectDebugSession* weakSelf = self;
	[self send:command arguments:@{ @"threadId": self.selectedThreadID } timeout:10 reply:^(NSDictionary* body, NSString* error){
		ProjectDebugSession* session = weakSelf;
		if(error && session && session->_snapshot == snapshot)
		{
			[session changeState:ProjectDebugPaused detail:@"Paused"];
			[session publishOutput:[NSString stringWithFormat:@"%@\n", error]];
			[session loadStack];
		}
	}];
}

- (void)continueExecution { [self resumeWithCommand:@"continue"]; }
- (void)stepOver { [self resumeWithCommand:@"next"]; }
- (void)stepIn { [self resumeWithCommand:@"stepIn"]; }
- (void)stepOut { [self resumeWithCommand:@"stepOut"]; }

- (void)pause
{
	if(!self.canPause)
		return;
	_pausePending = YES;
	[self changeState:ProjectDebugRunning detail:@"Pausing…"];
	__weak ProjectDebugSession* weakSelf = self;
	[self send:@"pause" arguments:@{ @"threadId": _thread ?: @(-1) } timeout:10 reply:^(NSDictionary* body, NSString* error){
		ProjectDebugSession* session = weakSelf;
		if(error && session.state == ProjectDebugRunning)
		{
			session->_pausePending = NO;
			[session changeState:ProjectDebugRunning detail:@"Debugging"];
			[session publishOutput:[NSString stringWithFormat:@"%@\n", error]];
		}
	}];
}

- (void)endSession:(NSString*)detail
{
	if(_state == ProjectDebugIdle || _state == ProjectDebugStopping)
		return;
	_result = detail;
	_stopDeadline = NSProcessInfo.processInfo.systemUptime + 2.5;
	[self clearInspection];
	[self changeState:ProjectDebugStopping detail:@"Stopping debugger…"];
	[_requests removeAllObjects];
	if(_connected)
		[self send:@"disconnect" arguments:@{ @"terminateDebuggee": @YES } timeout:3 reply:^(NSDictionary* body, NSString* error){}];
	else
		[_adapter stop];
}

- (void)stop { [self endSession:@"Debug session stopped."]; }

- (void)closeConnection
{
	if(_socket >= 0)
		close(_socket);
	_socket = -1;
	_connected = NO;
}

- (void)finish:(NSString*)detail
{
	[self closeConnection];
	[_timer invalidate];
	_timer = nil;
	if(_scratch)
		[NSFileManager.defaultManager removeItemAtPath:_scratch error:nil];
	_scratch = nil;
	_launchArguments = nil;
	_adapter = nil;
	_framing = nil;
	_outgoing = nil;
	_requests = nil;
	_breakpoints = nil;
	_breakpointResults = nil;
	_breakpointRequests = nil;
	_thread = _selectedThread = nil;
	[self clearInspection];
	[self changeState:ProjectDebugIdle detail:detail];
}

- (void)invalidate
{
	self.didReadOutput = nil;
	self.didChangeState = nil;
	self.didChangeFrames = nil;
	self.didChangeVariables = nil;
	self.didChangeBreakpointResults = nil;
	if(self.state == ProjectDebugIdle)
		return;
	[self stop];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		if(self.state != ProjectDebugIdle)
		{
			[self->_adapter invalidate];
			[self finish:nil];
		}
	});
}

- (void)dealloc
{
	[self closeConnection];
	[_timer invalidate];
	[_adapter invalidate];
	if(_scratch)
		[NSFileManager.defaultManager removeItemAtPath:_scratch error:nil];
}
@end
