#import "OakTabBarView.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <OakAppKit/NSImage Additions.h>
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <OakAppKit/OakAppKit.h>
#import <OakAppKit/NSMenuItem Additions.h>
#import <OakFoundation/OakFoundation.h>
#import <TMFileReference/TMFileReference.h>
#import <oak/misc.h>
#import <Preferences/Keys.h>

static void DisableImplicitAnimationForBlock (void(^handler)())
{
	[NSAnimationContext runAnimationGroup:^(NSAnimationContext* context){
		context.allowsImplicitAnimation = NO;
		handler();
	} completionHandler:^{
	}];
}

// ==============
// = OakTabItem =
// ==============

static NSString* const OakTabItemPasteboardType = @"com.macromates.TextMate.tabItem";
static CGFloat const kTitleBarDragEdgeHeight = 12;
static CGFloat const kTabDragDistance = 10;
static CGFloat const kTabDragRailDistance = 40;

static CGFloat LinearColorComponent(CGFloat component)
{
	return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4);
}

@class OakTabView;

@interface OakTabItem : NSObject <NSPasteboardWriting>
@property (nonatomic, readonly) NSString* identifier;
@property (nonatomic) NSString* title;
@property (nonatomic) NSString* path;
@property (nonatomic) NSString* toolTip; // empty or nil keeps the path tooltip
@property (nonatomic) NSDictionary* statusInfo;
@property (nonatomic, getter = isModified) BOOL modified;
@property (nonatomic, getter = isSelected) BOOL selected;
@property (nonatomic) CGFloat fittingWidth;
@property (nonatomic) BOOL needsLayout;
@property (nonatomic, weak) OakTabView* tabView;
@end

@implementation OakTabItem
+ (instancetype)tabItemWithTitle:(NSString*)aTitle path:(NSString*)aPath identifier:(NSString*)anIdentifier modified:(BOOL)flag
{
	return [[OakTabItem alloc] initWithTitle:aTitle path:aPath identifier:anIdentifier modified:flag];
}

+ (instancetype)tabItemFromPasteboardItem:(NSPasteboardItem*)pasteboardItem
{
	NSDictionary* plist = [pasteboardItem propertyListForType:OakTabItemPasteboardType];
	return plist ? [[OakTabItem alloc] initWithTitle:plist[@"title"] path:plist[@"path"] identifier:plist[@"identifier"] modified:[plist[@"modified"] boolValue]] : nil;
}

- (instancetype)initWithTitle:(NSString*)title path:(NSString*)path identifier:(NSString*)identifier modified:(BOOL)modified
{
	if(self = [super init])
	{
		_title       = title;
		_path        = path;
		_identifier  = identifier;
		_modified    = modified;
		_needsLayout = YES;
	}
	return self;
}

- (NSString*)description
{
	return [NSString stringWithFormat:@"<%@: %@>", [self class], _title];
}

- (void)setTitle:(NSString*)newTitle
{
	if(_title == newTitle || [_title isEqualToString:newTitle])
		return;
	_title = newTitle;
	self.needsLayout = YES;
}

- (NSArray*)writableTypesForPasteboard:(NSPasteboard*)aPasteboard
{
	// Only the private tab type. Advertising a file URL lets Finder/Desktop
	// accept the drag (operation != None), which suppresses tear-off.
	return @[ OakTabItemPasteboardType ];
}

- (NSPasteboardWritingOptions)writingOptionsForType:(NSString*)aType pasteboard:(NSPasteboard*)aPasteboard
{
	return 0;
}

- (id)pasteboardPropertyListForType:(NSString*)aType
{
	if([aType isEqualToString:UTTypeFileURL.identifier])
		return [NSURL fileURLWithPath:_path].absoluteString;

	NSMutableDictionary* dict = [NSMutableDictionary dictionary];
	dict[@"identifier"] = _identifier;
	dict[@"title"]      = _title;
	dict[@"path"]       = OakNotEmptyString(_path) ? _path : nil;
	dict[@"modified"]   = _modified ? @YES : nil;
	return dict;
}
@end

// ====================
// = OakAnimatorProxy =
// ====================

@interface OakAnimatorProxy : NSProxy
@property (nonatomic) id realObject;
@end

@implementation OakAnimatorProxy
- (instancetype)initWithRealObject:(id)realObject
{
	_realObject = realObject;
	return self;
}

- (void)forwardInvocation:(NSInvocation*)anInvocation
{
	[NSAnimationContext runAnimationGroup:^(NSAnimationContext* context){
		context.allowsImplicitAnimation = YES;
		[anInvocation setTarget:_realObject];
		[anInvocation invoke];
	} completionHandler:^{
	}];
}

- (NSMethodSignature*)methodSignatureForSelector:(SEL)aSelector
{
	return [_realObject methodSignatureForSelector:aSelector];
}
@end

// ==================== //
// = Status Text Link = //
// ==================== //

// The title and status text leave mouse events to the bar behind them.
@interface OakTabBarLabel : NSTextField
@end

@implementation OakTabBarLabel
- (NSView*)hitTest:(NSPoint)aPoint
{
	return nil;
}
@end

@interface OakAddTabButton : NSButton
@property (nonatomic, weak) OakTabBarView* tabBar;
@end

@interface NSWindow (OakTitleBarFill)
- (void)_zoomFill:(NSView*)sender;
@end

// ==============
// = OakTabView =
// ==============

@class OakTabBarView;
@class OakTabFrame;

@interface OakTabView : NSView <NSAccessibilityRadioButton>
@property (nonatomic, weak) OakTabBarView* tabBarView;
@property (nonatomic) OakTabItem* tabItem;

@property (nonatomic, weak) id target;
@property (nonatomic) SEL action;
@property (nonatomic) SEL doubleAction;
@property (nonatomic) SEL dragAction;

@property (nonatomic, getter = isSelected) BOOL selected;
@property (nonatomic, getter = isModified) BOOL modified;
@property (nonatomic, getter = isOverflowButtonVisible) BOOL overflowButtonVisible;

@property (nonatomic, getter = isMouseInside) BOOL mouseInside;
@property (nonatomic, getter = isVoiceOverEnabled) BOOL voiceOverEnabled;

@property (nonatomic, readonly) BOOL shouldShowCloseButton;
@property (nonatomic) NSArray<NSLayoutConstraint*>* overflowButtonConstraints;

@property (nonatomic) OakRolloverButton* closeButton;
@property (nonatomic) OakRolloverButton* overflowButton;
@property (nonatomic) NSTextField* textField;
@property (nonatomic) NSView* statusView;
@property (nonatomic) NSImageView* statusImage;
@property (nonatomic) NSProgressIndicator* statusSpinner;
@property (nonatomic) NSLayoutConstraint* statusWidth;
- (void)updateStatus;
- (void)updateLabelAppearance;
- (CGFloat)preferredTitleBarWidth;

@property (nonatomic) NSTrackingArea* trackingArea;
@property (nonatomic) NSEvent* mouseDownEvent;
@property (nonatomic) NSString* previousSelection;
@end

@interface OakTabBarView () <NSAccessibilityGroup, NSDraggingSource>
{
	NSInteger _minimumTabSize;
	NSInteger _maximumTabSize;

	NSInteger _tag;
}
@property (nonatomic) NSMutableArray<OakTabItem*>* tabItems;
@property (nonatomic) NSInteger draggedTabIndex;
@property (nonatomic) NSInteger dropTabAtIndex;
@property (nonatomic) NSInteger freezeTabFramesLeftOfIndex;
@property (nonatomic) NSButton* createNewTabButton;
@property (nonatomic) NSTextField* statusTextLabel;
@property (nonatomic) NSTextField* collapsedTitleLabel;
@property (nonatomic) NSTrackingArea* trackingArea;
@property (nonatomic, getter = isDragging) BOOL dragging;
@property (nonatomic) NSPoint tabDragStart;
@property (nonatomic) NSPoint tabDragWindowOffset;
@property (nonatomic) BOOL tabDragLeftRail;
@property (nonatomic) NSDictionary<NSString*, NSNumber*>* tabDragMidpoints;
@property (nonatomic) NSString* selectionBeforeTabDrag;
@property (nonatomic, weak) OakTabBarView* tabDragDestination;
@property (nonatomic) NSPanel* tabDragPreview;
- (NSColor*)titleBarInkColor;
- (NSColor*)titleBarSurfaceColor;
- (NSString*)selectedTabIdentifier;
- (void)selectTabWithIdentifier:(NSString*)identifier;
- (void)didSingleClickTabView:(OakTabView*)tabView;
- (BOOL)canDragWindow;
- (BOOL)shouldDragWindowFromTabWithEvent:(NSEvent*)event;
- (void)dragWindowWithEvent:(NSEvent*)event;
- (void)performTitlebarDoubleClick:(id)sender;
- (void)didClickCloseButtonForTabView:(OakTabView*)tabView;
- (void)didClickOverflorButtonForTabView:(OakTabView*)tabView;
- (NSMenu*)menuForTabView:(OakTabView*)tabView withEvent:(NSEvent*)anEvent;

@property (nonatomic) NSArray<OakTabFrame*>* fromLayout;
@property (nonatomic) NSArray<OakTabFrame*>* toLayout;
@property (nonatomic) NSArray<OakTabFrame*>* currentLayout;
@property (nonatomic) CGFloat tabLayoutAnimationProgressOffset;
@property (nonatomic) CGFloat tabLayoutAnimationProgress;
@end

static void* kOakTabViewVoiceOverContext = &kOakTabViewVoiceOverContext;
static void* kOakTabViewStatusContext = &kOakTabViewStatusContext;
static void* kOakTabViewTitleContext     = &kOakTabViewTitleContext;
static void* kOakTabViewPathContext      = &kOakTabViewPathContext;
static void* kOakTabViewToolTipContext   = &kOakTabViewToolTipContext;
static void* kOakTabViewModifiedContext  = &kOakTabViewModifiedContext;
static void* kOakTabViewSelectedContext  = &kOakTabViewSelectedContext;

@implementation OakTabView
+ (NSSet*)keyPathsForValuesAffectingCloseButtonAlphaValue
{
	return [NSSet setWithObjects:@"tabItem", @"mouseInside", @"modified", @"voiceOverEnabled", nil];
}

- (instancetype)animator
{
	return (OakTabView*)[[OakAnimatorProxy alloc] initWithRealObject:super.animator];
}

