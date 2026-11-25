#import <Cocoa/Cocoa.h>
#import "GitRepository.h"

NSTextField* GitLabel(NSString* text, CGFloat size, NSFontWeight weight);
NSView* GitBadge(NSString* text, NSColor* fill);
NSButton* GitIconButton(NSString* symbol, NSString* label, id target, SEL action);
NSScrollView* GitScrollView(NSView* document);
NSView* GitPaneHeader(NSView* heading, CGFloat height = 40, CGFloat inset = 10);
NSView* GitPaneFooter(NSTextField* status, NSButton* action = nil);
NSTableRowView* GitListRow(BOOL fullWidthSeparator = NO);

@interface GitOutlineView : NSOutlineView
@end

@interface GitEditorTheme : NSObject
@property (nonatomic) NSColor* background;
@property (nonatomic) NSColor* foreground;
@property (nonatomic) NSColor* gutterBackground;
@property (nonatomic) NSColor* gutterForeground;
@property (nonatomic) NSAppearance* appearance;
@property (nonatomic, copy) NSString* syntaxThemeUUID;
@end

@interface GitDiffView : NSView
@property (nonatomic) NSImage* fileIcon;
@property (nonatomic, readonly) NSStackView* headerControls;
@property (nonatomic, readonly) NSStackView* footerOptions;
@property (nonatomic, readonly) NSStackView* footerControls;
@property (nonatomic) BOOL showsPatch;
@property (nonatomic) BOOL softWrap;
@property (nonatomic, copy) NSString* syntaxPath;
@property (nonatomic) GitEditorTheme* editorTheme;
- (instancetype)initWithFrame:(NSRect)frame inlinePatch:(BOOL)inlinePatch;
- (CGFloat)wrappedInlineHeightForWidth:(CGFloat)width;
- (void)setChunkActions:(NSArray<NSNumber*>*)actions handler:(void(^)(NSUInteger index, GitRepositoryAction action))handler;
- (void)setChunkActionsEnabled:(BOOL)enabled;
- (void)showTitle:(NSString*)title subtitle:(NSString*)subtitle patch:(NSDictionary*)patch;
- (void)showTitle:(NSString*)title subtitle:(NSString*)subtitle patch:(NSDictionary*)patch preserveScroll:(BOOL)preserve;
@end

NSArray<NSString*>* GitDiffHunks(NSString* patch);
CGFloat GitDiffInlineHeight(NSDictionary* patch);

@interface GitChangeWindowController : NSWindowController
@property (nonatomic) BOOL softWrap;
@property (nonatomic, copy) void (^softWrapChanged)(BOOL enabled);
- (void)showChange:(NSDictionary*)change snapshot:(NSDictionary*)snapshot buffers:(NSDictionary*)buffers;
@end
