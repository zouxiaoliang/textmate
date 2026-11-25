#import "TerminalPanelViewController.h"
#import "TerminalTabBarController.h"
#import "FloatingPanel.h"
#import <OakAppKit/OakUIConstructionFunctions.h>
#if HAVE_OAK_SWIFTUI
	#import "OakSwiftUI-Swift.h"
#endif

NSString* const kUserDefaultsTerminalPanelPlacementKey = @"terminalPanelPlacement";
NSString* const kTerminalPanelPositionLeft   = @"left";
NSString* const kTerminalPanelPositionRight  = @"right";
NSString* const kTerminalPanelPositionBottom = @"bottom";
NSString* const kTerminalPanelPositionFloating = @"floating";
static NSString* const kUserDefaultsTerminalPanelWidthKey  = @"terminalPanelWidth";
static NSString* const kUserDefaultsTerminalPanelHeightKey = @"terminalPanelHeight";

static CGFloat const kDefaultPanelWidth  = 320;
static CGFloat const kDefaultPanelHeight = 220;
static CGFloat const kMinimumPanelWidth  = 120;
static CGFloat const kMinimumPanelHeight = 100;
static CGFloat const kMinimumContentWidth  = 240;
static CGFloat const kMinimumContentHeight = 120;
static CGFloat const kFloatingHeaderInset = 6;
static CGFloat const kFloatingHeaderHeight = 24;

static NSString* SupportedPanelPosition (NSString* position)
{
	if([kTerminalPanelPositionFloating isEqual:position])
		return TEXTMATE_ENABLE_FLOATING_TERMINAL ? kTerminalPanelPositionFloating : kTerminalPanelPositionBottom;
	return [@[ kTerminalPanelPositionLeft, kTerminalPanelPositionRight, kTerminalPanelPositionBottom ] containsObject:position] ? position : nil;
}

typedef NS_ENUM(NSInteger, TerminalDividerDrag) {
	TerminalDividerDragBegan,
	TerminalDividerDragMoved,
	TerminalDividerDragEnded,
};

// Laid out entirely by Auto Layout, like ProjectLayoutView, so the content's own constraints reach the window instead of being pinned to a frame.
@interface TerminalPanelLayoutView : NSView
@property (nonatomic) NSView* divider; // nil while the panel is hidden
@property (nonatomic) BOOL dividerAlongYAxis;
@property (nonatomic, copy) void (^dividerDragHandler)(TerminalDividerDrag phase, NSSize offset);
@property (nonatomic, copy) void (^windowChangedHandler)(void);
@property (nonatomic) BOOL mouseDownRecursionGuard;
@end

@implementation TerminalPanelLayoutView
- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	if(self.windowChangedHandler)
		self.windowChangedHandler();
}

- (NSRect)dividerResizeRect
{
	if(!_divider)
		return NSZeroRect;
	return _dividerAlongYAxis ? NSInsetRect(_divider.frame, -4, 0) : NSInsetRect(_divider.frame, 0, -4);
}

- (void)layout
{
	[super layout];
	[self.window invalidateCursorRectsForView:self];
}

- (void)resetCursorRects
{
	[self addCursorRect:[self dividerResizeRect] cursor:_dividerAlongYAxis ? NSCursor.resizeLeftRightCursor : NSCursor.resizeUpDownCursor];
}

- (BOOL)mouseDownCanMoveWindow
{
	return NO;
}

- (NSView*)hitTest:(NSPoint)aPoint
{
	if(NSMouseInRect([self convertPoint:aPoint fromView:self.superview], [self dividerResizeRect], self.isFlipped))
		return self;
	return [super hitTest:aPoint];
}