- (instancetype)initWithFrame:(NSRect)frameRect tabItem:(OakTabItem*)tabItem parent:(OakTabBarView*)tabBarView
{
	if(self = [super initWithFrame:frameRect])
	{
		self.accessibilityRole            = NSAccessibilityRadioButtonRole;
		self.accessibilityRoleDescription = @"Tab";

		_tabBarView = tabBarView;

		_textField = OakCreateLabel();
		if(tabBarView.isWindowTitleBar)
		{
			_textField.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
			_textField.lineBreakMode = NSLineBreakByTruncatingMiddle;
			_textField.allowsDefaultTighteningForTruncation = NO;
			_textField.alignment = NSTextAlignmentCenter;
		}
        _statusView = [[NSView alloc] initWithFrame:NSZeroRect];
        _statusImage = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 14, 14)];
        _statusSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 14, 14)];
        _statusSpinner.style = NSProgressIndicatorStyleSpinning;
        _statusSpinner.controlSize = NSControlSizeSmall;
        _statusSpinner.displayedWhenStopped = NO;
        [_statusView addSubview:_statusImage];
        _statusWidth = [_statusView.widthAnchor constraintEqualToConstant:0];
        _statusWidth.active = YES;

		NSArray<NSView*>* subviews = @[ _textField, _statusView, _statusSpinner, self.closeButton, self.overflowButton ];
		for(NSView* view in subviews)
		{
			view.translatesAutoresizingMaskIntoConstraints = NO;
			[self addSubview:view positioned:NSWindowAbove relativeTo:nil];
		}

		self.overflowButton.hidden = YES;

		[NSWorkspace.sharedWorkspace addObserver:self forKeyPath:@"voiceOverEnabled" options:NSKeyValueObservingOptionInitial context:kOakTabViewVoiceOverContext];

		NSDictionary* views = @{
			@"close":      self.closeButton,
			@"title":      self.textField,
            @"status":     self.statusView,
			@"overflow":   self.overflowButton,
		};

		// iTerm2 Minimal layout: title centered with breathing room, close
		// button tucked at the trailing edge (revealed on hover / when modified).
		NSString* horizontalLayout = tabBarView.isWindowTitleBar
			? @"H:|-(8@53)-[status]-(>=0@53)-[title]-(>=4@53)-[close]-(4@53)-|"
			: @"H:|-(8@53)-[status][title]-(>=4@53)-[close]-(4@53)-|";
		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:horizontalLayout options:0 metrics:nil views:views]];

		_overflowButtonConstraints = [NSLayoutConstraint constraintsWithVisualFormat:@"H:[title]-(>=3@53)-[overflow]" options:0 metrics:nil views:views];
		[NSLayoutConstraint deactivateConstraints:_overflowButtonConstraints];
		[self addConstraints:_overflowButtonConstraints];

		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:[overflow]|" options:0 metrics:nil views:views]];
		// Center the title and close button vertically so a taller tab bar stays balanced.
		[NSLayoutConstraint activateConstraints:@[
			[self.closeButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
			[self.textField.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
		]];
		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[overflow]|" options:0 metrics:nil views:views]];

		[_textField setContentHuggingPriority:tabBarView.isWindowTitleBar ? NSLayoutPriorityFittingSizeCompression - 1 : NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
		[_textField setContentCompressionResistancePriority:NSLayoutPriorityFittingSizeCompression+2 forOrientation:NSLayoutConstraintOrientationHorizontal];

		NSLayoutConstraint* centerTitleConstraint = [NSLayoutConstraint constraintWithItem:_textField attribute:NSLayoutAttributeCenterX relatedBy:NSLayoutRelationEqual toItem:self attribute:NSLayoutAttributeCenterX multiplier:1 constant:0];
		centerTitleConstraint.priority = NSLayoutPriorityFittingSizeCompression+1;
		[self addConstraint:centerTitleConstraint];
		if(tabBarView.isWindowTitleBar)
		{
			// Use the available width rather than the text field's intrinsic size;
			// the latter can truncate even short filenames by a fraction of a point.
			NSLayoutConstraint* fillTitle = [_textField.widthAnchor constraintEqualToAnchor:self.widthAnchor];
			fillTitle.priority = NSLayoutPriorityFittingSizeCompression;
			fillTitle.active = YES;
		}

		[NSLayoutConstraint activateConstraints:@[
            [_statusSpinner.widthAnchor constraintEqualToConstant:14],
            [_statusSpinner.heightAnchor constraintEqualToConstant:14],
            [_statusSpinner.centerXAnchor constraintEqualToAnchor:self.closeButton.centerXAnchor],
            [_statusSpinner.centerYAnchor constraintEqualToAnchor:self.closeButton.centerYAnchor],
            [_statusView.heightAnchor constraintEqualToConstant:14],
            [_statusView.centerYAnchor constraintEqualToAnchor:_textField.centerYAnchor]
        ]];
        self.tabItem = tabItem;
	}
	return self;
}

- (void)dealloc
{
	self.tabItem = nil;
	[NSWorkspace.sharedWorkspace removeObserver:self forKeyPath:@"voiceOverEnabled" context:kOakTabViewVoiceOverContext];
}

- (void)setHidden:(BOOL)flag
{
	if(self.isHidden == flag)
		return;
	[super setHidden:flag];

	if(!flag)
	{
		DisableImplicitAnimationForBlock(^{
			self.mouseInside = NSMouseInRect([self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil], self.visibleRect, self.isFlipped);
		});
	}
}

- (void)setMouseInside:(BOOL)flag
{
	if(_mouseInside == flag)
		return;

	_mouseInside = flag;
	if(self.tabBarView.isWindowTitleBar)
		self.tabBarView.needsDisplay = YES;
}

- (void)setModified:(BOOL)flag
{
	_modified = flag;
	[self updateCloseButtonImage];
}

- (void)setSelected:(BOOL)flag
{
	if(_selected == flag)
		return;

	_selected = flag;

	if(self.tabBarView.isWindowTitleBar)
	{
		[self updateLabelAppearance];
		self.tabBarView.needsDisplay = YES;
	}
	else
		self.textField.alphaValue = _selected ? 1 : 0.5;
}

- (void)setTabItem:(OakTabItem*)tabItem
{
	[_tabItem removeObserver:self forKeyPath:@"statusInfo" context:kOakTabViewStatusContext];
	[_tabItem removeObserver:self forKeyPath:@"title"    context:kOakTabViewTitleContext];
	[_tabItem removeObserver:self forKeyPath:@"path"     context:kOakTabViewPathContext];
	[_tabItem removeObserver:self forKeyPath:@"toolTip"  context:kOakTabViewToolTipContext];
	[_tabItem removeObserver:self forKeyPath:@"modified" context:kOakTabViewModifiedContext];
	[_tabItem removeObserver:self forKeyPath:@"selected" context:kOakTabViewSelectedContext];

	_tabItem = tabItem;

	[_tabItem addObserver:self forKeyPath:@"statusInfo" options:NSKeyValueObservingOptionInitial context:kOakTabViewStatusContext];
	[_tabItem addObserver:self forKeyPath:@"title"    options:NSKeyValueObservingOptionInitial context:kOakTabViewTitleContext];
	[_tabItem addObserver:self forKeyPath:@"path"     options:NSKeyValueObservingOptionInitial context:kOakTabViewPathContext];
	[_tabItem addObserver:self forKeyPath:@"toolTip"  options:NSKeyValueObservingOptionInitial context:kOakTabViewToolTipContext];
	[_tabItem addObserver:self forKeyPath:@"modified" options:NSKeyValueObservingOptionInitial context:kOakTabViewModifiedContext];
	[_tabItem addObserver:self forKeyPath:@"selected" options:NSKeyValueObservingOptionInitial context:kOakTabViewSelectedContext];

	if(_tabItem)
	{
		if(self.tabBarView.isWindowTitleBar)
			[self updateLabelAppearance];
		else
			self.textField.alphaValue = _selected ? 1 : 0.5;
		self.accessibilityElement                     = YES;
		self.closeButton.cell.accessibilityElement    = YES;
		self.overflowButton.cell.accessibilityElement = YES;
	}
	else
	{
		self.accessibilityElement                     = NO;
		self.closeButton.cell.accessibilityElement    = NO;
		self.overflowButton.cell.accessibilityElement = NO;

		self.textField.alphaValue      = 0.0;
		self.overflowButtonVisible     = NO;
        [self updateStatus];
	}
}

// A data source that describes the tab's state (a terminal's attention dot, for instance) wins over the
// path, which remains the tooltip for the data sources that have a better answer in their path.
- (void)updateToolTip
{
	NSString* toolTip = self.tabItem.toolTip;
	NSString* status = self.tabItem.statusInfo[@"description"];
	self.toolTip = OakNotEmptyString(toolTip) ? toolTip : status.length ? status : self.tabItem.path.stringByAbbreviatingWithTildeInPath;
}

- (void)updateCloseButtonImage
{
	if(_modified)
	{
		_closeButton.regularImage  = [NSImage imageNamed:@"TabCloseThin_Modified_Template"         inSameBundleAsClass:self];
		_closeButton.pressedImage  = [NSImage imageNamed:@"TabCloseThin_ModifiedPressed_Template"  inSameBundleAsClass:self];
		_closeButton.rolloverImage = [NSImage imageNamed:@"TabCloseThin_ModifiedRollover_Template" inSameBundleAsClass:self];
	}
	else
	{
		_closeButton.regularImage  = [NSImage imageNamed:@"TabCloseThinTemplate"           inSameBundleAsClass:self];
		_closeButton.pressedImage  = [NSImage imageNamed:@"TabCloseThin_Pressed_Template"  inSameBundleAsClass:self];
		_closeButton.rolloverImage = [NSImage imageNamed:@"TabCloseThin_Rollover_Template" inSameBundleAsClass:self];
	}
}

- (OakRolloverButton*)closeButton
{
	if(!_closeButton)
	{
		_closeButton = [[OakRolloverButton alloc] initWithFrame:NSZeroRect];

		_closeButton.accessibilityLabel                 = @"Close tab";
		_closeButton.action                             = @selector(didClickCloseButton:);
		_closeButton.target                             = self;
		_closeButton.disableWindowOrderingForFirstMouse = YES;

		[self updateCloseButtonImage];
	}
	return _closeButton;
}

- (OakRolloverButton*)overflowButton
{
	if(!_overflowButton)
	{
		_overflowButton = [[OakRolloverButton alloc] initWithFrame:NSZeroRect];
		[_overflowButton sendActionOn:NSEventMaskLeftMouseDown];

		_overflowButton.accessibilityLabel = @"Show tab overflow menu";
		_overflowButton.action             = @selector(didClickOverflorButton:);
		_overflowButton.target             = self;
		_overflowButton.regularImage       = [NSImage imageNamed:@"TabOverflowThinTemplate" inSameBundleAsClass:self];
	}
	return _overflowButton;
}

- (CGFloat)closeButtonAlphaValue
{
	return _tabItem && (_mouseInside || _modified || _voiceOverEnabled) ? 1 : 0;
}

- (void)setOverflowButtonVisible:(BOOL)flag
{
	_overflowButtonVisible = flag;
	self.overflowButton.hidden = !flag;
	if(flag)
			[NSLayoutConstraint activateConstraints:_overflowButtonConstraints];
	else	[NSLayoutConstraint deactivateConstraints:_overflowButtonConstraints];
}

- (NSString*)accessibilityLabel
{
    NSString* title = self.tabItem.isModified ? [self.tabItem.title stringByAppendingString:@" (modified)"] : self.tabItem.title;
    NSString* status = self.tabItem.statusInfo[@"description"];
    return status.length ? [NSString stringWithFormat:@"%@, %@", title, status] : title;
}

- (void)updateStatus
{
    OakTabStatus status = (OakTabStatus)[self.tabItem.statusInfo[@"value"] integerValue];
    BOOL showsStatusImage = status != OakTabStatusNone && status != OakTabStatusWorking;
    self.statusWidth.constant = showsStatusImage ? 18 : 0;
    self.statusView.hidden = !showsStatusImage;
    self.statusImage.hidden = status == OakTabStatusWorking;
    if(status == OakTabStatusWorking) [self.statusSpinner startAnimation:nil];
    else [self.statusSpinner stopAnimation:nil];
    NSString* symbol = status == OakTabStatusBlocked ? @"exclamationmark.bubble.fill" : status == OakTabStatusDone ? @"checkmark.circle.fill" : @"exclamationmark.circle.fill";
    self.statusImage.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    self.statusImage.contentTintColor = status == OakTabStatusBlocked ? NSColor.systemOrangeColor : status == OakTabStatusError ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    [self updateToolTip];
    self.tabItem.needsLayout = YES;
}
- (NSNumber*)accessibilityValue { return @(self.isSelected); }

- (BOOL)accessibilityPerformPress
{
	return [NSApp sendAction:self.action to:self.target from:self];
}

- (BOOL)accessibilityPerformShowMenu
{
	[[self menuForEvent:NSApp.currentEvent] popUpMenuPositioningItem:nil atLocation:NSZeroPoint inView:self];
	return YES;
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)someObject change:(NSDictionary*)changes context:(void*)context
{
	if(context == kOakTabViewStatusContext)
        [self updateStatus];
	else if(context == kOakTabViewVoiceOverContext)
	{
		self.voiceOverEnabled = NSWorkspace.sharedWorkspace.isVoiceOverEnabled;
	}
	else if(context == kOakTabViewTitleContext)
		self.textField.stringValue = self.tabItem.title;
	else if(context == kOakTabViewPathContext)
		[self updateToolTip];
	else if(context == kOakTabViewToolTipContext)
		[self updateToolTip];
	else if(context == kOakTabViewModifiedContext)
		self.modified = self.tabItem.isModified;
	else if(context == kOakTabViewSelectedContext)
		self.selected = self.tabItem.isSelected;
}

- (void)viewWillMoveToWindow:(NSWindow*)newWindow
{
	if(self.window)
	{
		// Break retain-cycle when view is removed from window
		[self.closeButton unbind:@"alphaValue"];
		[self.statusSpinner unbind:@"alphaValue"];

		[NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidBecomeMainNotification object:self.window];
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidResignMainNotification object:self.window];
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidBecomeKeyNotification object:self.window];
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidResignKeyNotification object:self.window];
	}

	if(newWindow)
	{
		[self.closeButton bind:@"alphaValue" toObject:self withKeyPath:@"closeButtonAlphaValue" options:nil];
		[self.statusSpinner bind:@"alphaValue" toObject:self withKeyPath:@"closeButtonAlphaValue" options:@{ NSValueTransformerNameBindingOption: NSNegateBooleanTransformerName }];

		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowDidChangeMainOrKey:) name:NSWindowDidBecomeMainNotification object:newWindow];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowDidChangeMainOrKey:) name:NSWindowDidResignMainNotification object:newWindow];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowDidChangeMainOrKey:) name:NSWindowDidBecomeKeyNotification object:newWindow];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowDidChangeMainOrKey:) name:NSWindowDidResignKeyNotification object:newWindow];
	}
}

