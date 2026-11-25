#import "ProjectRun.h"
#import "ProjectWorkspace.h"
#import <io/environment.h>
#import <io/path.h>
#import <ns/ns.h>

NSDictionary<NSString*, NSString*>* ProjectRunDefaultEnvironment()
{
	NSMutableDictionary* environment = [NSMutableDictionary dictionary];
	for(auto const& pair : oak::basic_environment())
		environment[to_ns(pair.first)] = to_ns(pair.second);
	NSString* extraPaths = [NSString stringWithFormat:@"%@/go/bin:%@/.local/bin:/opt/homebrew/bin:/usr/local/bin", NSHomeDirectory(), NSHomeDirectory()];
	environment[@"PATH"] = [NSString stringWithFormat:@"%@:%@", environment[@"PATH"] ?: @"/usr/bin:/bin", extraPaths];
	environment[@"TERM"] = @"dumb";
	return environment;
}

static id RunConfigurationError(NSError** error, NSString* message)
{
	if(error)
		*error = [NSError errorWithDomain:@"TextMate.ProjectRun" code:1 userInfo:@{ NSLocalizedDescriptionKey: message }];
	return nil;
}

static NSString* RunWorkingDirectory(NSString* directory, NSString* base, NSError** error)
{
	if(!directory.length)
		return RunConfigurationError(error, @"The working directory cannot be empty.");
	NSString* path = (directory.isAbsolutePath ? directory : [base stringByAppendingPathComponent:directory]).stringByStandardizingPath;
	BOOL isDirectory = NO;
	if(![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory)
		return RunConfigurationError(error, [NSString stringWithFormat:@"The working directory “%@” is unavailable.", path]);
	return path;
}

static NSArray<NSString*>* RunCommandWords(id value, NSString** directory, NSString* message, NSError** error)
{
	if(![value isKindOfClass:NSString.class])
		return RunConfigurationError(error, message);

	NSString* source = value;
	NSMutableArray<NSString*>* words = [NSMutableArray array];
	NSMutableString* word = [NSMutableString string];
	NSCharacterSet* operators = [NSCharacterSet characterSetWithCharactersInString:@"|;<>()*?[]~#{}"];
	unichar quote = 0;
	BOOL inWord = NO;
	for(NSUInteger index = 0; index < source.length; ++index)
	{
		unichar character = [source characterAtIndex:index];
		if(character == '\r' || character == '\n' || !character)
			return RunConfigurationError(error, message);
		if(!quote && (character == ' ' || character == '\t' || character == '&'))
		{
			if(inWord)
			{
				[words addObject:[word copy]];
				[word setString:@""];
				inWord = NO;
			}
			if(character == '&')
			{
				if(!directory || *directory || words.count != 2 || ![words.firstObject isEqual:@"cd"] || !words.lastObject.length ||
				   index + 1 >= source.length || [source characterAtIndex:index + 1] != '&')
					return RunConfigurationError(error, message);
				*directory = words.lastObject;
				[words removeAllObjects];
				++index;
			}
			continue;
		}
		inWord = YES;
		if(character == quote)
		{
			quote = 0;
			continue;
		}
		if(!quote && (character == '\'' || character == '"'))
		{
			quote = character;
			continue;
		}
		if(character == '$' && index + 1 < source.length && [source characterAtIndex:index + 1] == '{')
		{
			NSUInteger start = index + 2;
			NSRange end = [source rangeOfString:@"}" options:0 range:NSMakeRange(start, source.length-start)];
			if(end.location == NSNotFound)
				return RunConfigurationError(error, message);
			[word appendString:[source substringWithRange:NSMakeRange(index, NSMaxRange(end)-index)]];
			index = end.location;
			continue;
		}
		if((quote != '\'' && (character == '$' || character == '`' || character == '\\')) ||
		   (!quote && [operators characterIsMember:character]))
			return RunConfigurationError(error, message);
		[word appendString:[source substringWithRange:NSMakeRange(index, 1)]];
	}
	if(inWord)
		[words addObject:[word copy]];
	if(quote || !words.firstObject.length)
		return RunConfigurationError(error, message);
	return words;
}

static NSArray<NSString*>* TerminalCommandWords(id value, NSString** directory, NSError** error)
{
	return RunCommandWords(value, directory, @"node-terminal requires a simple command, optionally preceded by “cd <directory> &&”. Pipes, redirects, and shell expansions are not supported.", error);
}

static NSArray<NSDictionary*>* ReadConfigurations(NSString* root, NSString* filename, NSString* key, NSMutableArray<NSError*>* errors)
{
	NSString* path = [root stringByAppendingPathComponent:[@".vscode" stringByAppendingPathComponent:filename]];
	NSError* error = nil;
	NSData* source = [NSData dataWithContentsOfFile:path options:0 error:&error];
	if(!source)
	{
		if(error && error.code != NSFileReadNoSuchFileError)
			[errors addObject:error];
		return @[];
	}

	NSData* json = ProjectJSONDataWithoutComments(source);
	id configuration = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
	id entries = [configuration isKindOfClass:NSDictionary.class] ? configuration[key] : nil;
	if(![entries isKindOfClass:NSArray.class])
	{
		[errors addObject:[NSError errorWithDomain:@"TextMate.ProjectRun" code:2 userInfo:@{
			NSLocalizedDescriptionKey: [NSString stringWithFormat:@"“%@” must contain a valid %@ array.", path, key]
		}]];
		return @[];
	}
	return [entries filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id entry, NSDictionary* bindings){
		return [entry isKindOfClass:NSDictionary.class];
	}]];
}

