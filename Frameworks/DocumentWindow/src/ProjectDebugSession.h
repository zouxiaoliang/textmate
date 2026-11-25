#import <Foundation/Foundation.h>

@class ProjectDebugPlan;

typedef NS_ENUM(NSUInteger, ProjectDebugState) {
	ProjectDebugIdle,
	ProjectDebugStarting,
	ProjectDebugRunning,
	ProjectDebugPaused,
	ProjectDebugStopping,
};

@interface ProjectDebugSession : NSObject
@property (nonatomic, readonly) ProjectDebugState state;
@property (nonatomic, readonly) BOOL canPause;
@property (nonatomic, readonly) BOOL canStep;
@property (nonatomic, readonly) NSArray<NSDictionary*>* frames;
@property (nonatomic, readonly) NSNumber* stoppedThreadID;
@property (nonatomic, readonly) NSNumber* selectedThreadID;
@property (nonatomic, copy) void (^didChangeState)(ProjectDebugState state, NSString* detail);
@property (nonatomic, copy) void (^didReadOutput)(NSString* text);
@property (nonatomic, copy) void (^didChangeFrames)(NSArray<NSDictionary*>* frames);
@property (nonatomic, copy) void (^didChangeVariables)(NSArray<NSDictionary*>* variables);
@property (nonatomic, copy) void (^didChangeBreakpointResults)(NSString* path);
- (void)start:(ProjectDebugPlan*)plan breakpoints:(NSDictionary<NSString*, NSArray<NSDictionary*>*>*)breakpoints;
- (void)setBreakpoints:(NSArray<NSDictionary*>*)breakpoints forPath:(NSString*)path;
- (NSDictionary*)breakpointResultAtPath:(NSString*)path line:(NSUInteger)line;
- (void)selectFrame:(NSDictionary*)frame;
- (void)loadThreads:(void (^)(NSArray<NSDictionary*>* threads, NSString* error))completion;
- (void)selectThread:(NSNumber*)thread;
- (void)evaluateWatchExpression:(NSString*)expression completion:(void (^)(NSDictionary* value, NSString* error))completion;
- (void)loadChildrenOfVariable:(NSNumber*)reference completion:(void (^)(NSArray<NSDictionary*>* values, NSString* error))completion;
- (void)continueExecution;
- (void)stepOver;
- (void)stepIn;
- (void)stepOut;
- (void)pause;
- (void)stop;
- (void)invalidate;
@end