- (void)windowDidChangeMainOrKey:(NSNotification*)aNotification
{
	[self updateLabelAppearance];
}

- (void)updateLabelAppearance
{
	BOOL isActive = self.window.isKeyWindow || self.window.isMainWindow || self.isInFullScreenMode;
	if(self.tabBarView.isWindowTitleBar)
	{
		NSColor* ink = [self.tabBarView titleBarInkColor];
		CGFloat opacity = _selected ? (isActive ? 1.0 : 0.84) : (isActive ? 0.74 : 0.62);
		_textField.textColor = [ink colorWithAlphaComponent:opacity];
		_textField.alphaValue = 1;
		_closeButton.contentTintColor = ink;
		_overflowButton.contentTintColor = ink;
	}
	else
	{
		_textField.textColor = isActive ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor;
	}
}

- (CGFloat)preferredTitleBarWidth
{
	// Reserve room on both sides so the label stays centered next to the close button.
	return ceil([_textField.stringValue sizeWithAttributes:@{ NSFontAttributeName: _textField.font }].width) + 2 * MAX(24, 8 + _statusWidth.constant);
}

- (NSView*)hitTest:(NSPoint)aPoint
{
	NSView* res = [super hitTest:aPoint];
	return [res isKindOfClass:NSButton.class] || !res ? res : self;
}

- (BOOL)mouseDownCanMoveWindow
{
	// YES would let the window server steal tab reorder/tear-off drags as native
	// window moves before -mouseDragged: can start a drag session. Blank-area
	// window moves go through -mouseDown: → performWindowDragWithEvent: instead.
	return NO;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)anEvent
{
	return YES;
}

- (BOOL)shouldDelayWindowOrderingForEvent:(NSEvent*)anEvent
{
	return !self.tabBarView.isWindowTitleBar;
}

- (void)mouseEntered:(NSEvent*)anEvent
{
	self.animator.mouseInside = YES;
}

- (void)mouseExited:(NSEvent*)anEvent
{
	self.animator.mouseInside = NO;
}

- (void)mouseDown:(NSEvent*)anEvent
{
	self.mouseDownEvent = anEvent;
	self.previousSelection = nil;
	if(self.tabBarView.isWindowTitleBar && !self.isSelected && anEvent.clickCount == 1 && !(anEvent.modifierFlags & NSEventModifierFlagOption))
	{
		self.previousSelection = [self.tabBarView selectedTabIdentifier];
		[self.tabBarView didSingleClickTabView:self];
	}
}

- (void)otherMouseDown:(NSEvent*)anEvent
{
	[self.tabBarView didClickCloseButtonForTabView:self];
}

- (void)mouseDragged:(NSEvent*)anEvent
{
	NSEvent* downEvent = self.mouseDownEvent;
	if(!downEvent)
		return;
	if([self.tabBarView shouldDragWindowFromTabWithEvent:anEvent])
	{
		self.mouseDownEvent = nil;
		[self.tabBarView selectTabWithIdentifier:self.previousSelection];
		self.previousSelection = nil;
		[self.tabBarView dragWindowWithEvent:anEvent];
		return;
	}
	NSPoint start = downEvent.locationInWindow, end = anEvent.locationInWindow;
	if(self.dragAction && hypot(start.x - end.x, start.y - end.y) >= kTabDragDistance)
	{
		[NSApp sendAction:self.dragAction to:self.target from:self];
		self.mouseDownEvent = nil;
		self.previousSelection = nil;
	}
}

- (void)mouseUp:(NSEvent*)anEvent
{
	NSEvent* downEvent = self.mouseDownEvent;
	self.mouseDownEvent = nil;
	self.previousSelection = nil;
	if(!downEvent)
		return;
	NSPoint start = downEvent.locationInWindow, end = anEvent.locationInWindow;
	if(hypot(start.x - end.x, start.y - end.y) >= kTabDragDistance)
		return;
	if(!self.isSelected && (anEvent.clickCount == 1 || self.tabBarView.isWindowTitleBar))
		[NSApp sendAction:self.action to:self.target from:self];
	if(anEvent.clickCount == 2 && self.doubleAction)
		[NSApp sendAction:self.doubleAction to:self.target from:self];
}

- (void)didClickCloseButton:(id)sender
{
	[self.tabBarView didClickCloseButtonForTabView:self];
}

- (void)didClickOverflorButton:(id)sender
{
	[self.tabBarView didClickOverflorButtonForTabView:self];
}

- (NSMenu*)menuForEvent:(NSEvent*)anEvent
{
	return [self.tabBarView menuForTabView:self withEvent:anEvent];
}

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if(_trackingArea)
		[self removeTrackingArea:_trackingArea];

	NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways;
	if(!self.tabBarView.isDragging)
	{
		BOOL isInside = NSMouseInRect([self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil], self.visibleRect, self.isFlipped);
		if(isInside)
			options |= NSTrackingAssumeInside;
		if(self.mouseInside != isInside)
			self.animator.mouseInside = isInside;
	}

	_trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:options owner:self userInfo:nil];
	[self addTrackingArea:_trackingArea];
}

- (NSImage*)dragImage
{
	NSRect bounds = self.bounds;
	if(NSIsEmptyRect(bounds))
		return nil;

	NSImage* image = [[NSImage alloc] initWithSize:bounds.size];
	[image lockFocusFlipped:self.isFlipped];

	_overflowButton.hidden = YES;
	_textField.alphaValue  = 1.0;
	_textField.textColor   = self.tabBarView.isWindowTitleBar ? [self.tabBarView titleBarInkColor] : NSColor.labelColor;
	if(self.tabBarView.isWindowTitleBar)
	{
		[[self.tabBarView titleBarSurfaceColor] setFill];
		NSRectFill(bounds);
	}

	[self displayRectIgnoringOpacity:bounds inContext:NSGraphicsContext.currentContext];

	_overflowButton.hidden = !_overflowButtonVisible;
	[self updateLabelAppearance];
	if(!self.tabBarView.isWindowTitleBar)
		_textField.alphaValue = _selected ? 1 : 0.5;

	[image unlockFocus];
	return image;
}
@end

