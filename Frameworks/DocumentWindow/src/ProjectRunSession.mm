#import "ProjectRunSession.h"
#import "ProjectRun.h"
#include <spawn.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>

static int RunSpawn(ProjectRunCommand* command, pid_t* child, int* output)
{
	int pipes[2];
	if(pipe(pipes) != 0)
		return errno;
	int error = 0;
	for(int& descriptor : pipes)
	{
		if(descriptor <= STDERR_FILENO)
		{
			int replacement = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO+1);
			if(replacement == -1)
			{
				error = errno;
				break;
			}
			close(descriptor);
			descriptor = replacement;
		}
		else if(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == -1)
		{
			error = errno;
			break;
		}
	}
	if(!error && fcntl(pipes[0], F_SETFL, O_NONBLOCK) == -1)
		error = errno;

	posix_spawn_file_actions_t actions;
	posix_spawnattr_t attributes;
	BOOL actionsReady = !error && !(error = posix_spawn_file_actions_init(&actions));
	BOOL attributesReady = !error && !(error = posix_spawnattr_init(&attributes));
	if(!error)
	{
		sigset_t defaults, mask;
		sigemptyset(&defaults);
		sigemptyset(&mask);
		sigaddset(&defaults, SIGINT);
		sigaddset(&defaults, SIGTERM);
		sigaddset(&defaults, SIGPIPE);

		error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_SETSIGDEF|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_CLOEXEC_DEFAULT);
		if(!error) error = posix_spawnattr_setpgroup(&attributes, 0);
		if(!error) error = posix_spawnattr_setsigdefault(&attributes, &defaults);
		if(!error) error = posix_spawnattr_setsigmask(&attributes, &mask);
		if(!error) error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
		if(!error) error = posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
		if(!error) error = posix_spawn_file_actions_adddup2(&actions, pipes[1], STDERR_FILENO);
		if(!error) error = posix_spawn_file_actions_addclose(&actions, pipes[1]);
		if(!error) error = posix_spawn_file_actions_addclose(&actions, pipes[0]);
		if(!error)
		{
			if(@available(macOS 26.0, *))
				error = posix_spawn_file_actions_addchdir(&actions, command.directory.fileSystemRepresentation);
			else
			{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
				error = posix_spawn_file_actions_addchdir_np(&actions, command.directory.fileSystemRepresentation);
#pragma clang diagnostic pop
			}
		}

		if(!error)
		{
			std::vector<std::string> argumentStorage;
			argumentStorage.emplace_back(command.executable.fileSystemRepresentation);
			for(NSString* argument in command.arguments)
				argumentStorage.emplace_back(argument.UTF8String);
			std::vector<char*> arguments;
			for(auto& argument : argumentStorage)
				arguments.push_back(argument.data());
			arguments.push_back(nullptr);

			std::vector<std::string> environmentStorage;
			for(NSString* name in command.environment)
				environmentStorage.emplace_back(std::string(name.UTF8String) + "=" + command.environment[name].UTF8String);
			std::vector<char*> environment;
			for(auto& entry : environmentStorage)
				environment.push_back(entry.data());
			environment.push_back(nullptr);

			error = posix_spawn(child, arguments.front(), &actions, &attributes, arguments.data(), environment.data());
		}
	}
	if(attributesReady) posix_spawnattr_destroy(&attributes);
	if(actionsReady) posix_spawn_file_actions_destroy(&actions);
	close(pipes[1]);
	if(error)
		close(pipes[0]);
	else
		*output = pipes[0];
	return error;
}

@implementation ProjectRunSession
{
	NSArray<ProjectRunCommand*>* _commands;
	NSUInteger _step;
	NSTimer* _timer;
	pid_t _child;
	int _output;
	int _exitCode;
	BOOL _reaped;
	CFAbsoluteTime _stopDeadline;
}

- (instancetype)init
{
	if(self = [super init])
	{
		_child = -1;
		_output = -1;
	}
	return self;
}

- (BOOL)isRunning { return _commands != nil; }
- (BOOL)isStopping { return _stopDeadline != 0; }

- (void)runCommands:(NSArray<ProjectRunCommand*>*)commands
{
	if(self.isRunning || commands.count == 0)
		return;
	_commands = [commands copy];
	_step = 0;
	[self startNextCommand];
}

- (void)startNextCommand
{
	ProjectRunCommand* command = _commands[_step];
	if(self.didStartCommand)
		self.didStartCommand(command);
	int error = RunSpawn(command, &_child, &_output);
	if(error)
	{
		_child = -1;
		[self finishWithExitCode:-1 stopped:NO error:[NSError errorWithDomain:NSPOSIXErrorDomain code:error userInfo:nil]];
		return;
	}

	_reaped = NO;
	__weak ProjectRunSession* weakSelf = self;
	_timer = [NSTimer timerWithTimeInterval:0.04 repeats:YES block:^(NSTimer* timer){ [weakSelf poll]; }];
	_timer.tolerance = 0.008;
	[NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)stop
{
	if(!self.isRunning || self.isStopping)
		return;
	_stopDeadline = CFAbsoluteTimeGetCurrent() + 0.6;
	if(_child > 0 && !_reaped)
		kill(-_child, SIGTERM);
}

- (BOOL)drainOutput
{
	NSMutableData* data = [NSMutableData data];
	char buffer[8192];
	while(data.length < 128 * 1024)
	{
		ssize_t count = read(_output, buffer, sizeof(buffer));
		if(count < 0 && errno == EINTR)
			continue;
		if(count <= 0)
			break;
		[data appendBytes:buffer length:count];
	}
	if(data.length && self.didReadOutput)
		self.didReadOutput(data);
	return data.length < 128 * 1024;
}

- (void)poll
{
	if(self.isStopping && !_reaped && CFAbsoluteTimeGetCurrent() >= _stopDeadline)
		kill(-_child, SIGKILL);

	if(!_reaped && (!self.isStopping || CFAbsoluteTimeGetCurrent() >= _stopDeadline))
	{
		int status;
		pid_t result = waitpid(_child, &status, WNOHANG);
		if(result == _child)
		{
			_reaped = YES;
			_exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
		}
		else if(result == -1 && errno != EINTR)
		{
			NSError* error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
			[self finishWithExitCode:-1 stopped:self.isStopping error:error];
			return;
		}
	}
	if(![self drainOutput] || !_reaped)
		return;

	[self tearDownTimerAndPipe];
	if(!self.isStopping && _exitCode == 0 && ++_step < _commands.count)
		[self startNextCommand];
	else
		[self finishWithExitCode:_exitCode stopped:self.isStopping error:nil];
}

- (void)tearDownTimerAndPipe
{
	if(_timer)
	{
		[_timer invalidate];
		_timer = nil;
	}
	if(_output != -1)
	{
		close(_output);
		_output = -1;
	}
	_child = -1;
}

- (void)finishWithExitCode:(int)exitCode stopped:(BOOL)stopped error:(NSError*)error
{
	[self tearDownTimerAndPipe];
	_commands = nil;
	_stopDeadline = 0;
	if(self.didFinish)
		self.didFinish(exitCode, stopped, error);
}

- (void)invalidate
{
	if(_child > 0 && !_reaped)
	{
		pid_t child = _child;
		kill(-child, SIGKILL);
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
			while(waitpid(child, nullptr, 0) == -1 && errno == EINTR) {}
		});
	}
	[self tearDownTimerAndPipe];
	_commands = nil;
	_stopDeadline = 0;
}

- (void)dealloc
{
	[self invalidate];
}
@end
