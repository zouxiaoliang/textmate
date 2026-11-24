#import <Cocoa/Cocoa.h>
#import "GitRepository.h"

@interface SourceControlViewController : NSViewController
@property (nonatomic, copy) NSString* directory;
@property (nonatomic) BOOL panelVisible;
@property (nonatomic) BOOL workspaceLayout;
@property (nonatomic, copy) NSDictionary<NSString*, ProjectChangesBuffer*>* (^bufferProvider)(void);
@property (nonatomic, copy) void (^showDiff)(NSDictionary* change, NSDictionary* snapshot, NSDictionary* buffers);
@property (nonatomic, copy) void (^previewChange)(NSDictionary* change, NSDictionary* snapshot, NSDictionary* buffers);
@property (nonatomic, copy) void (^didRefresh)(NSDictionary* snapshot, NSUInteger changedFileCount);
@property (nonatomic, copy) void (^showFileHistory)(NSString* path);
@property (nonatomic, copy) void (^repositoryDidChange)(void);
@property (nonatomic, copy) void (^controlsDidChange)(void);
@property (nonatomic) NSColor* themeBackgroundColor;
@property (nonatomic, copy) NSString* searchString;
@property (nonatomic, readonly) NSUInteger workingCopySelectionCount;
- (IBAction)refresh:(id)sender;
- (IBAction)openActions:(NSButton*)sender;
- (IBAction)generateMessage:(id)sender;
- (BOOL)canPerformAction:(GitRepositoryAction)action;
- (void)performHunk:(NSString*)hunk change:(NSDictionary*)change action:(GitRepositoryAction)action contextLines:(NSUInteger)contextLines;
- (void)performToolbarAction:(GitRepositoryAction)action;
- (void)showToolbarAction:(GitRepositoryAction)action reference:(NSString*)reference quick:(BOOL)quick;
- (void)checkOutReference:(NSString*)reference;
- (void)runWorkspaceMutationAtRoot:(NSString*)root changesWorktree:(BOOL)changesWorktree path:(NSString*)path execute:(NSString*(^)(void))execute;
- (void)applyStash:(NSDictionary*)stash pop:(BOOL)pop;
- (void)chooseStashToApply:(NSArray<NSDictionary*>*)stashes preferred:(NSDictionary*)preferred;
- (void)deleteStash:(NSDictionary*)stash;
- (void)focusChanges;
@end