@implementation OakAddTabButton
- (BOOL)acceptsFirstMouse:(NSEvent*)event
{
	return self.tabBar.isWindowTitleBar || [super acceptsFirstMouse:event];
}

- (void)mouseDown:(NSEvent*)event
{
	if(!self.isEnabled || ![self.tabBar canDragWindow])
	{
		[super mouseDown:event];
		return;
	}

	[self highlight:YES];
	NSEventMask mask = NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp;
	while(NSEvent* nextEvent = [self.window nextEventMatchingMask:mask])
	{
		NSPoint point = [self convertPoint:nextEvent.locationInWindow fromView:nil];
		BOOL inside = NSMouseInRect(point, self.bounds, self.isFlipped);
		if(nextEvent.type == NSEventTypeLeftMouseUp)
		{
			[self highlight:NO];
			if(inside)
				[self sendAction:self.action to:self.target];
			return;
		}
		NSPoint start = event.locationInWindow, end = nextEvent.locationInWindow;
		if(hypot(start.x - end.x, start.y - end.y) >= kTabDragDistance)
		{
			[self highlight:NO];
			[self.tabBar dragWindowWithEvent:nextEvent];
			return;
		}
		[self highlight:inside];
	}
	[self highlight:NO];
}
@end

// ===============
// = OakTabFrame =
// ===============

@interface OakTabFrame : NSObject
@property (nonatomic) OakTabItem* tabItem;
@property (nonatomic) CGFloat width;
@end

@implementation OakTabFrame
- (instancetype)initWithTabItem:(OakTabItem*)tabItem width:(CGFloat)width
{
	if(self = [super init])
	{
		_tabItem = tabItem;
		_width   = width;
	}
	return self;
}

- (BOOL)isEqual:(id)lhs
{
	OakTabFrame* otherFrame = [lhs isKindOfClass:[self class]] ? lhs : nil;
	return otherFrame && _width == otherFrame.width && [_tabItem.identifier isEqual:otherFrame.tabItem.identifier];
}
@end

// =================
// = OakTabBarView =
// =================

@implementation OakTabBarView
+ (id)defaultAnimationForKey:(NSString*)key
{
	if([key isEqualToString:@"tabLayoutAnimationProgress"])
		return [CABasicAnimation animation];
	return [super defaultAnimationForKey:key];
}

- (instancetype)animator
{
	return (OakTabBarView*)[[OakAnimatorProxy alloc] initWithRealObject:super.animator];
}

- (instancetype)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		self.accessibilityRole  = NSAccessibilityTabGroupRole;
		self.accessibilityLabel = @"Open files";

		_minimumTabSize = [NSUserDefaults.standardUserDefaults integerForKey:kUserDefaultsTabItemMinWidthKey];
		_maximumTabSize = [NSUserDefaults.standardUserDefaults integerForKey:kUserDefaultsTabItemMaxWidthKey];

		_draggedTabIndex = -1;
		_dropTabAtIndex  = -1;

		[self addSubview:self.createNewTabButton positioned:NSWindowAbove relativeTo:nil];
		[self addSubview:self.statusTextLabel positioned:NSWindowAbove relativeTo:self.createNewTabButton];

		[self registerForDraggedTypes:@[ OakTabItemPasteboardType ]];
	}
	return self;
}

- (NSSize)intrinsicContentSize
{
	return NSMakeSize(NSViewNoIntrinsicMetric, self.isWindowTitleBar ? 30 : 24);
}

- (NSColor*)titleBarSurfaceColor
{
	return self.titleBarBackgroundColor ?: NSColor.windowBackgroundColor;
}

