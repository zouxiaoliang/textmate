#import <Foundation/Foundation.h>

NSDictionary<NSString*, NSString*>* ProjectRunDefaultEnvironment();

@interface ProjectRunCommand : NSObject
@property (nonatomic, readonly) NSString* executable;
@property (nonatomic, readonly) NSArray<NSString*>* arguments;
@property (nonatomic, readonly) NSString* directory;
@property (nonatomic, readonly) NSDictionary<NSString*, NSString*>* environment;
@property (nonatomic, readonly) NSString* displayCommand;
- (ProjectRunCommand*)commandWithArguments:(NSArray<NSString*>*)arguments;
@end

@interface ProjectDebugPlan : NSObject
@property (nonatomic, readonly) NSArray<ProjectRunCommand*>* tasks;
@property (nonatomic, readonly) ProjectRunCommand* adapter;
@property (nonatomic, readonly) NSDictionary* launchArguments;
@end

@interface ProjectRunConfiguration : NSObject
@property (nonatomic, readonly) NSString* name;
@property (nonatomic, readonly) NSString* root;
@property (nonatomic, readonly) NSString* title;
@property (nonatomic, readonly) NSString* identifier;
@property (nonatomic, readonly) BOOL task;
@property (nonatomic, readonly) BOOL supportsDebugging;

+ (NSArray<ProjectRunConfiguration*>*)configurationsForFolders:(NSArray<NSDictionary<NSString*, NSString*>*>*)folders errors:(NSMutableArray<NSError*>*)errors;
+ (NSURL*)openOrCreateLaunchConfigurationInFolder:(NSString*)folder error:(NSError**)error;
- (NSArray<ProjectRunCommand*>*)commandsForFile:(NSString*)file environment:(NSDictionary<NSString*, NSString*>*)environment error:(NSError**)error;
- (ProjectDebugPlan*)debugPlanForFile:(NSString*)file environment:(NSDictionary<NSString*, NSString*>*)environment error:(NSError**)error;
@end
