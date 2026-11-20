#import "ProjectLayoutView.h"
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <OakFoundation/OakFoundation.h>
#import <Preferences/Keys.h>
#import <oak/misc.h>
#import <oak/debug.h>

NSString* const kUserDefaultsFileBrowserWidthKey = @"fileBrowserWidth";
NSString* const kUserDefaultsHTMLOutputSizeKey   = @"htmlOutputSize";

static CGFloat const kMinimumProjectHeight = 72;
static CGFloat const kMinimumOutlineHeight = 48;
static CGFloat const kOutlineResizeEdgeHeight = 6;
static CGFloat const kOutlineResizeIndicatorHeight = 3;
static CGFloat const kSidebarChevronSize = 14;
static CGFloat const kSidebarTitleSpacing = 3;
static CGFloat const kSidebarCollapseThreshold = 100;

@interface ProjectSidebarBackgroundView : NSView
@property (nonatomic) NSColor* themeBackgroundColor;
@end

@implementation ProjectSidebarBackgroundView
- (void)setThemeBackgroundColor:(NSColor*)color
{
	_themeBackgroundColor = color;
	[self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect
{
	[(self.themeBackgroundColor ?: NSColor.controlBackgroundColor) setFill];
	// A window repaint can pass a rectangle larger than this view on macOS 14 and later.
	NSRectFill(NSIntersectionRect(dirtyRect, self.bounds));
}
@end

@interface ProjectOutlineResizeHandle : NSView
@property (nonatomic, weak) ProjectLayoutView* layoutView;
@property (nonatomic) NSTrackingArea* hoverArea;
@property (nonatomic) BOOL hovered;
@property (nonatomic) BOOL dragging;
@end

@interface ProjectLayoutView () <OakUserDefaultsObserver>
@property (nonatomic) NSView* sidebar;
@property (nonatomic) NSView* sidebarDivider;
@property (nonatomic) NSButton* fileBrowserHeader;
@property (nonatomic) NSButton* outlineHeader;
@property (nonatomic) ProjectOutlineResizeHandle* outlineResizeHandle;
@property (nonatomic) NSArray<NSLayoutConstraint*>* sidebarConstraints;
@property (nonatomic) NSLayoutConstraint* outlineHeightConstraint;
@property (nonatomic) NSView* htmlOutputDivider;
@property (nonatomic) NSLayoutConstraint* sidebarWidthConstraint;
@property (nonatomic) NSLayoutConstraint* htmlOutputSizeConstraint;
@property (nonatomic) NSMutableArray* myConstraints;
@property (nonatomic) BOOL mouseDownRecursionGuard;
- (void)trackOutlineResizeWithEvent:(NSEvent*)mouseDown;
- (BOOL)adjustOutlineHeightBy:(CGFloat)offset;
@end

@implementation ProjectOutlineResizeHandle
- (void)setHovered:(BOOL)hovered
{
	if(_hovered == hovered)
		return;
	_hovered = hovered;
	[self setNeedsDisplay:YES];
}

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if(!self.hoverArea)
	{
		self.hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
		[self addTrackingArea:self.hoverArea];
	}
}

- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	if(!self.window)
		self.hovered = NO;
}

- (void)mouseEntered:(NSEvent*)event { self.hovered = YES; }
- (void)mouseExited:(NSEvent*)event  { self.hovered = NO; }

- (void)drawRect:(NSRect)dirtyRect
{
	if(!self.hovered && !self.dragging)
		return;
	[NSColor.separatorColor setFill];
	NSRect bar = NSMakeRect(NSMinX(self.bounds), NSMinY(self.bounds), NSWidth(self.bounds), kOutlineResizeIndicatorHeight);
	NSRectFillUsingOperation(NSIntersectionRect(bar, dirtyRect), NSCompositingOperationSourceOver);
}

- (void)resetCursorRects
{
	[self addCursorRect:self.bounds cursor:NSCursor.resizeUpDownCursor];
}

- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)mouseDown:(NSEvent*)event
{
	self.dragging = YES;
	[self setNeedsDisplay:YES];
	[self.layoutView trackOutlineResizeWithEvent:event];
	self.dragging = NO;
	NSPoint point = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
	self.hovered = self.window.isKeyWindow && NSMouseInRect(point, self.bounds, self.isFlipped);
	[self setNeedsDisplay:YES];
}
@end

@implementation ProjectLayoutView
+ (void)initialize
{
	[NSUserDefaults.standardUserDefaults registerDefaults:@{
		kUserDefaultsFileBrowserWidthKey: @250,
		kUserDefaultsHTMLOutputSizeKey:   NSStringFromSize(NSMakeSize(200, 200))
	}];
}

- (id)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		_myConstraints     = [NSMutableArray array];
		_fileBrowserWidth  = [NSUserDefaults.standardUserDefaults integerForKey:kUserDefaultsFileBrowserWidthKey];
		_htmlOutputSize    = NSSizeFromString([NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsHTMLOutputSizeKey]);

		[self userDefaultsDidChange:nil];
		OakObserveUserDefaults(self);
	}
	return self;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)userDefaultsDidChange:(NSNotification*)aNotification
{
	self.htmlOutputOnRight = [[NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsHTMLOutputPlacementKey] isEqualToString:@"right"];
}

- (NSView*)replaceView:(NSView*)oldView withView:(NSView*)newView
{
	if(newView == oldView)
		return oldView;

	[oldView removeFromSuperview];
	if(newView)
		OakAddAutoLayoutViewsToSuperview(@[ newView ], self);

	[self setNeedsUpdateConstraints:YES];
	return newView;
}

- (void)updateKeyViewLoop
{
	NSMutableArray<NSView*>* views = [NSMutableArray array];
	for(NSView* view : { _documentView, _htmlOutputView, (NSView*)_fileBrowserHeader, _fileBrowserActionsView, _fileBrowserView, (NSView*)_outlineHeader, _outlineView })
	{
		if(view.superview)
			[views addObject:view];
	}
	OakSetupKeyViewLoop(views);
}

- (void)setDocumentView:(NSView*)aDocumentView       { _documentView = [self replaceView:_documentView withView:aDocumentView]; [self updateKeyViewLoop]; }

- (void)setSidebarThemeBackgroundColor:(NSColor*)color
{
	_sidebarThemeBackgroundColor = color;
	((ProjectSidebarBackgroundView*)_sidebar).themeBackgroundColor = color;
}

- (void)setSidebarThemeIsDark:(BOOL)dark
{
	_sidebarThemeIsDark = dark;
	_sidebar.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
}

- (NSView*)createDividerAlongYAxis:(BOOL)flag
{
	NSView* res = OakCreateNSBoxSeparator();
	res.translatesAutoresizingMaskIntoConstraints = NO;
	[res addConstraint:[NSLayoutConstraint constraintWithItem:res attribute:(flag ? NSLayoutAttributeWidth : NSLayoutAttributeHeight) relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:1]];
	[res addConstraint:[NSLayoutConstraint constraintWithItem:res attribute:(flag ? NSLayoutAttributeHeight : NSLayoutAttributeWidth) relatedBy:NSLayoutRelationGreaterThanOrEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:2]];
	return res;
}

- (void)setHtmlOutputView:(NSView*)aHtmlOutputView
{
	_htmlOutputDivider = [self replaceView:_htmlOutputDivider withView:(aHtmlOutputView ? [self createDividerAlongYAxis:_htmlOutputOnRight] : nil)];
	_htmlOutputView    = [self replaceView:_htmlOutputView withView:aHtmlOutputView];
	[self updateKeyViewLoop];
}

- (void)setOutlineView:(NSView*)anOutlineView
{
	if(_outlineView == anOutlineView)
		return;
	[_outlineView removeFromSuperview];
	_outlineView = anOutlineView;
	[self updateSidebar];
}

- (void)setFileBrowserView:(NSView*)aFileBrowserView
{
	if(_fileBrowserView == aFileBrowserView)
		return;
	[_fileBrowserView removeFromSuperview];
	_fileBrowserView = aFileBrowserView;
	[self updateSidebar];
}