- (NSColor*)titleBarInkColor
{
	__block NSColor* rgb;
	[self.effectiveAppearance performAsCurrentDrawingAppearance:^{
		rgb = [[self titleBarSurfaceColor] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	}];
	if(!rgb)
		return NSColor.labelColor;
	CGFloat luminance = 0.2126 * LinearColorComponent(rgb.redComponent) + 0.7152 * LinearColorComponent(rgb.greenComponent) + 0.0722 * LinearColorComponent(rgb.blueComponent);
	return luminance > 0.179 ? NSColor.blackColor : NSColor.whiteColor;
}

- (void)updateTitleBarAppearance
{
	if(!self.isWindowTitleBar)
		return;
	NSColor* ink = [self titleBarInkColor];
	_createNewTabButton.contentTintColor = ink;
	_collapsedTitleLabel.textColor = [ink colorWithAlphaComponent:0.88];
	for(OakTabFrame* frame in _currentLayout)
		[frame.tabItem.tabView updateLabelAppearance];
	self.needsDisplay = YES;
}

- (void)setTitleBarBackgroundColor:(NSColor*)color
{
	if(_titleBarBackgroundColor == color || [_titleBarBackgroundColor isEqual:color])
		return;
	_titleBarBackgroundColor = color;
	[self updateTitleBarAppearance];
}

- (void)viewDidChangeEffectiveAppearance
{
	[super viewDidChangeEffectiveAppearance];
	[self updateTitleBarAppearance];
}

- (void)drawRect:(NSRect)dirtyRect
{
	[super drawRect:dirtyRect];
	if(!self.isWindowTitleBar)
		return;

	NSColor* surface = [self titleBarSurfaceColor];
	NSColor* ink = [self titleBarInkColor];
	BOOL hasMultipleTabs = _tabItems.count > 1;
	[surface setFill];
	NSRectFill(dirtyRect);
	if(!hasMultipleTabs && _dropTabAtIndex < 0)
		return;
	[[ink colorWithAlphaComponent:0.045] setFill];
	NSRectFillUsingOperation(dirtyRect, NSCompositingOperationSourceOver);

	// The selected tab uses the editor background. The dividing line rises up
	// its two sides, leaving a gap where the tab joins the editor.
	CGFloat pixel = 1.0 / (self.window.backingScaleFactor ?: 1);
	NSRect selectedRect = NSZeroRect;
	for(OakTabFrame* frame in _currentLayout)
	{
		OakTabView* view = frame.tabItem.tabView;
		if(view.hidden || frame.width <= 0)
			continue;
		NSRect rect = NSIntersectionRect(NSMakeRect(NSMinX(view.frame), NSMinY(self.bounds), NSWidth(view.frame), NSHeight(self.bounds)), self.bounds);
		if(frame.tabItem.isSelected)
		{
			selectedRect = rect;
			[surface setFill];
			NSRectFill(NSIntersectionRect(rect, dirtyRect));
			continue;
		}
		BOOL placeholder = ![_tabItems containsObject:frame.tabItem];
		if(placeholder || view.isMouseInside)
		{
			[[ink colorWithAlphaComponent:placeholder ? 0.11 : 0.05] setFill];
			NSRectFillUsingOperation(NSIntersectionRect(rect, dirtyRect), NSCompositingOperationSourceOver);
		}
	}
	[[ink colorWithAlphaComponent:0.18] setFill];
	CGFloat bottom = NSMinY(self.bounds), left = NSMinX(self.bounds), right = NSMaxX(self.bounds);
	if(NSIsEmptyRect(selectedRect))
	{
		NSRectFillUsingOperation(NSMakeRect(left, bottom, right - left, pixel), NSCompositingOperationSourceOver);
		return;
	}
	CGFloat selectionLeft = NSMinX(selectedRect), selectionRight = NSMaxX(selectedRect);
	NSRectFillUsingOperation(NSMakeRect(left, bottom, selectionLeft - left, pixel), NSCompositingOperationSourceOver);
	NSRectFillUsingOperation(NSMakeRect(selectionRight, bottom, right - selectionRight, pixel), NSCompositingOperationSourceOver);
	NSRectFillUsingOperation(NSMakeRect(selectionLeft - pixel, bottom + pixel, pixel, NSHeight(self.bounds) - pixel), NSCompositingOperationSourceOver);
	NSRectFillUsingOperation(NSMakeRect(selectionRight, bottom + pixel, pixel, NSHeight(self.bounds) - pixel), NSCompositingOperationSourceOver);
}

- (BOOL)mouseDownCanMoveWindow
{
	return NO;
}

- (NSRect)_opaqueRectForWindowMoveWhenInTitlebar
{
	// A full-size content view still overlaps the native title bar. AppKit's
	// window-move hit testing uses this rect separately from -hitTest: and
	// -mouseDownCanMoveWindow. Cover the strip so only the gestures we choose
	// are handed back to AppKit as window moves, as in iTerm's Minimal bar.
	return self.isWindowTitleBar ? self.bounds : NSZeroRect;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event
{
	return self.isWindowTitleBar;
}

- (BOOL)canDragWindow
{
	NSWindow* window = self.window;
	return self.isWindowTitleBar && window.isMovable && !window.attachedSheet && !(window.styleMask & NSWindowStyleMaskFullScreen);
}

- (BOOL)shouldDragWindowFromTabWithEvent:(NSEvent*)event
{
	if(![self canDragWindow])
		return NO;
	if(event.modifierFlags & NSEventModifierFlagOption)
		return YES;
	return self.countOfVisibleTabs == 1;
}

- (NSInteger)countOfVisibleTabs
{
	NSInteger count = 0;
	for(OakTabFrame* frame in _currentLayout)
		if(frame.width > 0 && [_tabItems containsObject:frame.tabItem])
			++count;
	return count;
}

- (void)dragWindowWithEvent:(NSEvent*)event
{
	[self.window makeKeyAndOrderFront:nil];
	[self.window performWindowDragWithEvent:event];
}

- (NSView*)hitTest:(NSPoint)aPoint
{
	NSView* hit = [super hitTest:aPoint];
	if([hit isKindOfClass:OakTabView.class] && [self canDragWindow])
	{
		NSPoint local = [self convertPoint:aPoint fromView:self.superview];
		if(NSMaxY(self.bounds) - local.y < kTitleBarDragEdgeHeight)
			return self;
	}
	return hit;
}

- (void)mouseDown:(NSEvent*)anEvent
{
	if([self canDragWindow])
	{
		if(anEvent.clickCount == 2)
			[self performTitlebarDoubleClick:self];
		else
			[self dragWindowWithEvent:anEvent];
	}
	else if(!self.isWindowTitleBar && anEvent.clickCount == 2 && [_delegate respondsToSelector:@selector(tabBarViewDidDoubleClick:)])
	{
		[_delegate tabBarViewDidDoubleClick:self];
	}
}

- (NSMenu*)menuForEvent:(NSEvent*)anEvent
{
	_tag = -1;
	return [_delegate respondsToSelector:@selector(menuForTabBarView:)] ? [_delegate menuForTabBarView:self] : nil;
}

- (NSButton*)createNewTabButton
{
	if(!_createNewTabButton)
	{
		OakAddTabButton* button = [[OakAddTabButton alloc] initWithFrame:NSMakeRect(0, 2, 26, 20)];
		button.tabBar = self;
		_createNewTabButton = button;
		_createNewTabButton.accessibilityLabel = @"Create new tab";
		_createNewTabButton.image      = [NSImage imageNamed:NSImageNameAddTemplate];
		_createNewTabButton.bordered   = NO;
		_createNewTabButton.buttonType = NSButtonTypeMomentaryChange;
		_createNewTabButton.toolTip    = @"Create new tab";
		_createNewTabButton.action     = @selector(newTab:);
		_createNewTabButton.target     = self;
		if(self.isWindowTitleBar)
			button.contentTintColor = [self titleBarInkColor];
	}
	return _createNewTabButton;
}

- (NSTextField*)statusTextLabel
{
	if(!_statusTextLabel)
	{
		_statusTextLabel                 = [[OakTabBarLabel alloc] initWithFrame:NSZeroRect];
		_statusTextLabel.editable        = NO;
		_statusTextLabel.bezeled         = NO;
		_statusTextLabel.drawsBackground = NO;
		_statusTextLabel.bordered        = NO;
		_statusTextLabel.hidden          = YES;
		_statusTextLabel.lineBreakMode   = NSLineBreakByTruncatingTail;
		_statusTextLabel.textColor       = NSColor.secondaryLabelColor;
	}
	return _statusTextLabel;
}

- (void)setStatusText:(NSString*)text color:(NSColor*)color
{
	NSString* newText = text ?: @"";
	if([_statusTextLabel.stringValue isEqualToString:newText] && [_statusTextLabel.textColor isEqual:color ?: NSColor.secondaryLabelColor])
		return;
	_statusTextLabel.stringValue = newText;
	_statusTextLabel.textColor   = color ?: NSColor.secondaryLabelColor;
	_statusTextLabel.hidden      = newText.length == 0;
	[_statusTextLabel sizeToFit];
	[self updateToLayout:[self makeLayout]];
}

- (void)setCollapsedTitle:(NSString*)title
{
	if(_collapsedTitle == title || [_collapsedTitle isEqualToString:title])
		return;
	_collapsedTitle = [title copy];
	if(title && !_collapsedTitleLabel)
	{
		_collapsedTitleLabel = [[OakTabBarLabel alloc] initWithFrame:NSZeroRect];
		_collapsedTitleLabel.editable = NO;
		_collapsedTitleLabel.selectable = NO;
		_collapsedTitleLabel.bordered = NO;
		_collapsedTitleLabel.drawsBackground = NO;
		_collapsedTitleLabel.alignment = NSTextAlignmentCenter;
		_collapsedTitleLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium];
		_collapsedTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
		[self addSubview:_collapsedTitleLabel positioned:NSWindowBelow relativeTo:_createNewTabButton];
		[self updateTitleBarAppearance];
	}
	_collapsedTitleLabel.stringValue = title ?: @"";
	[self updateToLayout:[self makeLayout]];
}

- (void)setDragging:(BOOL)dragging
{
	if(_dragging == dragging)
		return;
	_dragging = dragging;
	if(_collapsedTitle)
		[self updateToLayout:[self makeLayout]];
}

- (NSUInteger)selectedTabIndex
{
	return [_tabItems indexOfObjectPassingTest:^BOOL(OakTabItem* tabItem, NSUInteger index, BOOL* stop){ return tabItem.isSelected; }];
}

- (NSString*)selectedTabIdentifier
{
	NSUInteger index = self.selectedTabIndex;
	return index == NSNotFound ? nil : _tabItems[index].identifier;
}

- (void)selectTabWithIdentifier:(NSString*)identifier
{
	if(!identifier)
		return;
	NSUInteger index = [_tabItems indexOfObjectPassingTest:^BOOL(OakTabItem* item, NSUInteger index, BOOL* stop){ return [item.identifier isEqualToString:identifier]; }];
	if(index != NSNotFound && index != self.selectedTabIndex)
	{
		self.selectedTabIndex = index;
		if([_delegate respondsToSelector:@selector(tabBarView:shouldSelectIndex:)])
			[_delegate tabBarView:self shouldSelectIndex:index];
	}
}

- (void)setDraggedTabIndex:(NSInteger)newDraggedTabIndex
{
	if(_draggedTabIndex == newDraggedTabIndex)
		return;

	if(_draggedTabIndex != -1)
		_tabItems[_draggedTabIndex].tabView.hidden = NO;

	_draggedTabIndex = newDraggedTabIndex;

	if(_draggedTabIndex != -1)
		_tabItems[_draggedTabIndex].tabView.hidden = YES;

	[self updateToLayout:[self makeLayout]];
}

- (void)setDropTabAtIndex:(NSInteger)newDropTabAtIndex
{
	if(_dropTabAtIndex == newDropTabAtIndex)
		return;

	_dropTabAtIndex = newDropTabAtIndex;
	[self updateToLayout:[self makeLayout]];
}

- (NSString*)toolTipForIndex:(NSUInteger)anIndex
{
	// A data source without an opinion keeps the path tooltip OakTabView derives itself.
	if([_dataSource respondsToSelector:@selector(tabBarView:toolTipForIndex:)])
		return [_dataSource tabBarView:self toolTipForIndex:anIndex];
	return nil;
}

- (void)reloadData
{
	if(!_tabItems)
		_tabItems = [NSMutableArray array];

	NSUInteger newCount = [_dataSource numberOfRowsInTabBarView:self];
	if(newCount > _tabItems.count)
		_freezeTabFramesLeftOfIndex = 0;

	OakTabItem* draggedTabItem = _draggedTabIndex != -1 ? _tabItems[_draggedTabIndex] : nil;
	OakTabItem* droppedTabItem = _dropTabAtIndex != -1 && _dropTabAtIndex < _tabItems.count ? _tabItems[_dropTabAtIndex] : nil;

	NSMutableDictionary<NSString*, OakTabItem*>* oldTabItems = [NSMutableDictionary dictionary];
	for(OakTabItem* tabItem in _tabItems)
		oldTabItems[tabItem.identifier] = tabItem;

	NSMutableArray<OakTabItem*>* newTabItems = [NSMutableArray array];
	for(NSUInteger i = 0; i < newCount; ++i)
	{
		NSString* identifier = [_dataSource tabBarView:self UUIDForIndex:i].UUIDString;
		OakTabItem* tabItem = oldTabItems[identifier];
		if(tabItem)
		{
			tabItem.title    = [_dataSource tabBarView:self titleForIndex:i];
			tabItem.path     = [_dataSource tabBarView:self pathForIndex:i];
			tabItem.modified = [_dataSource tabBarView:self isEditedAtIndex:i];

			oldTabItems[identifier] = nil;
		}
		else
		{
			tabItem = [[OakTabItem alloc] initWithTitle:[_dataSource tabBarView:self titleForIndex:i] path:[_dataSource tabBarView:self pathForIndex:i] identifier:identifier modified:[_dataSource tabBarView:self isEditedAtIndex:i]];
		}
		tabItem.toolTip = [self toolTipForIndex:i];
		OakTabStatus status = [_dataSource respondsToSelector:@selector(tabBarView:statusForIndex:)] ? [_dataSource tabBarView:self statusForIndex:i] : OakTabStatusNone;
        NSString* description = [_dataSource respondsToSelector:@selector(tabBarView:statusDescriptionForIndex:)] ? [_dataSource tabBarView:self statusDescriptionForIndex:i] : @"";
        NSDictionary* info = @{ @"value": @(status), @"description": description ?: @"" };
        if(![tabItem.statusInfo isEqual:info]) { tabItem.statusInfo = info; tabItem.needsLayout = YES; }
        [newTabItems addObject:tabItem];
	}

	_tabItems = newTabItems;

	_draggedTabIndex = draggedTabItem ? ([_tabItems indexOfObject:draggedTabItem] == NSNotFound ? -1 : [_tabItems indexOfObject:draggedTabItem]) : -1;
	_dropTabAtIndex  = droppedTabItem ? ([_tabItems indexOfObject:droppedTabItem] == NSNotFound ? -1 : [_tabItems indexOfObject:droppedTabItem]) : (_dropTabAtIndex == -1 ? -1 : _tabItems.count);

	NSArray<OakTabFrame*>* newLayout = [self makeLayout];
	if(![_toLayout isEqual:newLayout])
		[self updateToLayout:newLayout];
}

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if(_trackingArea)
		[self removeTrackingArea:_trackingArea];
	NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways;
	if(NSMouseInRect([self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil], self.visibleRect, self.isFlipped))
		options |= NSTrackingAssumeInside;

	_trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:options owner:self userInfo:nil];
	[self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent*)anEvent
{
}

- (void)mouseExited:(NSEvent*)anEvent
{
	if(_freezeTabFramesLeftOfIndex > 0)
	{
		_freezeTabFramesLeftOfIndex = 0;
		[self.animator updateToLayout:[self makeLayout]];
	}
}

- (void)didClickOverflorButtonForTabView:(OakTabView*)clickedTabView
{
	NSMenu* menu = [NSMenu new];
	for(NSUInteger i = 0; i < _tabItems.count; ++i)
	{
		OakTabItem* tabItem = _tabItems[i];
		if(tabItem.tabView && !tabItem.tabView.overflowButtonVisible && NSWidth(tabItem.tabView.frame) != 0)
			continue;

		NSMenuItem* item = [menu addItemWithTitle:tabItem.title action:@selector(takeSelectedTabIndexFrom:) keyEquivalent:@""];
		item.representedObject = tabItem;
		item.tag = i;

		NSString* path = tabItem.path;
		if(OakNotEmptyString(path))
		{
			item.image   = [TMFileReference imageForURL:[NSURL fileURLWithPath:tabItem.path] size:NSMakeSize(16, 16)];
			item.toolTip = [path stringByAbbreviatingWithTildeInPath];
		}
		else
		{
			item.image = [[NSWorkspace.sharedWorkspace iconForContentType:UTTypeData] copy];
			item.image.size = NSMakeSize(16, 16);
		}

		if([tabItem.statusInfo[@"value"] integerValue] != OakTabStatusNone) {
            NSString* status = tabItem.statusInfo[@"description"];
            item.title = [NSString stringWithFormat:@"%@ — %@", tabItem.title, status];
            item.toolTip = status;
        }
        if(tabItem.isSelected)
			item.state = NSControlStateValueOn;
		else if(tabItem.isModified)
			item.modifiedState = YES;
	}
	[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSWidth(clickedTabView.overflowButton.frame), 0) inView:clickedTabView.overflowButton];
}