- (void)mouseDown:(NSEvent*)anEvent
{
	NSPoint mouseDownPos = [self convertPoint:anEvent.locationInWindow fromView:nil];
	if(_mouseDownRecursionGuard || anEvent.type != NSEventTypeLeftMouseDown || !NSMouseInRect(mouseDownPos, [self dividerResizeRect], self.isFlipped))
		return [super mouseDown:anEvent];
	_mouseDownRecursionGuard = YES;

	NSEvent* mouseDownEvent = anEvent;
	BOOL didDrag = NO;
	_dividerDragHandler(TerminalDividerDragBegan, NSZeroSize);
	while(anEvent.type != NSEventTypeLeftMouseUp)
	{
		anEvent = [NSApp nextEventMatchingMask:(NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseDown|NSEventMaskLeftMouseUp) untilDate:NSDate.distantFuture inMode:NSEventTrackingRunLoopMode dequeue:YES];
		if(anEvent.type != NSEventTypeLeftMouseDragged)
			break;

		NSPoint mouseCurrentPos = [self convertPoint:anEvent.locationInWindow fromView:nil];
		if(!didDrag && hypot(mouseDownPos.x - mouseCurrentPos.x, mouseDownPos.y - mouseCurrentPos.y) < 2.5)
			continue;

		_dividerDragHandler(TerminalDividerDragMoved, NSMakeSize(mouseCurrentPos.x - mouseDownPos.x, mouseCurrentPos.y - mouseDownPos.y));
		didDrag = YES;
	}
	_dividerDragHandler(TerminalDividerDragEnded, NSZeroSize);

	if(!didDrag)
	{
		NSView* view = [super hitTest:[self.superview convertPoint:mouseDownEvent.locationInWindow fromView:nil]];
		if(view && view != self)
		{
			[NSApp postEvent:anEvent atStart:NO];
			[view mouseDown:mouseDownEvent];
		}
	}
	_mouseDownRecursionGuard = NO;
}
@end

#if HAVE_OAK_SWIFTUI
@interface TerminalPanelViewController () <OakTerminalPanelControllerDelegate>
#else
@interface TerminalPanelViewController ()
#endif
@property (nonatomic) TerminalPanelLayoutView* layoutView;
#if HAVE_OAK_SWIFTUI
@property (nonatomic) OakTerminalPanelController* terminalController;
@property (nonatomic) TerminalTabBarController* terminalTabBarController;
#endif
#if HAVE_OAK_SWIFTUI
@property (nonatomic) OakTerminalTheme* terminalTheme;
#endif
@property (nonatomic) NSFont* terminalFont;
@property (nonatomic) NSView* contentView;
@property (nonatomic) NSView* panelView;
@property (nonatomic) FloatingPanel* floatingPanel;
@property (nonatomic) NSBox* floatingSurface;
@property (nonatomic) FloatingPanelDragBar* floatingDragBar;
@property (nonatomic) NSView* floatingTabs;
@property (nonatomic) NSView* floatingBody;
@property (nonatomic) NSMutableArray<NSLayoutConstraint*>* layoutConstraints;
@property (nonatomic) NSLayoutConstraint* panelSizeConstraint;
@property (nonatomic) CGFloat dragInitialSize;
@end

@implementation TerminalPanelViewController
+ (void)initialize
{
	[NSUserDefaults.standardUserDefaults registerDefaults:@{
		kUserDefaultsTerminalPanelPlacementKey: kTerminalPanelPositionBottom,
		kUserDefaultsTerminalPanelWidthKey:     @(kDefaultPanelWidth),
		kUserDefaultsTerminalPanelHeightKey:    @(kDefaultPanelHeight),
	}];
}

- (instancetype)initWithContentView:(NSView*)contentView
{
	if(self = [super initWithNibName:nil bundle:nil])
	{
		_contentView = contentView;
		NSString* placement = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsTerminalPanelPlacementKey];
		_panelPosition = SupportedPanelPosition(placement) ?: kTerminalPanelPositionBottom;
		_panelWidth    = MAX(kMinimumPanelWidth, [NSUserDefaults.standardUserDefaults doubleForKey:kUserDefaultsTerminalPanelWidthKey]);
		_panelHeight   = MAX(kMinimumPanelHeight, [NSUserDefaults.standardUserDefaults doubleForKey:kUserDefaultsTerminalPanelHeightKey]);
		_layoutConstraints = [NSMutableArray array];
		_layoutView = [[TerminalPanelLayoutView alloc] initWithFrame:NSZeroRect];
		__weak TerminalPanelViewController* weakSelf = self;
		_layoutView.dividerDragHandler = ^(TerminalDividerDrag phase, NSSize offset){
			[weakSelf dragDivider:phase offset:offset];
		};
		_layoutView.windowChangedHandler = ^{ [weakSelf updateFloatingPresentation]; };
		self.view = _layoutView;

		NSBox* panel = [[NSBox alloc] initWithFrame:NSZeroRect];
		panel.boxType = NSBoxCustom;
		panel.borderWidth = 0;
		panel.fillColor = NSColor.windowBackgroundColor;
		panel.contentViewMargins = NSZeroSize;
		panel.accessibilityLabel = @"Terminal Panel";
		_panelView = panel;
		[self rebuildLayout];
	}
	return self;
}

