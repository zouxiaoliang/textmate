#import <Cocoa/Cocoa.h>
#import "GitRepository.h"

@class GitEditorTheme;

@interface GitWorkspaceViewController : NSViewController
@property (nonatomic, copy) NSString* directory;
@property (nonatomic) GitEditorTheme* editorTheme;
@property (nonatomic) BOOL softWrap;
@property (nonatomic, getter=isActive) BOOL active;
@property (nonatomic, readonly) NSView* titleBarItems;
@property (nonatomic, copy) NSDictionary<NSString*, ProjectChangesBuffer*>* (^bufferProvider)(void);
@property (nonatomic, copy) void (^repositoryDidChange)(void);
- (IBAction)refresh:(id)sender;
- (void)layoutTitleBarAfterLeadingControls:(CGFloat)leadingControlsEnd;
- (void)focusWorkspace;
@end