// ===========
// = Actions =
// ===========

- (void)setSelectedTabIndex:(NSUInteger)index
{
	for(NSUInteger i = 0; i < _tabItems.count; ++i)
		_tabItems[i].selected = i == index;

	if(index < _tabItems.count)
	{
		if(!_tabItems[index].tabView || NSWidth(_tabItems[index].tabView.frame) == 0)
			[self updateToLayout:[self makeLayout]];
	}
}

- (void)didClickCloseButtonForTabView:(OakTabView*)tabView
{
	_tag = [_tabItems indexOfObject:tabView.tabItem]; // performCloseTab: asks for [sender tag]
	if(_tag == NSNotFound)
		return;

	BOOL closeOther = OakIsAlternateKeyOrMouseEvent();
	if(closeOther && [_delegate respondsToSelector:@selector(performCloseOtherTabsXYZ:)])
	{
		[_delegate performCloseOtherTabsXYZ:self];
	}
	else if([_delegate respondsToSelector:@selector(performCloseTab:)])
	{
		_freezeTabFramesLeftOfIndex = _tag;
		[_delegate performCloseTab:self];
	}
}

- (void)didSingleClickTabView:(OakTabView*)tabView
{
	NSInteger index = [_tabItems indexOfObject:tabView.tabItem];
	if(index == NSNotFound)
		return;

	self.selectedTabIndex = index;
	if([_delegate respondsToSelector:@selector(tabBarView:shouldSelectIndex:)])
		[_delegate tabBarView:self shouldSelectIndex:index];
}

- (void)didDoubleClickTabView:(OakTabView*)tabView
{
	NSInteger index = [_tabItems indexOfObject:tabView.tabItem];
	if(index == NSNotFound)
		return;

	if([_delegate respondsToSelector:@selector(tabBarView:didDoubleClickIndex:)])
		[_delegate tabBarView:self didDoubleClickIndex:index];
}

- (NSInteger)tag
{
	return _tag;
}

- (NSMenu*)menuForTabView:(OakTabView*)tabView withEvent:(NSEvent*)anEvent
{
	_tag = [_tabItems indexOfObject:tabView.tabItem];
	if(_tag != NSNotFound && [_delegate respondsToSelector:@selector(menuForTabBarView:)])
		return [_delegate menuForTabBarView:self];
	return nil;
}

- (void)newTab:(id)sender
{
	if([_delegate respondsToSelector:@selector(newTabInTabBar:)])
		[_delegate newTabInTabBar:self];
	else if([_delegate respondsToSelector:@selector(tabBarViewDidDoubleClick:)])
		[_delegate tabBarViewDidDoubleClick:self];
}

// The blank part of the tab bar serves as the window title bar.
- (void)performTitlebarDoubleClick:(id)sender
{
	NSString* action = [NSUserDefaults.standardUserDefaults stringForKey:@"AppleActionOnDoubleClick"];
	NSWindow* window = self.window;
	if([action isEqualToString:@"Minimize"])
		[window performMiniaturize:sender];
	else if([action isEqualToString:@"Fill"] || [action isEqualToString:@"Fill Screen"])
	{
		if([window respondsToSelector:@selector(_zoomFill:)])
			[window _zoomFill:window.contentView.superview];
		else if(NSScreen* screen = window.screen)
			[window setFrame:screen.visibleFrame display:YES animate:YES];
	}
	else if(!action || [action isEqualToString:@"Maximize"] || [action isEqualToString:@"Zoom"])
		[window performZoom:sender];
}

- (void)performClose:(id)sender
{
	for(OakTabItem* tabItem in [_tabItems filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"selected == YES"]])
	{
		_tag = [_tabItems indexOfObject:tabItem]; // performCloseTab: asks for [sender tag]
		if([_delegate respondsToSelector:@selector(performCloseTab:)])
			[_delegate performCloseTab:self];
	}
}

// ===============
// = Drag’n’drop =
// ===============

- (void)didDragTabView:(OakTabView*)tabView
{
	NSEvent* dragEvent = self.window.currentEvent;
	NSUInteger index = [_tabItems indexOfObject:tabView.tabItem];
	if(!dragEvent || !tabView.mouseDownEvent || index == NSNotFound)
		return;

	NSDraggingItem* dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:tabView.tabItem];
	if(NSImage* dragImage = tabView.dragImage)
		[dragItem setDraggingFrame:[self convertRect:tabView.bounds fromView:tabView] contents:dragImage];

	self.tabDragStart = [self.window convertPointToScreen:tabView.mouseDownEvent.locationInWindow];
	self.tabDragWindowOffset = NSMakePoint(_tabDragStart.x - NSMinX(self.window.frame), _tabDragStart.y - NSMaxY(self.window.frame));
	self.tabDragLeftRail = NO;
	self.selectionBeforeTabDrag = tabView.previousSelection;
	if(self.isWindowTitleBar)
	{
		NSMutableDictionary* midpoints = [NSMutableDictionary dictionary];
		for(OakTabFrame* frame in _currentLayout)
		{
			if(frame.width > 0 && frame.tabItem != tabView.tabItem)
				midpoints[frame.tabItem.identifier] = @(NSMidX(frame.tabItem.tabView.frame));
		}
		self.tabDragMidpoints = midpoints;
	}
	self.draggedTabIndex = index;
	self.dropTabAtIndex = index;

	NSDraggingSession* session = [self beginDraggingSessionWithItems:@[ dragItem ] event:dragEvent source:self];
	if(self.isWindowTitleBar)
		session.animatesToStartingPositionsOnCancelOrFail = NO;
}

- (NSDragOperation)draggingSession:(NSDraggingSession*)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context
{
	return context == NSDraggingContextOutsideApplication ? (NSDragOperationCopy|NSDragOperationGeneric) : (NSDragOperationCopy|NSDragOperationMove|NSDragOperationLink);
}

- (NSPoint)pointInBarFromScreen:(NSPoint)screenPoint
{
	return [self convertPoint:[self.window convertPointFromScreen:screenPoint] fromView:nil];
}

- (BOOL)isTabDragOnRailAtPoint:(NSPoint)screenPoint
{
	if(!self.isWindowTitleBar)
		return NO;
	if(fabs(screenPoint.y - _tabDragStart.y) > kTabDragRailDistance)
		self.tabDragLeftRail = YES;
	return !_tabDragLeftRail;
}

- (NSPoint)topLeftForTabDragAtPoint:(NSPoint)screenPoint
{
	return NSMakePoint(screenPoint.x - _tabDragWindowOffset.x, screenPoint.y - _tabDragWindowOffset.y);
}

- (NSInteger)railDropIndexAtPoint:(NSPoint)point
{
	// Use the positions from before moving the placeholder. Otherwise moving
	// the placeholder can put the same pointer back on the previous slot.
	NSInteger dropIndex = _draggedTabIndex;
	for(NSUInteger i = 0; i < _tabItems.count; ++i)
	{
		if(NSNumber* midpoint = _tabDragMidpoints[_tabItems[i].identifier])
		{
			if(point.x < midpoint.doubleValue)
				return i;
			dropIndex = i + 1;
		}
	}
	return dropIndex;
}