- (void)prepareTerminalController
{
#if HAVE_OAK_SWIFTUI
	if(!_terminalController)
	{
		_terminalController = [[OakTerminalPanelController alloc] init];
		_terminalTabBarController = [[TerminalTabBarController alloc] initWithTerminalController:_terminalController];
		__weak TerminalPanelViewController* weakSelf = self;
		_terminalTabBarController.detachSessionHandler = ^(NSUUID* identifier){
			if(weakSelf.detachSessionHandler) weakSelf.detachSessionHandler(identifier);
		};
		// The tab bar owns the controller's `tabsDidChange` block; this rides on its single reload seam.
		_terminalTabBarController.tabsDidReloadHandler = ^{
			if(weakSelf.terminalAttentionDidChange)
				weakSelf.terminalAttentionDidChange();
		};
		_terminalController.shellPath = self.terminalShellPath;
		_terminalController.shellArguments = self.terminalShellArguments;
		_terminalController.delegate = self;
		_terminalController.contextEnvironmentProvider = self.contextEnvironmentProvider;
		_terminalController.contextSessionClosed = self.contextSessionClosed;
		[_panelView removeFromSuperview];
		_panelView = _terminalController.view;
		if([self usesFloatingPanel])
			[self attachFloatingContent];
		else
			[self rebuildLayout];
	}
	if(_terminalFont)
		[_terminalController applyFont:_terminalFont];
	if(_terminalTheme)
		[_terminalController applyTheme:_terminalTheme];
#endif
}

#if HAVE_OAK_SWIFTUI
- (void)terminalPanel:(OakTerminalPanelController*)panel openFile:(NSURL*)url line:(NSInteger)line column:(NSInteger)column
{
	if(self.openTerminalFile)
		self.openTerminalFile(url, line, column);
}

- (NSString*)terminalPanelWorkingDirectory:(OakTerminalPanelController*)panel
{
	return self.terminalDirectoryProvider ? self.terminalDirectoryProvider() : nil;
}

- (NSDictionary<NSString*, NSString*>*)terminalPanel:(OakTerminalPanelController*)panel environmentForDirectory:(NSString*)directory
{
	return self.terminalEnvironmentProvider ? self.terminalEnvironmentProvider(directory) : NSProcessInfo.processInfo.environment;
}

- (void)terminalPanelDidCloseLastSession:(OakTerminalPanelController*)panel
{
	if(self.lastSessionClosedHandler)
		self.lastSessionClosedHandler();
}
#endif

- (BOOL)hasTerminal
{
#if HAVE_OAK_SWIFTUI
	return _terminalController != nil;
#else
	return NO;
#endif
}

- (NSArray<NSUUID*>*)terminalSessionIdentifiers
{
#if HAVE_OAK_SWIFTUI
	return _terminalController.sessionIdentifiers ?: @[ ];
#else
	return @[ ];
#endif
}

- (void)closeTerminalSessions:(NSArray<NSUUID*>*)identifiers
{
#if HAVE_OAK_SWIFTUI
	[_terminalController closeSessionsWithIdentifiers:identifiers];
#endif
}

- (NSString*)terminalAttentionSubtitle
{
#if HAVE_OAK_SWIFTUI
	return _terminalController.attentionSubtitle;
#else
	return nil;
#endif
}

- (void)simulateSessionAttentionAtIndex:(NSInteger)index state:(NSString*)state kind:(NSString*)kind
{
#if HAVE_OAK_SWIFTUI
	[_terminalController simulateSessionAttentionAt:index state:state kind:kind];
#endif
}

- (void)startTerminal
{
#if HAVE_OAK_SWIFTUI
	[self prepareTerminalController];
	[_terminalController startSession];
#endif
}

- (void)takeTerminalSession:(NSUUID*)identifier fromPanel:(TerminalPanelViewController*)source
{
#if HAVE_OAK_SWIFTUI
	[self prepareTerminalController];
	[source.terminalController transferSessionWithIdentifier:identifier to:self.terminalController at:self.terminalController.sessionIdentifiers.count];
#endif
}

- (void)takePlacementFromPanel:(TerminalPanelViewController*)source
{
	self.panelPosition = source.panelPosition;
	self.panelWidth    = source.panelWidth;
	self.panelHeight   = source.panelHeight;
}