@interface ProjectRunCommand ()
@property (nonatomic, readwrite) NSString* executable;
@property (nonatomic, readwrite) NSArray<NSString*>* arguments;
@property (nonatomic, readwrite) NSString* directory;
@property (nonatomic, readwrite) NSDictionary<NSString*, NSString*>* environment;
@end

@implementation ProjectRunCommand
- (ProjectRunCommand*)commandWithArguments:(NSArray<NSString*>*)arguments
{
	ProjectRunCommand* command = [ProjectRunCommand new];
	command.executable = self.executable;
	command.arguments = [arguments copy];
	command.directory = self.directory;
	command.environment = self.environment;
	return command;
}

- (NSString*)displayCommand
{
	NSMutableArray<NSString*>* parts = [NSMutableArray array];
	for(NSString* part in [@[ self.executable ] arrayByAddingObjectsFromArray:self.arguments])
		[parts addObject:part.length ? to_ns(path::escape(to_s(part))) : @"''"];
	return [parts componentsJoinedByString:@" "];
}
@end

@interface ProjectDebugPlan ()
@property (nonatomic, readwrite) NSArray<ProjectRunCommand*>* tasks;
@property (nonatomic, readwrite) ProjectRunCommand* adapter;
@property (nonatomic, readwrite) NSDictionary* launchArguments;
@end

@implementation ProjectDebugPlan
@end

@interface ProjectRunConfiguration ()
@property (nonatomic, readwrite) NSString* name;
@property (nonatomic, readwrite) NSString* root;
@property (nonatomic, readwrite) NSString* title;
@property (nonatomic, readwrite) NSString* identifier;
@property (nonatomic) NSDictionary* definition;
@property (nonatomic) NSArray<NSDictionary*>* tasks;
@property (nonatomic) NSArray<NSDictionary<NSString*, NSString*>*>* folders;
@property (nonatomic) BOOL task;
@end

@implementation ProjectRunConfiguration
+ (NSURL*)openOrCreateLaunchConfigurationInFolder:(NSString*)folder error:(NSError**)error
{
	BOOL directory = NO;
	if(!folder.isAbsolutePath || ![NSFileManager.defaultManager fileExistsAtPath:folder isDirectory:&directory] || !directory)
		return RunConfigurationError(error, @"Open a project folder before configuring Run & Debug.");

	NSURL* settings = [[NSURL fileURLWithPath:folder isDirectory:YES] URLByAppendingPathComponent:@".vscode" isDirectory:YES];
	NSURL* launch = [settings URLByAppendingPathComponent:@"launch.json" isDirectory:NO];
	if(![NSFileManager.defaultManager fileExistsAtPath:launch.path])
	{
		if(![NSFileManager.defaultManager createDirectoryAtURL:settings withIntermediateDirectories:YES attributes:nil error:error])
			return nil;
		NSData* templateData = [@"{\n  \"version\": \"0.2.0\",\n  \"configurations\": [\n    {\n      \"name\": \"Debug Go\",\n      \"type\": \"go\",\n      \"request\": \"launch\",\n      \"mode\": \"debug\",\n      \"program\": \"${workspaceFolder}\"\n    }\n  ]\n}\n" dataUsingEncoding:NSUTF8StringEncoding];
		NSError* writeError = nil;
		if(![templateData writeToURL:launch options:NSDataWritingWithoutOverwriting error:&writeError] &&
		   !([writeError.domain isEqual:NSCocoaErrorDomain] && writeError.code == NSFileWriteFileExistsError))
		{
			if(error)
				*error = writeError;
			return nil;
		}
	}
	NSNumber* regularFile = nil;
	if(![launch.URLByResolvingSymlinksInPath getResourceValue:&regularFile forKey:NSURLIsRegularFileKey error:error])
		return nil;
	return regularFile.boolValue ? launch : RunConfigurationError(error, @"The launch.json path is not a regular file.");
}

