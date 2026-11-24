#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, GitStashAction) {
	GitStashApply, GitStashDelete, GitStashDiffTool,
};

@interface GitRevisionView : NSView
@property (nonatomic) BOOL softWrap;
@property (nonatomic, copy) NSString* syntaxThemeUUID;
@property (nonatomic, copy) void (^stashActionHandler)(GitStashAction action);
@property (nonatomic, copy) void (^showFileHistory)(NSString* path);
@property (nonatomic, copy) void (^restoreFile)(NSString* root, NSString* revision, NSString* path);
- (void)setStashActionsEnabled:(BOOL)enabled diffToolEnabled:(BOOL)diffToolEnabled;
- (void)showRevision:(NSDictionary*)revision repository:(NSString*)root stash:(BOOL)stash;
- (void)showRevision:(NSDictionary*)revision repository:(NSString*)root stash:(BOOL)stash completion:(void(^)(void))completion;
- (void)showComparison:(NSDictionary*)comparison repository:(NSString*)root;
- (void)showComparison:(NSDictionary*)comparison repository:(NSString*)root completion:(void(^)(void))completion;
@end