- (void)setFileBrowserActionsView:(NSView*)actionsView
{
	if(_fileBrowserActionsView == actionsView)
		return;
	[_fileBrowserActionsView removeFromSuperview];
	_fileBrowserActionsView = actionsView;
	[self updateSidebar];
}

- (NSButton*)sidebarHeaderWithTitle:(NSString*)title action:(SEL)action
{
	NSButton* button = [NSButton buttonWithTitle:title target:self action:action];
	button.bordered = NO;
	button.alignment = NSTextAlignmentLeft;
	button.imagePosition = NSImageLeft;
	button.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
	button.accessibilityRole = NSAccessibilityDisclosureTriangleRole;
	button.accessibilityLabel = title;
	return button;
}

- (void)updateSidebarHeader:(NSButton*)header collapsed:(BOOL)collapsed
{
	static NSImage* const collapsedChevron = OakSidebarDisclosureImage(NO, kSidebarChevronSize, kSidebarTitleSpacing);
	static NSImage* const expandedChevron = OakSidebarDisclosureImage(YES, kSidebarChevronSize, kSidebarTitleSpacing);
	header.image = collapsed ? collapsedChevron : expandedChevron;
	header.accessibilityExpanded = !collapsed;
}

- (void)updateSidebar
{
	if(!_sidebar && (_fileBrowserView || _outlineView))
	{
		_sidebar = [[ProjectSidebarBackgroundView alloc] initWithFrame:NSZeroRect];
		((ProjectSidebarBackgroundView*)_sidebar).themeBackgroundColor = _sidebarThemeBackgroundColor;
		_sidebar.appearance = [NSAppearance appearanceNamed:_sidebarThemeIsDark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
		_sidebar.clipsToBounds = YES;
		_sidebarWidthConstraint = [_sidebar.widthAnchor constraintEqualToConstant:_fileBrowserWidth];
		_sidebarWidthConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow;
		_fileBrowserHeader = [self sidebarHeaderWithTitle:@"Project" action:@selector(toggleFileBrowserCollapsed:)];
		_outlineHeader = [self sidebarHeaderWithTitle:@"Outline" action:@selector(toggleOutlineCollapsed:)];
		_outlineResizeHandle = [[ProjectOutlineResizeHandle alloc] initWithFrame:NSZeroRect];
		_outlineResizeHandle.layoutView = self;
		_outlineResizeHandle.translatesAutoresizingMaskIntoConstraints = NO;
		_outlineResizeHandle.wantsLayer = YES;
	}

	BOOL visible = _fileBrowserView || _outlineView;
	if(visible != (_sidebar.superview != nil))
	{
		if(visible)
		{
			_sidebarWidthConstraint.constant = _fileBrowserWidth;
			_sidebarWidthConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow;
			_sidebar.alphaValue = 1;
		}
		[self replaceView:visible ? nil : _sidebar withView:visible ? _sidebar : nil];
		_sidebarDivider = [self replaceView:_sidebarDivider withView:visible ? [self createDividerAlongYAxis:YES] : nil];
	}

	[NSLayoutConstraint deactivateConstraints:_sidebarConstraints ?: @[]];
	_outlineHeightConstraint = nil;
	[self updateSidebarHeader:_fileBrowserHeader collapsed:_fileBrowserCollapsed];
	[self updateSidebarHeader:_outlineHeader collapsed:_outlineCollapsed];

	BOOL projectExpanded = _fileBrowserView && !_fileBrowserCollapsed;
	BOOL outlineExpanded = _outlineView && !_outlineCollapsed;
	NSView* projectActions = projectExpanded ? _fileBrowserActionsView : nil;
	NSView* resizeHandle = projectExpanded && outlineExpanded ? _outlineResizeHandle : nil;
	if(resizeHandle && !_outlineResizeHandle.superview)
	{
		__weak ProjectLayoutView* layoutView = self;
		_outlineHeader.accessibilityCustomActions = @[
			[[NSAccessibilityCustomAction alloc] initWithName:@"Increase Outline Height" handler:^BOOL{ return [layoutView adjustOutlineHeightBy:16]; }],
			[[NSAccessibilityCustomAction alloc] initWithName:@"Decrease Outline Height" handler:^BOOL{ return [layoutView adjustOutlineHeightBy:-16]; }],
		];
	}
	else if(!resizeHandle)
		_outlineHeader.accessibilityCustomActions = nil;
	NSMutableArray<NSView*>* rows = [NSMutableArray array];
	if(_fileBrowserView)
	{
		[rows addObject:_fileBrowserHeader];
		if(projectExpanded)
			[rows addObject:_fileBrowserView];
	}
	if(_outlineView)
	{
		[rows addObject:_outlineHeader];
		if(outlineExpanded)
			[rows addObject:_outlineView];
	}

	for(NSView* view in _sidebar.subviews)
	{
		if(view != projectActions && view != resizeHandle && ![rows containsObject:view])
		{
			NSResponder* responder = self.window.firstResponder;
			if([responder isKindOfClass:NSView.class] && [(NSView*)responder isDescendantOf:view])
			{
				NSButton* header = view == _fileBrowserView || (view == _fileBrowserActionsView && _fileBrowserView) ? _fileBrowserHeader : view == _outlineView ? _outlineHeader : nil;
				[self.window makeFirstResponder:header];
			}
			[view removeFromSuperview];
		}
	}

	NSMutableArray<NSLayoutConstraint*>* constraints = [NSMutableArray array];
	NSLayoutYAxisAnchor* top = _sidebar.topAnchor;
	for(NSView* row in rows)
	{
		if(row.superview != _sidebar)
			OakAddAutoLayoutViewsToSuperview(@[ row ], _sidebar);

		BOOL isHeader = row == _fileBrowserHeader || row == _outlineHeader;
		BOOL hasActions = row == _fileBrowserHeader && projectActions;
		if(hasActions && projectActions.superview != _sidebar)
			OakAddAutoLayoutViewsToSuperview(@[ projectActions ], _sidebar);
		NSLayoutConstraint* height = isHeader ? [row.heightAnchor constraintEqualToConstant:28] : [row.heightAnchor constraintGreaterThanOrEqualToConstant:0];
		NSLayoutConstraint* trailing = [row.trailingAnchor constraintEqualToAnchor:hasActions ? projectActions.leadingAnchor : _sidebar.trailingAnchor constant:hasActions ? -4 : 0];
		trailing.priority = NSLayoutPriorityRequired - 2;
		[constraints addObjectsFromArray:@[
			[row.leadingAnchor constraintEqualToAnchor:_sidebar.leadingAnchor constant:isHeader ? kOakSidebarDisclosureCenter - kSidebarChevronSize / 2 : 0],
			trailing,
			[row.topAnchor constraintEqualToAnchor:top],
			[row.widthAnchor constraintGreaterThanOrEqualToConstant:0],
			height,
		]];
		if(hasActions)
		{
			[constraints addObjectsFromArray:@[
				[projectActions.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
				[projectActions.trailingAnchor constraintEqualToAnchor:_sidebar.trailingAnchor constant:-6],
			]];
		}
		top = row.bottomAnchor;
	}

	if(projectExpanded || outlineExpanded)
		[constraints addObject:[top constraintEqualToAnchor:_sidebar.bottomAnchor]];
	if(projectExpanded && outlineExpanded)
	{
		// Overlay the bottom of Project so the resize target never covers the Outline title.
		if(_sidebar.subviews.lastObject != resizeHandle)
			[_sidebar addSubview:resizeHandle positioned:NSWindowAbove relativeTo:nil];
		[constraints addObjectsFromArray:@[
			[resizeHandle.leadingAnchor constraintEqualToAnchor:_sidebar.leadingAnchor],
			[resizeHandle.trailingAnchor constraintEqualToAnchor:_sidebar.trailingAnchor],
			[resizeHandle.bottomAnchor constraintEqualToAnchor:_outlineHeader.topAnchor],
			[resizeHandle.heightAnchor constraintEqualToConstant:kOutlineResizeEdgeHeight],
		]];
		NSLayoutConstraint* projectMinimum = [_fileBrowserView.heightAnchor constraintGreaterThanOrEqualToConstant:kMinimumProjectHeight];
		NSLayoutConstraint* outlineMinimum = [_outlineView.heightAnchor constraintGreaterThanOrEqualToConstant:kMinimumOutlineHeight];
		projectMinimum.priority = outlineMinimum.priority = NSLayoutPriorityDefaultHigh + 1;
		_outlineHeightConstraint = _outlineHeight > 0 ? [_outlineView.heightAnchor constraintEqualToConstant:_outlineHeight]
			: [_outlineView.heightAnchor constraintEqualToAnchor:_fileBrowserView.heightAnchor multiplier:0.5];
		_outlineHeightConstraint.priority = NSLayoutPriorityDefaultHigh;
		[constraints addObjectsFromArray:@[ projectMinimum, outlineMinimum, _outlineHeightConstraint ]];
	}

	_sidebarConstraints = constraints;
	[NSLayoutConstraint activateConstraints:_sidebarConstraints];
	[self updateKeyViewLoop];
}

- (void)setFileBrowserCollapsed:(BOOL)collapsed
{
	if(_fileBrowserCollapsed == collapsed)
		return;
	_fileBrowserCollapsed = collapsed;
	[self updateSidebar];
	if(self.sidebarStateDidChange)
		self.sidebarStateDidChange(self);
}

- (void)setOutlineCollapsed:(BOOL)collapsed
{
	if(_outlineCollapsed == collapsed)
		return;
	_outlineCollapsed = collapsed;
	[self updateSidebar];
	if(self.sidebarStateDidChange)
		self.sidebarStateDidChange(self);
}

- (void)setOutlineHeight:(CGFloat)height
{
	CGFloat newHeight = std::isfinite(height) && height > 0 ? height : 0;
	if(_outlineHeight == newHeight)
		return;
	BOOL usesAutomaticHeight = _outlineHeight == 0 || newHeight == 0;
	_outlineHeight = newHeight;
	if(_outlineHeightConstraint && usesAutomaticHeight)
		[self updateSidebar];
	else
		_outlineHeightConstraint.constant = newHeight;
}

- (BOOL)applyOutlineHeight:(CGFloat)height
{
	if(!_outlineResizeHandle.superview)
		return NO;
	CGFloat currentHeight = NSHeight(_outlineView.frame);
	CGFloat availableHeight = NSHeight(_fileBrowserView.frame) + currentHeight;
	if(availableHeight <= kMinimumProjectHeight + kMinimumOutlineHeight)
		return NO;
	CGFloat clampedHeight = std::clamp(round(height), kMinimumOutlineHeight, availableHeight - kMinimumProjectHeight);
	if(clampedHeight == currentHeight)
		return NO;
	self.outlineHeight = clampedHeight;
	[self layoutSubtreeIfNeeded];
	return YES;
}

- (BOOL)adjustOutlineHeightBy:(CGFloat)offset
{
	if(![self applyOutlineHeight:NSHeight(_outlineView.frame) + offset])
		return NO;
	if(self.sidebarStateDidChange)
		self.sidebarStateDidChange(self);
	return YES;
}

- (void)trackOutlineResizeWithEvent:(NSEvent*)mouseDown
{
	CGFloat initialHeight = NSHeight(_outlineView.frame);
	CGFloat startY = mouseDown.locationInWindow.y;
	__block BOOL didResize = NO;
	[self.window trackEventsMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp timeout:NSEventDurationForever mode:NSEventTrackingRunLoopMode handler:^(NSEvent* event, BOOL* stop){
		*stop = event.type == NSEventTypeLeftMouseUp;
		if(!*stop && [self applyOutlineHeight:initialHeight + event.locationInWindow.y - startY])
			didResize = YES;
	}];
	if(didResize && self.sidebarStateDidChange)
		self.sidebarStateDidChange(self);
}

- (IBAction)toggleFileBrowserCollapsed:(id)sender
{
	self.fileBrowserCollapsed = !self.fileBrowserCollapsed;
}

- (IBAction)toggleOutlineCollapsed:(id)sender
{
	self.outlineCollapsed = !self.outlineCollapsed;
}

- (void)setFileBrowserWidth:(CGFloat)width
{
	_fileBrowserWidth = width;
	_sidebarWidthConstraint.constant = width;
}

- (CGFloat)visibleSidebarWidth { return NSWidth(_sidebar.frame); }
- (CGFloat)sidebarOpacity      { return _sidebar.alphaValue; }

- (void)setSidebarTransitionWidth:(CGFloat)width opacity:(CGFloat)opacity
{
	_sidebarWidthConstraint.priority = NSLayoutPriorityRequired - 1;
	_sidebarWidthConstraint.constant = width;
	BOOL resizeAvailabilityChanged = (_sidebar.alphaValue == 1) != (opacity == 1);
	_sidebar.alphaValue = _sidebarDivider.alphaValue = opacity;
	if(resizeAvailabilityChanged)
		[self.window invalidateCursorRectsForView:self];
}

- (void)setFileBrowserOnRight:(BOOL)flag
{
	if(_fileBrowserOnRight != flag)
	{
		_fileBrowserOnRight = flag;
		if(_sidebar.superview)
			[self setNeedsUpdateConstraints:YES];
	}
}

- (void)setHtmlOutputOnRight:(BOOL)flag
{
	if(_htmlOutputOnRight != flag)
	{
		_htmlOutputOnRight = flag;
		self.htmlOutputView = _htmlOutputView; // recreate divider line, required due to <rdar://13093498>
	}
}

#ifndef CONSTRAINT
#define CONSTRAINT(str, align) [_myConstraints addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:str options:align metrics:nil views:views]]
#endif

- (void)updateConstraints
{
	[self removeConstraints:_myConstraints];
	[_myConstraints removeAllObjects];
	[super updateConstraints];

	NSDictionary* views = @{
		@"documentView":       _documentView,
		@"sidebar":            _sidebar.superview ? _sidebar : (id)[NSNull null],
		@"sidebarDivider":     _sidebarDivider      ?: [NSNull null],
		@"htmlOutputView":     _htmlOutputView      ?: [NSNull null],
		@"htmlOutputDivider":  _htmlOutputDivider   ?: [NSNull null],
	};

	// ========================
	// = Anchor Document View =
	// ========================

	// top
	CONSTRAINT(@"V:|[documentView]", 0);

	// bottom
	if(_htmlOutputView && !_htmlOutputOnRight)
		CONSTRAINT(@"V:[documentView][htmlOutputDivider]", 0);
	else
		CONSTRAINT(@"V:[documentView]|", 0);

	// ==================
	// = Horizontal rows =
	// ==================
	NSMutableString* format = [NSMutableString stringWithString:@"H:|"];
	if(_sidebar.superview && !_fileBrowserOnRight)
		[format appendString:@"[sidebar][sidebarDivider]"];
	[format appendString:@"[documentView]"];
	if(_htmlOutputView && _htmlOutputOnRight)
		[format appendString:@"[htmlOutputDivider][htmlOutputView]"];
	if(_sidebar.superview && _fileBrowserOnRight)
		[format appendString:@"[sidebarDivider][sidebar]"];
	[format appendString:@"|"];
	CONSTRAINT(format, 0);

	if(_sidebar.superview)
	{
		[_myConstraints addObject:self.sidebarWidthConstraint];

		// top
		CONSTRAINT(@"V:|[sidebarDivider]", 0);
		CONSTRAINT(@"V:|[sidebar]", 0);

		// bottom
		if(_htmlOutputView && !_htmlOutputOnRight)
		{
			CONSTRAINT(@"V:[sidebar][htmlOutputDivider]", 0);
			CONSTRAINT(@"V:[sidebarDivider][htmlOutputDivider]", 0);
		}
		else
		{
			CONSTRAINT(@"V:[sidebar]|", 0);
			CONSTRAINT(@"V:[sidebarDivider]|", 0);
		}
	}

	// ===========================
	// = Anchor HTML Output View =
	// ===========================

	if(_htmlOutputView)
	{
		// size (either width or height)
		self.htmlOutputSizeConstraint = _htmlOutputOnRight ? [NSLayoutConstraint constraintWithItem:_htmlOutputView attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:_htmlOutputSize.width] : [NSLayoutConstraint constraintWithItem:_htmlOutputView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:_htmlOutputSize.height];
		self.htmlOutputSizeConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow-1;
		[_myConstraints addObject:self.htmlOutputSizeConstraint];

		if(_htmlOutputOnRight)
		{
			// top + bottom
			CONSTRAINT(@"V:|[htmlOutputView]|", 0);
			CONSTRAINT(@"V:|[htmlOutputDivider]|", 0);
		}
		else
		{
			// top + bottom
			CONSTRAINT(@"V:[documentView][htmlOutputDivider][htmlOutputView]|", 0);

			// left + right
			CONSTRAINT(@"H:|[htmlOutputView]|", 0);
			CONSTRAINT(@"H:|[htmlOutputDivider]|", 0);
		}
	}

	[self addConstraints:_myConstraints];
	[[self window] invalidateCursorRectsForView:self];
}

#undef CONSTRAINT

- (NSRect)sidebarResizeRect
{
	if(!_sidebar.superview || _sidebar.alphaValue < 1)
		return NSZeroRect;
	NSRect r = _sidebar.frame;
	return NSMakeRect(_fileBrowserOnRight ? NSMinX(r)-3 : NSMaxX(r)-4, NSMinY(r), 10, NSHeight(r));
}

- (NSRect)htmlOutputResizeRect
{
	if(!_htmlOutputView)
		return NSZeroRect;
	NSRect r = _htmlOutputView.frame;
	return _htmlOutputOnRight ? NSMakeRect(NSMinX(r)-3, NSMinY(r), 10, NSHeight(r)) : NSMakeRect(NSMinX(r), NSMaxY(r)-4, NSWidth(r), 10);
}

- (void)resetCursorRects
{
	[self addCursorRect:[self sidebarResizeRect] cursor:[NSCursor resizeLeftRightCursor]];
	[self addCursorRect:[self htmlOutputResizeRect]  cursor:_htmlOutputOnRight ? [NSCursor resizeLeftRightCursor] : [NSCursor resizeUpDownCursor]];
}

- (BOOL)mouseDownCanMoveWindow
{
	return NO;
}

- (NSView*)hitTest:(NSPoint)aPoint
{
	if(NSMouseInRect([self convertPoint:aPoint fromView:[self superview]], [self sidebarResizeRect], [self isFlipped]))
		return self;
	if(NSMouseInRect([self convertPoint:aPoint fromView:[self superview]], [self htmlOutputResizeRect], [self isFlipped]))
		return self;
	return [super hitTest:aPoint];
}

- (void)mouseDown:(NSEvent*)anEvent
{
	if(_mouseDownRecursionGuard)
		return;
	_mouseDownRecursionGuard = YES;

	NSView* view = nil;
	NSPoint mouseDownPos = [self convertPoint:[anEvent locationInWindow] fromView:nil];
	if(NSMouseInRect(mouseDownPos, [self sidebarResizeRect], [self isFlipped]))
		view = _sidebar;
	else if(NSMouseInRect(mouseDownPos, [self htmlOutputResizeRect], [self isFlipped]))
		view = _htmlOutputView;

	if(!view || [anEvent type] != NSEventTypeLeftMouseDown)
	{
		[super mouseDown:anEvent];
	}
	else
	{
		if(_sidebar.superview)
		{
			self.sidebarWidthConstraint.constant = NSWidth(_sidebar.frame);
			self.sidebarWidthConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow;
		}

		if(_htmlOutputView)
		{
			if(_htmlOutputOnRight)
					self.htmlOutputSizeConstraint.constant = NSWidth(_htmlOutputView.frame);
			else	self.htmlOutputSizeConstraint.constant = NSHeight(_htmlOutputView.frame);
			self.htmlOutputSizeConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow;
		}

		NSEvent* mouseDownEvent = anEvent;
		NSRect initialFrame = view.frame;

		BOOL didDrag = NO;
		BOOL collapseSidebar = NO;
		CGFloat draggedSidebarWidth = _fileBrowserWidth;
		while([anEvent type] != NSEventTypeLeftMouseUp)
		{
			anEvent = [NSApp nextEventMatchingMask:(NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseDown|NSEventMaskLeftMouseUp) untilDate:[NSDate distantFuture] inMode:NSEventTrackingRunLoopMode dequeue:YES];
			if([anEvent type] != NSEventTypeLeftMouseDragged)
				break;

			NSPoint mouseCurrentPos = [self convertPoint:[anEvent locationInWindow] fromView:nil];
			if(!didDrag && hypot(mouseDownPos.x - mouseCurrentPos.x, mouseDownPos.y - mouseCurrentPos.y) < 2.5)
				continue;

			if(view == _htmlOutputView)
			{
				if(_htmlOutputOnRight)
				{
					CGFloat width = NSWidth(initialFrame) + (mouseCurrentPos.x - mouseDownPos.x) * (_htmlOutputOnRight ? -1 : +1);
					_htmlOutputSize.width = std::max<CGFloat>(50, round(width));
					self.htmlOutputSizeConstraint.constant = width;
				}
				else
				{
					CGFloat height = NSHeight(initialFrame) + (mouseCurrentPos.y - mouseDownPos.y);
					_htmlOutputSize.height = std::max<CGFloat>(50, round(height));
					self.htmlOutputSizeConstraint.constant = height;
				}
				self.htmlOutputSizeConstraint.priority   = NSLayoutPriorityDragThatCannotResizeWindow-1;

				[NSUserDefaults.standardUserDefaults setObject:NSStringFromSize(_htmlOutputSize) forKey:kUserDefaultsHTMLOutputSizeKey];
			}
			else if(view == _sidebar)
			{
				CGFloat width = NSWidth(initialFrame) + (mouseCurrentPos.x - mouseDownPos.x) * (_fileBrowserOnRight ? -1 : +1);
				collapseSidebar = width < kSidebarCollapseThreshold;
				draggedSidebarWidth = MAX(kSidebarCollapseThreshold, round(width));
				self.sidebarWidthConstraint.constant = draggedSidebarWidth;
				self.sidebarWidthConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow-1;
			}

			[[self window] invalidateCursorRectsForView:self];
			didDrag = YES;
		}

		if(!didDrag)
		{
			NSView* view = [super hitTest:[[self superview] convertPoint:[mouseDownEvent locationInWindow] fromView:nil]];
			if(view && view != self)
			{
				[NSApp postEvent:anEvent atStart:NO];
				[view mouseDown:mouseDownEvent];
			}
		}

		self.sidebarWidthConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow;
		self.htmlOutputSizeConstraint.priority   = NSLayoutPriorityDragThatCannotResizeWindow-1;
		if(didDrag && view == _sidebar)
		{
			if(collapseSidebar)
			{
				if(self.sidebarDidRequestClose)
					self.sidebarDidRequestClose();
				else
					self.sidebarWidthConstraint.constant = _fileBrowserWidth;
			}
			else
			{
				self.fileBrowserWidth = draggedSidebarWidth;
				[NSUserDefaults.standardUserDefaults setInteger:_fileBrowserWidth forKey:kUserDefaultsFileBrowserWidthKey];
			}
		}
	}

	_mouseDownRecursionGuard = NO;
}

- (void)performClose:(id)sender
{
	NSView* view = (NSView*)[[self window] firstResponder];
	if([view isKindOfClass:[NSView class]] && [view isDescendantOf:_htmlOutputView])
		[NSApp sendAction:@selector(performCloseSplit:) to:nil from:_htmlOutputView];
	else if([self.window.delegate respondsToSelector:@selector(performClose:)])
		[self.window.delegate performSelector:@selector(performClose:) withObject:sender];
	else
		NSBeep();
}
@end