- (void)applyTerminalBackground:(NSColor*)background foreground:(NSColor*)foreground caret:(NSColor*)caret selection:(NSColor*)selection syntaxColors:(NSArray<NSColor*>*)syntaxColors
{
#if HAVE_OAK_SWIFTUI
	self.terminalTheme = [[OakTerminalTheme alloc] initWithBackground:background foreground:foreground caret:caret selection:selection syntaxColors:syntaxColors];
	[_terminalController applyTheme:self.terminalTheme];
	[self updateFloatingSurfaceBackground:background];
#endif
}

- (void)applyTerminalFont:(NSFont*)font
{
	self.terminalFont = font;
#if HAVE_OAK_SWIFTUI
	[_terminalController applyFont:font];
#endif
}

- (void)focusTerminal
{
#if HAVE_OAK_SWIFTUI
	if([self usesFloatingPanel])
		[_floatingPanel focus];
	[_terminalController focusTerminal];
#endif
}

- (void)refreshFloatingPanelVisibility
{
	[_floatingPanel refreshWindowOrdering];
}

- (BOOL)terminalHasRunningWork
{
#if HAVE_OAK_SWIFTUI
	return _terminalController.hasRunningWork;
#else
	return NO;
#endif
}

- (void)confirmTerminalCloseInWindow:(NSWindow*)window completionHandler:(void(^)(BOOL canClose))callback
{
#if HAVE_OAK_SWIFTUI
	if(_terminalController)
		return [_terminalController confirmCloseIn:window completion:callback];
#endif
	callback(YES);
}

- (void)stopTerminal
{
#if HAVE_OAK_SWIFTUI
	[_terminalController stopSession];
#endif
}

- (void)setPanelVisible:(BOOL)visible
{
	if(_panelVisible == visible)
		return;
	_panelVisible = visible;
	if([self usesFloatingPanel])
		[self updateFloatingPresentation];
	else
		[self rebuildLayout];
}

- (void)setPanelPosition:(NSString*)position
{
	position = SupportedPanelPosition(position);
	if(!position || [_panelPosition isEqualToString:position])
		return;
	NSWindow* terminalWindow = _panelView.window;
	NSResponder* responder = terminalWindow.firstResponder;
	BOOL restoreFocus = terminalWindow.isKeyWindow && [responder isKindOfClass:NSView.class] && [(NSView*)responder isDescendantOf:_panelView];
	_panelPosition = [position copy];
	if(![self usesFloatingPanel])
	{
		[_floatingPanel dismiss];
#if HAVE_OAK_SWIFTUI
		_terminalTabBarController.floatingDragBar = nil;
		[_terminalController placeTabBarIn:nil];
#endif
		[_panelView removeFromSuperview];
	}
	[self rebuildLayout];
	[self updateFloatingPresentation];
	if(restoreFocus && _panelVisible)
		[self focusTerminal];
}

- (BOOL)usesFloatingPanel
{
	return [_panelPosition isEqualToString:kTerminalPanelPositionFloating];
}

- (BOOL)isPanelTucked
{
	return [self usesFloatingPanel] && _floatingPanel.isTucked;
}

- (void)updateFloatingSurfaceBackground:(NSColor*)background
{
	if(!_floatingSurface)
		return;
	NSColor* gray = [background colorUsingColorSpace:NSColorSpace.genericGrayColorSpace];
	_floatingSurface.appearance = gray ? [NSAppearance appearanceNamed:gray.whiteComponent < 0.5 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua] : nil;
	_floatingSurface.fillColor = background ?: NSColor.textBackgroundColor;
}

