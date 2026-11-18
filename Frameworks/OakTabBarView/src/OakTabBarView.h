#import <oak/misc.h>

typedef NS_ENUM(NSInteger, OakTabStatus) {
    OakTabStatusNone, OakTabStatusWorking, OakTabStatusBlocked, OakTabStatusDone, OakTabStatusError
};

@protocol OakTabBarViewDelegate, OakTabBarViewDataSource;

@interface OakTabBarView : NSView
@property (nonatomic, weak) id <OakTabBarViewDelegate> delegate;
@property (nonatomic, weak) id <OakTabBarViewDataSource> dataSource;
@property (nonatomic, readonly) NSInteger countOfVisibleTabs;
@property (nonatomic) NSUInteger selectedTabIndex;
- (void)reloadData;
- (void)performClose:(id)sender;

@property (nonatomic) BOOL neverHideLeftBorder;
@property (nonatomic, getter=isWindowTitleBar) BOOL windowTitleBar;
@property (nonatomic, copy) NSString* collapsedTitle;
@property (nonatomic) NSColor* titleBarBackgroundColor;

// iTerm2 Minimal: reserve leading space for floating traffic lights so
// tabs begin to their right; the inset strip stays part of the bar and
// participates in window dragging.
@property (nonatomic) CGFloat leadingContentInset;

// A short status message shown in the bar's trailing edge, e.g. the terminal's
// unseen state; nil (or empty) hides it again.
- (void)setStatusText:(NSString*)text color:(NSColor*)color;

@end

@protocol OakTabBarViewDelegate <NSObject>
@optional
- (BOOL)tabBarView:(OakTabBarView*)aTabBarView shouldSelectIndex:(NSUInteger)anIndex;
- (void)tabBarView:(OakTabBarView*)aTabBarView didDoubleClickIndex:(NSUInteger)anIndex;
- (void)tabBarViewDidDoubleClick:(OakTabBarView*)aTabBarView;
- (NSMenu*)menuForTabBarView:(OakTabBarView*)aTabBarView;

// Methods sent to the delegate which the tab was dragged to
- (BOOL)performDropOfTabItem:(NSUUID*)tabItemUUID fromTabBar:(OakTabBarView*)sourceTabBar index:(NSUInteger)dragIndex toTabBar:(OakTabBarView*)destTabBar index:(NSUInteger)droppedIndex operation:(NSDragOperation)operation;

- (void)performCloseTab:(OakTabBarView*)sender;
- (void)performCloseOtherTabsXYZ:(OakTabBarView*)sender;

// Sent when the bar's "+" (create new tab) button is clicked.
- (void)newTabInTabBar:(OakTabBarView*)sender;

- (NSImage*)tabBarView:(OakTabBarView*)sender tearOffPreviewForTabAtIndex:(NSUInteger)anIndex;
- (void)tabBarView:(OakTabBarView*)sender didTearOffTabAtIndex:(NSUInteger)anIndex atWindowTopLeft:(NSPoint)topLeft;
@end

@protocol OakTabBarViewDataSource <NSObject>
- (NSUInteger)numberOfRowsInTabBarView:(OakTabBarView*)aTabBarView;

- (NSString*)tabBarView:(OakTabBarView*)aTabBarView titleForIndex:(NSUInteger)anIndex;
- (NSString*)tabBarView:(OakTabBarView*)aTabBarView pathForIndex:(NSUInteger)anIndex;
- (NSUUID*)tabBarView:(OakTabBarView*)aTabBarView UUIDForIndex:(NSUInteger)anIndex;
- (BOOL)tabBarView:(OakTabBarView*)aTabBarView isEditedAtIndex:(NSUInteger)anIndex;
@optional

// Optional because the path is the sensible tooltip for a data source without a better description.
// Return an empty string for "no tooltip"; the tab then falls back to its path, which is empty too.
- (NSString*)tabBarView:(OakTabBarView*)aTabBarView toolTipForIndex:(NSUInteger)anIndex;
- (OakTabStatus)tabBarView:(OakTabBarView*)bar statusForIndex:(NSUInteger)index;
- (NSString*)tabBarView:(OakTabBarView*)bar statusDescriptionForIndex:(NSUInteger)index;
@end
