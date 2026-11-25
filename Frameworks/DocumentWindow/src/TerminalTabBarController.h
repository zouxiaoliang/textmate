#import <Cocoa/Cocoa.h>
@class FloatingPanelDragBar, OakTabBarView, OakTerminalPanelController;

@interface TerminalTabBarController : NSObject
@property (nonatomic, copy) void (^detachSessionHandler)(NSUUID*);
// Fires after every reload, i.e. whenever the session list or one session's state changed.
@property (nonatomic, copy) void (^tabsDidReloadHandler)(void);
@property (nonatomic, readonly) OakTabBarView* tabBar;
@property (nonatomic, weak) FloatingPanelDragBar* floatingDragBar;
- (instancetype)initWithTerminalController:(OakTerminalPanelController*)controller;
@end
