#import <FileBrowser/FileBrowserView.h>
#import <OakTabBarView/OakTabBarView.h>

@interface ProjectLayoutView : NSView
@property (nonatomic) NSView* documentView;
@property (nonatomic) NSView* outlineView;
@property (nonatomic) FileBrowserView* fileBrowserView;
@property (nonatomic) NSView* fileBrowserActionsView;
@property (nonatomic) NSView* sourceControlView;
@property (nonatomic) NSView* runAndDebugView;
@property (nonatomic) NSView* htmlOutputView;
@property (nonatomic) NSColor* sidebarThemeBackgroundColor;
@property (nonatomic) BOOL sidebarThemeIsDark;

@property (nonatomic) BOOL fileBrowserCollapsed;
@property (nonatomic) BOOL sourceControlCollapsed;
@property (nonatomic) BOOL outlineCollapsed;
@property (nonatomic) BOOL runAndDebugCollapsed;
@property (nonatomic) CGFloat outlineHeight;
@property (nonatomic, copy) void (^sidebarStateDidChange)(ProjectLayoutView* layoutView);
@property (nonatomic, copy) void (^sidebarDidRequestClose)(void);

@property (nonatomic) CGFloat fileBrowserWidth;
@property (nonatomic) BOOL fileBrowserOnRight;
@property (nonatomic, readonly) CGFloat visibleSidebarWidth;
@property (nonatomic, readonly) CGFloat sidebarOpacity;
- (void)setSidebarTransitionWidth:(CGFloat)width opacity:(CGFloat)opacity;

@property (nonatomic) NSSize htmlOutputSize;
@property (nonatomic) BOOL htmlOutputOnRight;
@end