- (void)updateTabDragPreviewAtPoint:(NSPoint)screenPoint
{
	if(!self.isWindowTitleBar || self.draggedTabIndex < 0 || ![_delegate respondsToSelector:@selector(tabBarView:tearOffPreviewForTabAtIndex:)])
		return;
	OakTabBarView* destination = self.tabDragDestination;
	if(NSPointInRect([self pointInBarFromScreen:screenPoint], self.bounds) || (destination && NSPointInRect([destination pointInBarFromScreen:screenPoint], destination.bounds)))
	{
		[_tabDragPreview orderOut:nil];
		return;
	}
	if(!_tabDragPreview)
	{
		NSImage* image = [_delegate tabBarView:self tearOffPreviewForTabAtIndex:self.draggedTabIndex];
		if(!image)
			return;
		NSRect frame = NSMakeRect(0, 0, image.size.width, image.size.height);
		NSPanel* preview = [[NSPanel alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
		preview.ignoresMouseEvents = YES;
		preview.excludedFromWindowsMenu = YES;
		preview.collectionBehavior = NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
		preview.level = NSFloatingWindowLevel;
		preview.alphaValue = 0.82;
		preview.hasShadow = YES;
		preview.opaque = NO;
		preview.backgroundColor = NSColor.clearColor;
		NSImageView* imageView = [[NSImageView alloc] initWithFrame:frame];
		imageView.image = image;
		imageView.wantsLayer = YES;
		imageView.layer.cornerRadius = 10;
		imageView.layer.masksToBounds = YES;
		preview.contentView = imageView;
		self.tabDragPreview = preview;
		[self selectTabWithIdentifier:self.selectionBeforeTabDrag];
	}
	[_tabDragPreview setFrameTopLeftPoint:[self topLeftForTabDragAtPoint:screenPoint]];
	if(!_tabDragPreview.isVisible)
		[_tabDragPreview orderFront:nil];
}

- (void)draggingSession:(NSDraggingSession*)session movedToPoint:(NSPoint)screenPoint
{
	if([self isTabDragOnRailAtPoint:screenPoint])
		self.dropTabAtIndex = [self railDropIndexAtPoint:[self pointInBarFromScreen:screenPoint]];
	else
		[self updateTabDragPreviewAtPoint:screenPoint];
}

- (void)draggingSession:(NSDraggingSession*)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation
{
	NSInteger index = _draggedTabIndex;
	BOOL cancelled = (NSEvent.pressedMouseButtons & 1) != 0;
	BOOL onRail = [self isTabDragOnRailAtPoint:screenPoint];
	NSPoint pointInBar = [self pointInBarFromScreen:screenPoint];
	NSInteger dropIndex = onRail ? [self railDropIndexAtPoint:pointInBar] : -1;
	NSUUID* identifier = index >= 0 && index < _tabItems.count ? [[NSUUID alloc] initWithUUIDString:_tabItems[index].identifier] : nil;
	self.dragging = NO;
	self.draggedTabIndex = -1;
	self.dropTabAtIndex = -1;
	self.tabDragLeftRail = NO;
	self.tabDragMidpoints = nil;
	self.tabDragDestination = nil;
	[_tabDragPreview orderOut:nil];
	self.tabDragPreview = nil;
	NSString* previousSelection = self.selectionBeforeTabDrag;
	self.selectionBeforeTabDrag = nil;
	if(cancelled)
		[self selectTabWithIdentifier:previousSelection];

	if(operation != NSDragOperationNone || !identifier || cancelled)
		return;
	if(onRail)
	{
		if(dropIndex != index && dropIndex != index + 1 && [_delegate respondsToSelector:@selector(performDropOfTabItem:fromTabBar:index:toTabBar:index:operation:)])
			[_delegate performDropOfTabItem:identifier fromTabBar:self index:index toTabBar:self index:dropIndex operation:NSDragOperationMove];
	}
	else if(!NSPointInRect(pointInBar, self.bounds) && [_delegate respondsToSelector:@selector(tabBarView:didTearOffTabAtIndex:atWindowTopLeft:)])
	{
		[self selectTabWithIdentifier:previousSelection];
		[_delegate tabBarView:self didTearOffTabAtIndex:(NSUInteger)index atWindowTopLeft:[self topLeftForTabDragAtPoint:screenPoint]];
	}
}

// ========================
// = Dragging Destination =
// ========================

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
	return [self draggingUpdated:sender];
}

- (NSInteger)dropIndexAtPoint:(NSPoint)point
{
	for(OakTabFrame* frame in _currentLayout)
	{
		NSUInteger index = [_tabItems indexOfObject:frame.tabItem];
		NSRect rect = frame.tabItem.tabView.frame;
		if(index == NSNotFound && _dropTabAtIndex >= 0 && point.x >= NSMinX(rect) && point.x < NSMaxX(rect))
			return _dropTabAtIndex;
		if(index != NSNotFound && frame.width > 0 && point.x < NSMidX(rect))
			return index;
	}
	return _tabItems.count;
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
	OakTabBarView* source = [sender.draggingSource isKindOfClass:OakTabBarView.class] ? sender.draggingSource : nil;
	NSDragOperation mask = sender.draggingSourceOperationMask;
	NSDragOperation operation = (mask & NSDragOperationMove) ?: (mask & NSDragOperationCopy);
	if(!operation || !source || !_delegate || [_delegate class] != [source.delegate class])
		return NSDragOperationNone;
	if(source != self && [source isTabDragOnRailAtPoint:NSEvent.mouseLocation])
		return NSDragOperationNone;
	source.tabDragDestination = self;
	[source.tabDragPreview orderOut:nil];
	self.dragging = YES;
	NSPoint point = [self pointInBarFromScreen:NSEvent.mouseLocation];
	self.dropTabAtIndex = source == self && [self isTabDragOnRailAtPoint:NSEvent.mouseLocation] ? [self railDropIndexAtPoint:point] : [self dropIndexAtPoint:point];
	return operation;
}

- (void)draggingExited:(id <NSDraggingInfo>)sender
{
	OakTabBarView* source = [sender.draggingSource isKindOfClass:OakTabBarView.class] ? sender.draggingSource : nil;
	if(source.tabDragDestination == self)
		source.tabDragDestination = nil;
	self.dragging = NO;
	if(source != self || ![self isTabDragOnRailAtPoint:NSEvent.mouseLocation])
		self.animator.dropTabAtIndex = -1;
}

- (BOOL)prepareForDragOperation:(id <NSDraggingInfo>)sender
{
	// The last destination update can precede mouse-up. Validate the actual
	// release location before accepting a drop, especially after leaving the bar.
	NSPoint screenPoint = NSEvent.mouseLocation;
	OakTabBarView* source = sender.draggingSource;
	if(!NSPointInRect([self pointInBarFromScreen:screenPoint], self.bounds) || (source != self && [source isTabDragOnRailAtPoint:screenPoint]))
	{
		self.dragging = NO;
		self.dropTabAtIndex = -1;
		return NO;
	}
	sender.animatesToDestination = YES;
	return YES;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
	OakTabBarView* sourceTabBar = sender.draggingSource;
	NSDragOperation mask = sender.draggingSourceOperationMask;
	NSInteger fromIndex = sourceTabBar.draggedTabIndex;
	NSPoint screenPoint = NSEvent.mouseLocation;
	NSPoint point = [self pointInBarFromScreen:screenPoint];
	NSInteger toIndex = sourceTabBar == self && [self isTabDragOnRailAtPoint:screenPoint] ? [self railDropIndexAtPoint:point] : [self dropIndexAtPoint:point];

	__block OakTabItem* tabItem = nil;
	[sender enumerateDraggingItemsWithOptions:0 forView:self classes:@[ [NSPasteboardItem class] ] searchOptions:@{ } usingBlock:^(NSDraggingItem* draggingItem, NSInteger idx, BOOL* stop){
		for(OakTabFrame* frame in _currentLayout)
		{
			if(![_tabItems containsObject:frame.tabItem] && frame.tabItem.tabView)
			{
				draggingItem.draggingFrame = frame.tabItem.tabView.frame;
				break;
			}
		}
		tabItem = [OakTabItem tabItemFromPasteboardItem:draggingItem.item];
	}];

	self.draggedTabIndex = -1;
	self.dropTabAtIndex  = -1;

	if(sourceTabBar == self && (fromIndex == toIndex || fromIndex + 1 == toIndex))
		return YES;
	if(sourceTabBar != self)
		[sourceTabBar selectTabWithIdentifier:sourceTabBar.selectionBeforeTabDrag];

	BOOL shouldDelegate = [_delegate respondsToSelector:@selector(performDropOfTabItem:fromTabBar:index:toTabBar:index:operation:)];
	return shouldDelegate && [_delegate performDropOfTabItem:[[NSUUID alloc] initWithUUIDString:tabItem.identifier] fromTabBar:sourceTabBar index:fromIndex toTabBar:self index:toIndex operation:(mask & NSDragOperationMove) ?: (mask & NSDragOperationCopy)];
}

- (void)concludeDragOperation:(id <NSDraggingInfo>)sender
{
	self.dragging = NO;
}

// ==========
// = Layout =
// ==========

- (NSArray<OakTabFrame*>*)interpolatedLayout:(NSArray<OakTabFrame*>*)oldLayout withFraction:(CGFloat)fraction ofLayout:(NSArray<OakTabFrame*>*)newLayout
{
	if(fraction == 0)
		return oldLayout;
	else if(fraction == 1)
		return newLayout;

	struct tab_t
	{
		tab_t (OakTabItem* tabItem, CGFloat oldWidth, CGFloat newWidth) : tabItem(tabItem), oldWidth(oldWidth), newWidth(newWidth) { }
		OakTabItem* tabItem;
		CGFloat oldWidth;
		CGFloat newWidth;
		CGFloat currentWidth = 0;
	};

	NSSet<NSString*>* oldTabIdentifiers = [NSSet setWithArray:[oldLayout valueForKeyPath:@"tabItem.identifier"]];
	NSSet<NSString*>* newTabIdentifiers = [NSSet setWithArray:[newLayout valueForKeyPath:@"tabItem.identifier"]];

	std::vector<tab_t> tabs;
	for(NSUInteger i = 0, j = 0; i < oldLayout.count || j < newLayout.count; )
	{
		if(j == newLayout.count || i < oldLayout.count && ![newTabIdentifiers containsObject:oldLayout[i].tabItem.identifier])
		{
			if(oldLayout[i].width > 0)
				tabs.emplace_back(oldLayout[i].tabItem, oldLayout[i].width, 0);
			++i;
		}
		else if(i == oldLayout.count || j < newLayout.count && ![oldTabIdentifiers containsObject:newLayout[j].tabItem.identifier])
		{
			if(newLayout[j].width > 0)
				tabs.emplace_back(newLayout[j].tabItem, 0, newLayout[j].width);
			++j;
		}
		else if([oldLayout[i].tabItem.identifier isEqualToString:newLayout[j].tabItem.identifier])
		{
			if(oldLayout[i].width > 0 || newLayout[j].width > 0)
				tabs.emplace_back(oldLayout[i].tabItem, oldLayout[i].width, newLayout[j].width);
			++i;
			++j;
		}
		else
		{
			NSLog(@"%s *** assertion failure for %@ != %@", sel_getName(_cmd), oldLayout[i].tabItem, newLayout[j].tabItem);
			break;
		}
	}

	CGFloat oldX0 = 0, newX0 = 0, x0 = 0;
	for(auto& tab : tabs)
	{
		CGFloat const oldX1 = oldX0 + tab.oldWidth;
		CGFloat const newX1 = newX0 + tab.newWidth;

		CGFloat x1 = oldX1 + round(fraction * (newX1 - oldX1));
		tab.currentWidth = x1 - x0;

		x0    = x1;
		oldX0 = oldX1;
		newX0 = newX1;
	}

	NSMutableArray<OakTabFrame*>* result = [NSMutableArray array];
	for(auto const& tab : tabs)
		[result addObject:[[OakTabFrame alloc] initWithTabItem:tab.tabItem width:tab.currentWidth]];
	return result;
}

- (void)setLeadingContentInset:(CGFloat)leadingContentInset
{
	if(_leadingContentInset == leadingContentInset)
		return;
	_leadingContentInset = leadingContentInset;
	[self updateToLayout:[self makeLayout]];
}

- (NSArray<OakTabFrame*>*)makeLayoutForTabItems:(NSArray<OakTabItem*>*)tabItems inRectOfWidth:(CGFloat)totalWidth
{
	if(self.isWindowTitleBar)
	{
		// Keep short filenames compact. Extra space remains a window drag area.
		CGFloat desiredWidth = 0;
		NSMutableArray<OakTabFrame*>* compactLayout = [NSMutableArray arrayWithCapacity:tabItems.count];
		for(OakTabItem* item in tabItems)
		{
			CGFloat width = MIN(_maximumTabSize, MAX(_minimumTabSize, item.fittingWidth));
			desiredWidth += width;
			[compactLayout addObject:[[OakTabFrame alloc] initWithTabItem:item width:width]];
		}
		if(desiredWidth <= totalWidth)
			return compactLayout;
	}
	if(self.leadingContentInset <= 0)
		totalWidth += 1; // The leftmost tab starts at -1 when there is no inset.

	NSMutableArray<OakTabFrame*>* array = [NSMutableArray array];
	if(_maximumTabSize * tabItems.count <= totalWidth)
	{
		for(NSUInteger i = 0; i < tabItems.count; ++i)
			[array addObject:[[OakTabFrame alloc] initWithTabItem:tabItems[i] width:_maximumTabSize]];
	}
	else
	{
		CGFloat supply = 0, demand = 0;

		for(NSUInteger i = 0; i < tabItems.count; ++i)
		{
			CGFloat x0 = round(totalWidth * (i+0) / tabItems.count);
			CGFloat x1 = round(totalWidth * (i+1) / tabItems.count);
			CGFloat width = x1 - x0;

			if(width < tabItems[i].fittingWidth)
					demand += tabItems[i].fittingWidth - width;
			else	supply += width - tabItems[i].fittingWidth;
		}

		CGFloat counter = 0;
		for(NSUInteger i = 0; i < tabItems.count; ++i)
		{
			CGFloat x0 = round(totalWidth * (i+0) / tabItems.count);
			CGFloat x1 = round(totalWidth * (i+1) / tabItems.count);
			CGFloat width = x1 - x0;

			if(supply != 0 && demand != 0)
			{
				if(supply <= demand)
				{
					if(tabItems[i].fittingWidth < width)
					{
						width = tabItems[i].fittingWidth;
					}
					else
					{
						CGFloat x0 = round(supply * counter / demand);
						counter += tabItems[i].fittingWidth - width;
						CGFloat x1 = round(supply * counter / demand);
						width += x1 - x0;
					}
				}
				else if(width < tabItems[i].fittingWidth)
				{
					width = tabItems[i].fittingWidth;
				}
				else
				{
					CGFloat x0 = round(demand * counter / supply);
					counter += width - tabItems[i].fittingWidth;
					CGFloat x1 = round(demand * counter / supply);
					width -= x1 - x0;
				}
			}

			[array addObject:[[OakTabFrame alloc] initWithTabItem:tabItems[i] width:width]];
		}
	}
	return array;
}

- (NSArray<OakTabFrame*>*)makeLayout
{
	if(_collapsedTitle && !_dragging)
		return @[];

	static NSString* const firstTabIdentifier = [NSUUID UUID].UUIDString;
	// Reserve leading traffic-light inset (Minimal) and trailing chrome so tabs
	// cannot slide under the "+" button or status label.
	CGFloat visibleWidth = NSWidth(self.bounds) - NSWidth(self.createNewTabButton.frame) - MAX(0, self.leadingContentInset);
	if(!_statusTextLabel.hidden)
		visibleWidth -= NSWidth(_statusTextLabel.frame) + 16;
	NSUInteger const countOfVisibleTabs = MIN(MAX(0, floor(visibleWidth / _minimumTabSize)), _tabItems.count);

	NSMutableArray<OakTabItem*>* tabItems = [NSMutableArray array];
	BOOL didIncludeSelected = [_tabItems filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"selected == YES"]].count == 0;
	for(NSUInteger visibleCount = 0, i = 0; i <= _tabItems.count; ++i)
	{
		if(i == _dropTabAtIndex)
		{
			NSString* identifier = _dropTabAtIndex == 0 ? firstTabIdentifier : [_tabItems[_dropTabAtIndex-1].identifier stringByAppendingString:@".margin"];
			OakTabItem* dummyTabItem = [[OakTabItem alloc] initWithTitle:@"" path:nil identifier:identifier modified:NO];
			[tabItems addObject:dummyTabItem];
		}

		if(i == _tabItems.count)
			break;

		OakTabItem* tabItem = _tabItems[i];
		tabItem.tabView.overflowButtonVisible = NO;

		if(visibleCount >= countOfVisibleTabs || (_tabItems.count > countOfVisibleTabs && visibleCount+1 == countOfVisibleTabs && !tabItem.isSelected && !didIncludeSelected))
			continue;

		++visibleCount;
		didIncludeSelected = didIncludeSelected || tabItem.isSelected;

		if(i == _draggedTabIndex)
			continue;

		[tabItems addObject:tabItem];
	}

	NSMutableDictionary<NSString*, OakTabView*>* existingTabViews = [NSMutableDictionary dictionary];
	for(OakTabFrame* tabFrame in _currentLayout)
		existingTabViews[tabFrame.tabItem.identifier] = tabFrame.tabItem.tabView;

	for(OakTabItem* tabItem in tabItems)
	{
		if(!tabItem.tabView)
		{
			if(existingTabViews[tabItem.identifier])
			{
				tabItem.tabView = existingTabViews[tabItem.identifier];
				existingTabViews[tabItem.identifier] = nil;
			}
			else
			{
				OakTabView* tabView = [[OakTabView alloc] initWithFrame:NSZeroRect tabItem:tabItem parent:self];
				tabView.target       = self;
				tabView.action       = @selector(didSingleClickTabView:);
				tabView.doubleAction = @selector(didDoubleClickTabView:);
				tabView.dragAction   = @selector(didDragTabView:);

				tabItem.tabView = tabView;
				[self addSubview:tabView];
			}
		}

		if(tabItem.needsLayout)
		{
			tabItem.fittingWidth = self.isWindowTitleBar ? [tabItem.tabView preferredTitleBarWidth] : tabItem.tabView.fittingSize.width;
			tabItem.needsLayout = NO;
		}
	}

	if(_tabItems.count > countOfVisibleTabs)
		tabItems.lastObject.tabView.overflowButtonVisible = YES;

	NSArray<OakTabFrame*>* res = [self makeLayoutForTabItems:tabItems inRectOfWidth:visibleWidth];

	if(_freezeTabFramesLeftOfIndex > 0)
	{
		NSSet<NSString*>* frozenTabIdentifiers = [NSSet setWithArray:[[_tabItems subarrayWithRange:NSMakeRange(0, MIN(_freezeTabFramesLeftOfIndex, _tabItems.count))] valueForKeyPath:@"identifier"]];
		for(OakTabFrame* tabFrame in res)
		{
			if([frozenTabIdentifiers containsObject:tabFrame.tabItem.identifier])
			{
				if(OakTabView* tabView = tabFrame.tabItem.tabView)
				{
					if(NSWidth(tabView.frame) > 0)
						tabFrame.width = NSWidth(tabView.frame);
				}
			}
		}
	}

	return res;
}

