#import <Foundation/Foundation.h>

@class ProjectRunCommand;

@interface ProjectRunSession : NSObject
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly, getter=isStopping) BOOL stopping;
@property (nonatomic, copy) void (^didStartCommand)(ProjectRunCommand* command);
@property (nonatomic, copy) void (^didReadOutput)(NSData* data);
@property (nonatomic, copy) void (^didFinish)(int exitCode, BOOL stopped, NSError* error);
- (void)runCommands:(NSArray<ProjectRunCommand*>*)commands;
- (void)stop;
- (void)invalidate;
@end