- (BOOL)supportsDebugging
{
	id mode = self.definition[@"mode"] ?: @"auto";
	return !self.task && [self.definition[@"type"] isEqual:@"go"] && [self.definition[@"request"] isEqual:@"launch"] &&
	       ([mode isEqual:@"auto"] || [mode isEqual:@"debug"]);
}

+ (NSArray<ProjectRunConfiguration*>*)configurationsForFolders:(NSArray<NSDictionary<NSString*, NSString*>*>*)folders errors:(NSMutableArray<NSError*>*)errors
{
	NSMutableArray* configurations = [NSMutableArray array];
	NSCountedSet* names = [[NSCountedSet alloc] initWithArray:[folders valueForKey:@"name"] ?: @[]];
	for(NSDictionary* folder in folders)
	{
		NSString* root = folder[@"path"];
		NSString* folderName = folder[@"name"];
		if([names countForObject:folderName] > 1)
			folderName = [NSString stringWithFormat:@"%@ (%@)", folderName, root.stringByAbbreviatingWithTildeInPath];
		NSArray* tasks = ReadConfigurations(root, @"tasks.json", @"tasks", errors);
		NSArray* launches = ReadConfigurations(root, @"launch.json", @"configurations", errors);
		for(NSNumber* isTask in @[ @NO, @YES ])
		{
			for(NSDictionary* definition in (isTask.boolValue ? tasks : launches))
			{
				if(isTask.boolValue && ![definition[@"type"] isEqual:@"process"])
					continue;
				id name = definition[isTask.boolValue ? @"label" : @"name"];
				if(![name isKindOfClass:NSString.class] || ![name length])
					continue;
				ProjectRunConfiguration* config = [self new];
				config.name = name;
				config.root = root;
				config.title = [NSString stringWithFormat:@"%@ — %@%@", name, folderName, isTask.boolValue ? @" (Task)" : @""];
				config.identifier = [NSString stringWithFormat:@"%@\n%@\n%@", root, isTask, name];
				config.definition = definition;
				config.tasks = tasks;
				config.folders = folders;
				config.task = isTask.boolValue;
				[configurations addObject:config];
			}
		}
	}
	return configurations;
}