- (void)prepareFloatingPanel
{
	_floatingSurface = [NSBox new];
	_floatingSurface.boxType = NSBoxCustom;
	_floatingSurface.titlePosition = NSNoTitle;
	_floatingSurface.borderWidth = 0;
	_floatingSurface.contentViewMargins = NSZeroSize;
	_floatingSurface.cornerRadius = 8;
	_floatingSurface.wantsLayer = YES;
	_floatingSurface.layer.cornerRadius = 8;
	_floatingSurface.layer.masksToBounds = YES;
	_floatingSurface.accessibilityLabel = @"Terminal Panel";
#if HAVE_OAK_SWIFTUI
	[self updateFloatingSurfaceBackground:self.terminalTheme.background];
#else
	[self updateFloatingSurfaceBackground:nil];
#endif

	FloatingPanelPinButton* pin = [[FloatingPanelPinButton alloc] initWithPanelName:@"Terminal"];
	NSButton* hide = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Hide Terminal"]
		target:self action:@selector(hideFloatingPanel:)];
	hide.bordered = NO;
	hide.controlSize = NSControlSizeSmall;
	hide.toolTip = @"Hide Terminal";

	FloatingPanelDragBar* bar = [FloatingPanelDragBar stackViewWithViews:@[ pin, hide ]];
	bar.alignment = NSLayoutAttributeCenterY;
	bar.spacing = 0;
	_floatingDragBar = bar;
	_floatingTabs = [NSView new];
	_floatingBody = [NSView new];
	NSView* container = _floatingSurface.contentView;
	OakAddAutoLayoutViewsToSuperview(@[ _floatingTabs, bar, _floatingBody ], container);
	[NSLayoutConstraint activateConstraints:@[
		[pin.widthAnchor constraintEqualToConstant:26],
		[pin.heightAnchor constraintEqualToConstant:kFloatingHeaderHeight],
		[hide.widthAnchor constraintEqualToConstant:26],
		[hide.heightAnchor constraintEqualToConstant:kFloatingHeaderHeight],
		[bar.topAnchor constraintEqualToAnchor:container.topAnchor constant:kFloatingHeaderInset],
		[bar.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-kFloatingHeaderInset],
		[bar.heightAnchor constraintEqualToConstant:kFloatingHeaderHeight],
		[_floatingTabs.topAnchor constraintEqualToAnchor:bar.topAnchor],
		[_floatingTabs.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
		[_floatingTabs.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:kFloatingHeaderInset],
		[_floatingTabs.trailingAnchor constraintEqualToAnchor:bar.leadingAnchor],
		[_floatingBody.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
		[_floatingBody.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
		[_floatingBody.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
		[_floatingBody.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
	]];

	_floatingPanel = [[FloatingPanel alloc] initWithContentView:_floatingSurface title:@"Terminal"];
	_floatingPanel.opensNearBottom = YES;
	_floatingPanel.keepsOpenWhileKey = YES;
	__weak TerminalPanelViewController* weakSelf = self;
	_floatingPanel.dismissHandler = ^{ [weakSelf hideFloatingPanel:nil]; };
	bar.panel = pin.panel = _floatingPanel;
}

- (void)attachFloatingContent
{
	if(!_floatingBody || _panelView.superview == _floatingBody)
		return;
	_panelView.translatesAutoresizingMaskIntoConstraints = YES;
	_panelView.frame = _floatingBody.bounds;
	_panelView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	[_floatingBody addSubview:_panelView];
#if HAVE_OAK_SWIFTUI
	_terminalTabBarController.floatingDragBar = _floatingDragBar;
	[_terminalController placeTabBarIn:_floatingTabs];
#endif
}

- (void)updateFloatingPresentation
{
	if(![self usesFloatingPanel] || !_panelVisible || !_layoutView.window)
	{
		[_floatingPanel dismiss];
		return;
	}

	if(!_floatingPanel)
		[self prepareFloatingPanel];
	[self attachFloatingContent];
	[_floatingPanel showInWindow:_layoutView.window];
}

- (void)hideFloatingPanel:(id)sender
{
	self.panelVisible = NO;
	if(self.floatingPanelDismissed)
		self.floatingPanelDismissed();
}

- (void)setPanelWidth:(CGFloat)width
{
	_panelWidth = isfinite(width) ? MAX(kMinimumPanelWidth, width) : kDefaultPanelWidth;
	if(_panelVisible && ![_panelPosition isEqualToString:kTerminalPanelPositionBottom])
		_panelSizeConstraint.constant = _panelWidth;
}

- (void)setPanelHeight:(CGFloat)height
{
	_panelHeight = isfinite(height) ? MAX(kMinimumPanelHeight, height) : kDefaultPanelHeight;
	if(_panelVisible && [_panelPosition isEqualToString:kTerminalPanelPositionBottom])
		_panelSizeConstraint.constant = _panelHeight;
}

#ifndef CONSTRAINT
#define CONSTRAINT(str) [_layoutConstraints addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:str options:0 metrics:nil views:views]]
#endif

- (void)rebuildLayout
{
	NSWindow* window = _layoutView.window;
	NSView* panel = _panelVisible && ![self usesFloatingPanel] ? _panelView : nil;
	NSResponder* responder = window.firstResponder;
	BOOL restoreFocus = [responder isKindOfClass:NSView.class] &&
		([(NSView*)responder isDescendantOf:_contentView] ||
		 (panel && [(NSView*)responder isDescendantOf:panel]));

	[NSLayoutConstraint deactivateConstraints:_layoutConstraints];
	[_layoutConstraints removeAllObjects];
	[_contentView removeFromSuperview];
	[_panelView removeFromSuperview];
	[_layoutView.divider removeFromSuperview];

	BOOL bottom = [_panelPosition isEqualToString:kTerminalPanelPositionBottom];
	_layoutView.dividerAlongYAxis = !bottom;
	_layoutView.divider = panel ? OakCreateNSBoxSeparator() : nil;
	OakAddAutoLayoutViewsToSuperview(@[ _contentView ], _layoutView);
	if(panel)
		OakAddAutoLayoutViewsToSuperview(@[ panel, _layoutView.divider ], _layoutView);

	NSDictionary* views = @{
		@"content": _contentView,
		@"panel":   panel ?: NSNull.null,
		@"divider": _layoutView.divider ?: NSNull.null,
	};

	if(!panel)
	{
		CONSTRAINT(@"H:|[content]|");
		CONSTRAINT(@"V:|[content]|");
		_panelSizeConstraint = nil;
	}
	else
	{
		if(bottom)
		{
			CONSTRAINT(@"V:|[content][divider(==1)][panel]|");
			for(NSString* view in @[ @"content", @"divider", @"panel" ])
				CONSTRAINT(([NSString stringWithFormat:@"H:|[%@]|", view]));
		}
		else
		{
			if([_panelPosition isEqualToString:kTerminalPanelPositionLeft])
					CONSTRAINT(@"H:|[panel][divider(==1)][content]|");
			else	CONSTRAINT(@"H:|[content][divider(==1)][panel]|");
			for(NSString* view in @[ @"content", @"divider", @"panel" ])
				CONSTRAINT(([NSString stringWithFormat:@"V:|[%@]|", view]));
		}

		// Below the window's stay-put priority: a smaller window compresses the panel first, and it regains its preferred size when the window grows.
		_panelSizeConstraint = bottom ? [panel.heightAnchor constraintEqualToConstant:_panelHeight] : [panel.widthAnchor constraintEqualToConstant:_panelWidth];
		_panelSizeConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow-1;
		[_layoutConstraints addObject:_panelSizeConstraint];
		NSLayoutConstraint* contentMinimum = bottom ? [_contentView.heightAnchor constraintGreaterThanOrEqualToConstant:kMinimumContentHeight] : [_contentView.widthAnchor constraintGreaterThanOrEqualToConstant:kMinimumContentWidth];
		contentMinimum.priority = NSLayoutPriorityDragThatCannotResizeWindow;
		[_layoutConstraints addObject:contentMinimum];
	}

	[NSLayoutConstraint activateConstraints:_layoutConstraints];
	[window invalidateCursorRectsForView:_layoutView];
	if(restoreFocus)
		[window makeFirstResponder:responder];
}

#undef CONSTRAINT

- (void)dragDivider:(TerminalDividerDrag)phase offset:(NSSize)offset
{
	NSView* panel = _panelVisible ? _panelView : nil;
	if(!panel)
		return;

	BOOL bottom = [_panelPosition isEqualToString:kTerminalPanelPositionBottom];
	if(phase == TerminalDividerDragBegan)
	{
		_dragInitialSize = bottom ? NSHeight(panel.frame) : NSWidth(panel.frame);
	}
	else if(phase == TerminalDividerDragMoved)
	{
		CGFloat delta = bottom ? offset.height : ([_panelPosition isEqualToString:kTerminalPanelPositionLeft] ? offset.width : -offset.width);
		CGFloat available = MAX(0, (bottom ? NSHeight(_layoutView.bounds) : NSWidth(_layoutView.bounds)) - 1);
		NSSize fitting = _contentView.fittingSize;
		CGFloat maximum = MAX(0, available - (bottom ? MAX(kMinimumContentHeight, fitting.height) : MAX(kMinimumContentWidth, fitting.width)));
		CGFloat minimum = MIN(bottom ? kMinimumPanelHeight : kMinimumPanelWidth, maximum);
		CGFloat size = round(MAX(minimum, MIN(_dragInitialSize + delta, maximum)));
		if(bottom)
				_panelHeight = size;
		else	_panelWidth = size;
		_panelSizeConstraint.constant = size;
	}
	else if(phase == TerminalDividerDragEnded)
	{
		// Persist once per drag rather than for every pixel moved.
		NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
		[defaults setDouble:_panelWidth forKey:kUserDefaultsTerminalPanelWidthKey];
		[defaults setDouble:_panelHeight forKey:kUserDefaultsTerminalPanelHeightKey];
	}
}
@end
