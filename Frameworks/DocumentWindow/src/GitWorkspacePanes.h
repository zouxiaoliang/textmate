#import <Cocoa/Cocoa.h>

@interface GitWorkspaceReviewPane : NSViewController
- (instancetype)initWithPullRequests:(BOOL)pullRequests;
@property (nonatomic) BOOL softWrap;
@property (nonatomic, copy) NSString* repository;
@property (nonatomic, copy) NSString* filter;
@property (nonatomic, copy) void (^showHistory)(NSString* ref);
@property (nonatomic, copy) BOOL (^canCheckOut)(void);
@property (nonatomic, copy) void (^populateBranchMenu)(NSMenu* menu, NSDictionary* branch, NSArray<NSDictionary*>* refs, NSArray<NSDictionary*>* githubRemotes);
@property (nonatomic, copy) void (^repositoryDidChange)(void);
- (void)showCreatePullRequestFromBranch:(NSString*)branch remote:(NSDictionary*)remote base:(NSString*)base;
- (void)refresh;
- (void)focusList;
@end

@interface GitWorkspaceSettingsPane : NSViewController
@property (nonatomic, copy) NSString* repository;
@property (nonatomic, copy) void (^repositoryDidChange)(void);
@property (nonatomic, copy) BOOL (^hasUnsavedBuffer)(NSString* path);
@property (nonatomic, copy) BOOL (^canChangeWorkingTree)(void);
- (void)refresh;
@end
