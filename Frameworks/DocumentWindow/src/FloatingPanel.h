#import <Cocoa/Cocoa.h>

@interface FloatingPanel : NSObject
@property (nonatomic, getter=isPinned) BOOL pinned;
@property (nonatomic, readonly, getter=isTucked) BOOL tucked;
@property (nonatomic) BOOL opensNearBottom;
@property (nonatomic) BOOL keepsOpenWhileKey;
@property (nonatomic, copy) void (^dismissHandler)(void);
- (instancetype)initWithContentView:(NSView*)contentView title:(NSString*)title;
- (void)showInWindow:(NSWindow*)owner;
- (void)refreshWindowOrdering;
- (void)focus;
- (void)dismiss;
- (void)beginDrag;
- (void)moveBy:(NSSize)offset atPoint:(NSPoint)point;
- (void)endDragAtPoint:(NSPoint)point;
@end

@interface FloatingPanelDragBar : NSStackView
@property (nonatomic, weak) FloatingPanel* panel;
@end

@interface FloatingPanelPinButton : NSButton
@property (nonatomic, weak) FloatingPanel* panel;
- (instancetype)initWithPanelName:(NSString*)name;
@end