- (void)updateToLayout:(NSArray<OakTabFrame*>*)newLayout
{
	if(NSAnimationContext.currentContext.allowsImplicitAnimation)
	{
		_fromLayout = _currentLayout;
		_toLayout   = newLayout;

		_tabLayoutAnimationProgressOffset = _tabLayoutAnimationProgress;
		self.animator.tabLayoutAnimationProgress = _tabLayoutAnimationProgress + 1;
	}
	else
	{
		_fromLayout = _toLayout = newLayout;
		self.currentLayout = [self interpolatedLayout:_fromLayout withFraction:1 ofLayout:_toLayout];
	}
}

- (void)setTabLayoutAnimationProgress:(CGFloat)newTabAnimationProgress
{
	if(_tabLayoutAnimationProgress == newTabAnimationProgress)
		return;
	_tabLayoutAnimationProgress = newTabAnimationProgress;
	self.currentLayout = [self interpolatedLayout:_fromLayout withFraction:(_tabLayoutAnimationProgress - _tabLayoutAnimationProgressOffset) ofLayout:_toLayout];
}

- (void)setCurrentLayout:(NSArray<OakTabFrame*>*)newLayout
{
	NSMutableDictionary<NSString*, OakTabView*>* existingTabViews = [NSMutableDictionary dictionary];
	for(OakTabFrame* tabFrame in _currentLayout)
		existingTabViews[tabFrame.tabItem.identifier] = tabFrame.tabItem.tabView;

	for(OakTabFrame* tabFrame in newLayout)
	{
		if(tabFrame.tabItem.tabView == existingTabViews[tabFrame.tabItem.identifier])
			existingTabViews[tabFrame.tabItem.identifier] = nil;
	}

	_currentLayout = newLayout;

	for(OakTabView* tabView in existingTabViews.allValues)
	{
		tabView.tabItem.tabView = nil;
		[tabView removeFromSuperview];
	}

	NSRect createNewTabButtonFrame = _createNewTabButton.frame;
	CGFloat y = NSMinY(self.bounds)+1, height = MAX(0, NSHeight(self.bounds)-1);
	CGFloat leading = MAX(0, self.leadingContentInset);

	CGFloat x = (leading > 0) ? leading : -1;
	for(OakTabFrame* tabFrame in _currentLayout)
	{
		OakTabView* tabView = tabFrame.tabItem.tabView;
		tabView.tabItem = tabFrame.tabItem;
		tabView.frame = NSMakeRect(x, y, tabFrame.width, height);
		x += tabFrame.width;
	}

	_createNewTabButton.frame = { { x, round((height - NSHeight(createNewTabButtonFrame)) / 2) }, createNewTabButtonFrame.size };
	if(!_statusTextLabel.hidden)
		_statusTextLabel.frame = NSMakeRect(NSWidth(self.bounds) - 8 - NSWidth(_statusTextLabel.frame), round((NSHeight(self.bounds) - NSHeight(_statusTextLabel.frame)) / 2), NSWidth(_statusTextLabel.frame), NSHeight(_statusTextLabel.frame));
	BOOL collapsed = _collapsedTitle && !_dragging;
	_createNewTabButton.hidden = collapsed;
	_collapsedTitleLabel.hidden = !collapsed;
	if(collapsed)
	{
		CGFloat margin = MAX(leading, _statusTextLabel.hidden ? 0 : NSWidth(_statusTextLabel.frame) + 16);
		_collapsedTitleLabel.frame = NSMakeRect(margin, floor((NSHeight(self.bounds) - 17) / 2), MAX(0, NSWidth(self.bounds) - 2 * margin), 17);
	}

	NSView* above = nil;
	for(OakTabFrame* tabFrame in _currentLayout)
	{
		[self addSubview:tabFrame.tabItem.tabView positioned:NSWindowAbove relativeTo:above];
		above = tabFrame.tabItem.tabView;
	}
	[self addSubview:_createNewTabButton positioned:NSWindowAbove relativeTo:above];
	[self addSubview:_statusTextLabel positioned:NSWindowAbove relativeTo:_createNewTabButton];
	if(self.isWindowTitleBar)
		self.needsDisplay = YES;
}

- (void)setFrameSize:(NSSize)newSize
{
	// Layout is frame-driven (makeLayout reads self.bounds), and under Auto
	// Layout superviews update our frame without calling
	// resizeSubviewsWithOldSize: — re-tab whenever the size actually changes.
	NSSize oldSize = self.bounds.size;
	[super setFrameSize:newSize];
	if(!NSEqualSizes(oldSize, newSize))
		[self updateToLayout:[self makeLayout]];
}
@end