- (NSString*)resolveValue:(id)value file:(NSString*)file error:(NSError**)error
{
	if(![value isKindOfClass:NSString.class])
		return RunConfigurationError(error, @"Commands, arguments, paths, and environment values must be strings.");
	NSString* text = value;
	if(!text.UTF8String)
		return RunConfigurationError(error, @"A run setting contains invalid text.");
	if([text rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound)
		return RunConfigurationError(error, @"A run setting contains a NUL character.");
	NSMutableString* result = [NSMutableString string];
	for(NSUInteger cursor = 0; cursor < text.length;)
	{
		NSRange start = [text rangeOfString:@"${" options:0 range:NSMakeRange(cursor, text.length-cursor)];
		if(start.location == NSNotFound)
		{
			[result appendString:[text substringFromIndex:cursor]];
			break;
		}
		[result appendString:[text substringWithRange:NSMakeRange(cursor, start.location-cursor)]];
		NSUInteger first = NSMaxRange(start);
		NSRange end = [text rangeOfString:@"}" options:0 range:NSMakeRange(first, text.length-first)];
		if(end.location == NSNotFound)
			return RunConfigurationError(error, @"A run setting contains an unclosed ${…} variable.");
		NSString* token = [text substringWithRange:NSMakeRange(first, end.location-first)];

		NSString* resolved = nil;
		if([token isEqual:@"workspaceFolder"])
			resolved = self.root;
		else if([token isEqual:@"workspaceFolderBasename"])
			resolved = self.root.lastPathComponent;
		else if([token hasPrefix:@"workspaceFolder:"])
		{
			NSString* name = [token substringFromIndex:@"workspaceFolder:".length];
			for(NSDictionary* folder in self.folders)
			{
				if(![folder[@"name"] isEqual:name])
					continue;
				if(resolved)
					return RunConfigurationError(error, [NSString stringWithFormat:@"Workspace folder name “%@” is ambiguous.", name]);
				resolved = folder[@"path"];
			}
		}
		else if(file && [token isEqual:@"file"])
			resolved = file;
		else if(file && [token isEqual:@"fileDirname"])
			resolved = file.stringByDeletingLastPathComponent;
		else if(file && [token isEqual:@"fileBasename"])
			resolved = file.lastPathComponent;
		else if(file && [token isEqual:@"relativeFile"])
			resolved = to_ns(path::relative_to(to_s(file), to_s(self.root)));
		if(!resolved)
			return RunConfigurationError(error, [NSString stringWithFormat:@"Cannot resolve ${%@} for this configuration.", token]);

		[result appendString:resolved];
		cursor = NSMaxRange(end);
	}
	return result;
}

- (ProjectRunCommand*)commandForDefinition:(NSDictionary*)definition task:(BOOL)task file:(NSString*)file environment:(NSDictionary<NSString*, NSString*>*)environment launchArguments:(NSDictionary**)launchArguments error:(NSError**)error
{
	id type = definition[@"type"];
	BOOL go = !task && [type isEqual:@"go"];
	BOOL terminal = !task && [type isEqual:@"node-terminal"];
	if(task)
	{
		id background = definition[@"isBackground"];
		if(![type isEqual:@"process"] || (background && (![background isKindOfClass:NSNumber.class] || [background boolValue])) || definition[@"dependsOn"])
			return RunConfigurationError(error, @"Only standalone, foreground process tasks are supported.");
	}
	else if(![definition[@"request"] isEqual:@"launch"] || !(go || terminal || [type isEqual:@"textmate-process"]))
		return RunConfigurationError(error, @"Only local Go, node-terminal, and textmate-process launch configurations are supported.");
	if(definition[@"console"] && ![definition[@"console"] isEqual:@"internalConsole"])
		return RunConfigurationError(error, @"This configuration needs an interactive console. Use a foreground process task or internalConsole.");

	for(NSString* key in @[ @"osx", @"windows", @"linux", @"runtimeExecutable", @"runtimeArgs", @"envFile", @"postDebugTask" ])
	{
		if(definition[key])
			return RunConfigurationError(error, [NSString stringWithFormat:@"The run setting “%@” is not supported.", key]);
	}
	if(!go && definition[@"buildFlags"])
		return RunConfigurationError(error, @"buildFlags applies only to Go launch configurations.");

	NSString* terminalDirectory = nil;
	NSArray<NSString*>* terminalWords = nil;
	if(terminal)
	{
		NSSet* allowed = [NSSet setWithArray:@[ @"name", @"type", @"request", @"command", @"cwd", @"env", @"console", @"preLaunchTask", @"presentation" ]];
		for(NSString* key in definition)
		{
			if(![allowed containsObject:key])
				return RunConfigurationError(error, [NSString stringWithFormat:@"The node-terminal setting “%@” is not supported.", key]);
		}
		terminalWords = TerminalCommandWords(definition[@"command"], &terminalDirectory, error);
		if(!terminalWords)
			return nil;
	}

	id options = task ? definition[@"options"] : nil;
	if(options && ![options isKindOfClass:NSDictionary.class])
		return RunConfigurationError(error, @"Task options must be an object.");
	NSString* cwd = [self resolveValue:(task ? options[@"cwd"] : definition[@"cwd"]) ?: self.root file:file error:error];
	if(!cwd || !(cwd = RunWorkingDirectory(cwd, self.root, error)))
		return nil;
	if(terminalDirectory)
	{
		NSString* resolved = [self resolveValue:terminalDirectory file:file error:error];
		if(!resolved || !(cwd = RunWorkingDirectory(resolved, cwd, error)))
			return nil;
	}

	id entries = task ? options[@"env"] : definition[@"env"];
	if(entries && ![entries isKindOfClass:NSDictionary.class])
		return RunConfigurationError(error, @"The run environment must be an object.");
	NSMutableDictionary* effectiveEnvironment = [environment mutableCopy] ?: [NSMutableDictionary dictionary];
	for(NSString* key in entries)
	{
		if(!key.length || [key containsString:@"="] || [key rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound)
			return RunConfigurationError(error, @"An environment variable has an invalid name.");
		NSString* value = [self resolveValue:entries[key] file:file error:error];
		if(!value)
			return nil;
		effectiveEnvironment[key] = value;
	}

	id args = terminal ? [terminalWords subarrayWithRange:NSMakeRange(1, terminalWords.count-1)] : definition[@"args"] ?: @[];
	if(![args isKindOfClass:NSArray.class])
		return RunConfigurationError(error, @"Run arguments must be an array of strings.");
	NSMutableArray* arguments = [NSMutableArray array];
	NSMutableArray<NSString*>* buildFlags = [NSMutableArray array];
	NSString* debugProgram = nil;
	NSString* program = [self resolveValue:terminal ? terminalWords.firstObject : definition[task ? @"command" : @"program"] file:file error:error];
	if(!program)
		return nil;
	if(!program.length)
		return RunConfigurationError(error, @"The command or program cannot be empty.");
	if(go)
	{
		id rawBuildFlags = definition[@"buildFlags"];
		if([rawBuildFlags isKindOfClass:NSString.class])
		{
			NSString* text = [rawBuildFlags stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
			rawBuildFlags = text.length ? RunCommandWords(text, nil, @"buildFlags must be a quoted list of Go arguments without shell operators.", error) : @[];
			if(!rawBuildFlags)
				return nil;
		}
		if(rawBuildFlags && ![rawBuildFlags isKindOfClass:NSArray.class])
			return RunConfigurationError(error, @"buildFlags must be a string or an array of strings.");
		for(id flag in rawBuildFlags)
		{
			NSString* resolved = [self resolveValue:flag file:file error:error];
			if(!resolved)
				return nil;
			[buildFlags addObject:resolved];
		}
		id mode = definition[@"mode"] ?: @"auto";
		if(![mode isEqual:@"auto"] && ![mode isEqual:@"debug"])
			return RunConfigurationError(error, @"Run without debugging supports Go modes auto and debug.");
		if([program hasPrefix:@"-"])
			return RunConfigurationError(error, @"The Go program must name a local directory or source file.");
		NSString* path = program.isAbsolutePath ? program : [cwd stringByAppendingPathComponent:program];
		BOOL programIsDirectory = NO;
		if(![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&programIsDirectory] || (!programIsDirectory && ![path.pathExtension isEqual:@"go"]))
			return RunConfigurationError(error, @"The Go program must name a local directory or .go source file.");
		if(programIsDirectory)
		{
			if(!definition[@"cwd"])
				cwd = path.stringByStandardizingPath;
			NSString* relative = to_ns(path::relative_to(to_s(path), to_s(cwd)));
			program = relative.length ? ([relative hasPrefix:@"/"] || [relative hasPrefix:@"../"] ? relative : [@"./" stringByAppendingString:relative]) : @".";
		}
		else
		{
			program = path.stringByStandardizingPath;
			if(!definition[@"cwd"])
				cwd = program.stringByDeletingLastPathComponent;
		}
		if(launchArguments)
		{
			debugProgram = program;
			program = @"dlv";
		}
		else
		{
			[arguments addObject:@"run"];
			[arguments addObjectsFromArray:buildFlags];
			[arguments addObject:program];
			program = @"go";
		}
	}
	for(id argument in args)
	{
		NSString* resolved = [self resolveValue:argument file:file error:error];
		if(!resolved)
			return nil;
		[arguments addObject:resolved];
	}

	NSString* executable = nil;
	if([program containsString:@"/"])
		executable = (program.isAbsolutePath ? program : [cwd stringByAppendingPathComponent:program]).stringByStandardizingPath;
	else
	{
		for(NSString* directory in [effectiveEnvironment[@"PATH"] componentsSeparatedByString:@":"])
		{
			if(!directory.isAbsolutePath)
				continue;
			NSString* path = [directory stringByAppendingPathComponent:program];
			BOOL isDirectory = NO;
			if([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && !isDirectory && [NSFileManager.defaultManager isExecutableFileAtPath:path])
			{
				executable = path;
				break;
			}
		}
	}
	BOOL isExecutableDirectory = NO;
	if(!executable || ![NSFileManager.defaultManager fileExistsAtPath:executable isDirectory:&isExecutableDirectory] ||
	   isExecutableDirectory || ![NSFileManager.defaultManager isExecutableFileAtPath:executable])
	{
		if(launchArguments)
			return RunConfigurationError(error, @"Delve (dlv) was not found. Install it in ~/go/bin or put it on PATH.");
		return RunConfigurationError(error, [NSString stringWithFormat:@"Executable “%@” is unavailable.", program]);
	}

	ProjectRunCommand* command = [ProjectRunCommand new];
	command.executable = executable;
	command.arguments = launchArguments ? @[ @"dap" ] : [arguments copy];
	command.directory = cwd;
	command.environment = [effectiveEnvironment copy];
	if(launchArguments)
	{
		NSMutableDictionary* launch = [@{ @"mode": @"debug", @"program": debugProgram, @"cwd": cwd, @"args": [arguments copy],
		                                 @"stopOnEntry": definition[@"stopOnEntry"] ?: @NO } mutableCopy];
		if(buildFlags.count)
			launch[@"buildFlags"] = [buildFlags copy];
		*launchArguments = [launch copy];
	}
	return command;
}

- (NSArray<ProjectRunCommand*>*)resolvedCommandsForFile:(NSString*)file environment:(NSDictionary<NSString*, NSString*>*)environment launchArguments:(NSDictionary**)launchArguments error:(NSError**)error
{
	file = file.stringByStandardizingPath.stringByResolvingSymlinksInPath;
	if(file && ![self.root isEqual:@"/"] && !path::is_child(to_s(file), to_s(self.root)))
		file = nil;
	NSMutableArray* commands = [NSMutableArray array];
	if(!self.task && self.definition[@"preLaunchTask"])
	{
		id label = self.definition[@"preLaunchTask"];
		if(![label isKindOfClass:NSString.class] || ![label length])
			return RunConfigurationError(error, @"preLaunchTask must name one task in this folder.");
		NSDictionary* match = nil;
		for(NSDictionary* task in self.tasks)
		{
			if(![task[@"label"] isEqual:label])
				continue;
			if(match)
				return RunConfigurationError(error, [NSString stringWithFormat:@"The pre-launch task “%@” is ambiguous.", label]);
			match = task;
		}
		if(!match)
			return RunConfigurationError(error, [NSString stringWithFormat:@"The pre-launch task “%@” was not found in this folder.", label]);
		ProjectRunCommand* command = [self commandForDefinition:match task:YES file:file environment:environment launchArguments:nil error:error];
		if(!command)
			return nil;
		[commands addObject:command];
	}
	ProjectRunCommand* launch = [self commandForDefinition:self.definition task:self.task file:file environment:environment launchArguments:launchArguments error:error];
	if(!launch)
		return nil;
	[commands addObject:launch];
	return commands;
}

- (NSArray<ProjectRunCommand*>*)commandsForFile:(NSString*)file environment:(NSDictionary<NSString*, NSString*>*)environment error:(NSError**)error
{
	return [self resolvedCommandsForFile:file environment:environment launchArguments:nil error:error];
}

- (ProjectDebugPlan*)debugPlanForFile:(NSString*)file environment:(NSDictionary<NSString*, NSString*>*)environment error:(NSError**)error
{
	if(!self.task && [self.definition[@"type"] isEqual:@"node-terminal"])
		return RunConfigurationError(error, @"Use Run or Control-F5 for node-terminal configurations. Debug requires a local Go launch.");
	if(!self.supportsDebugging)
		return RunConfigurationError(error, @"Debug supports only local Go launch configurations in auto or debug mode.");

	NSSet* allowed = [NSSet setWithArray:@[ @"name", @"type", @"request", @"mode", @"program", @"cwd", @"args", @"env", @"console", @"preLaunchTask", @"stopOnEntry", @"buildFlags", @"presentation" ]];
	for(NSString* key in self.definition)
	{
		if(![allowed containsObject:key])
			return RunConfigurationError(error, [NSString stringWithFormat:@"The debug setting “%@” is not supported.", key]);
	}
	id stopOnEntry = self.definition[@"stopOnEntry"];
	if(stopOnEntry && CFGetTypeID((__bridge CFTypeRef)stopOnEntry) != CFBooleanGetTypeID())
		return RunConfigurationError(error, @"stopOnEntry must be true or false.");

	NSDictionary* launchArguments = nil;
	NSArray<ProjectRunCommand*>* commands = [self resolvedCommandsForFile:file environment:environment launchArguments:&launchArguments error:error];
	if(!commands)
		return nil;
	ProjectDebugPlan* plan = [ProjectDebugPlan new];
	plan.tasks = [commands subarrayWithRange:NSMakeRange(0, commands.count-1)];
	plan.adapter = commands.lastObject;
	plan.launchArguments = launchArguments;
	return plan;
}
@end
