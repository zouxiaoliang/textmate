#import "FloatingPanel.h"
#import <QuartzCore/QuartzCore.h>

static constexpr CGFloat AttractionDistance = 52;
static constexpr CGFloat SnapDistance = 18;
static constexpr CGFloat ReleaseDistance = 34;
static constexpr CGFloat EdgeThickness = 8;
static constexpr CGFloat EdgeLength = 88;
static constexpr NSTimeInterval GenieDuration = 0.28;

enum class RunOutputEdge { None, Left, Right, Bottom, Top };

static NSRect ConstrainOutputFrame(NSRect frame, NSRect bounds)
{
	frame.size.width = MIN(NSWidth(frame), NSWidth(bounds));
	frame.size.height = MIN(NSHeight(frame), NSHeight(bounds));
	frame.origin.x = MAX(NSMinX(bounds), MIN(NSMinX(frame), NSMaxX(bounds) - NSWidth(frame)));
	frame.origin.y = MAX(NSMinY(bounds), MIN(NSMinY(frame), NSMaxY(bounds) - NSHeight(frame)));
	return frame;
}

static CGFloat OutputEdgeGap(NSRect frame, NSRect bounds, RunOutputEdge edge)
{
	switch(edge)
	{
		case RunOutputEdge::Left:   return NSMinX(frame) - NSMinX(bounds);
		case RunOutputEdge::Right:  return NSMaxX(bounds) - NSMaxX(frame);
		case RunOutputEdge::Bottom: return NSMinY(frame) - NSMinY(bounds);
		case RunOutputEdge::Top:    return NSMaxY(bounds) - NSMaxY(frame);
		case RunOutputEdge::None:   return 0;
	}
}

static RunOutputEdge OutputEdgeNearFrame(NSRect frame, NSRect bounds, CGFloat distance, RunOutputEdge ignored, NSRect const* previous = nullptr)
{
	RunOutputEdge closest = RunOutputEdge::None;
	static constexpr RunOutputEdge edges[] = { RunOutputEdge::Left, RunOutputEdge::Right, RunOutputEdge::Bottom, RunOutputEdge::Top };
	for(RunOutputEdge edge : edges)
	{
		if(edge == ignored)
			continue;
		CGFloat signedGap = OutputEdgeGap(frame, bounds, edge);
		if(!previous && signedGap < 0)
			continue;
		CGFloat gap = signedGap < 0 && previous && OutputEdgeGap(*previous, bounds, edge) > 0 ? 0 : fabs(signedGap);
		if(gap < distance)
		{
			closest = edge;
			distance = gap;
		}
	}
	return closest;
}

static RunOutputEdge OutputArrivalEdge(NSRect from, NSRect to)
{
	if(NSIsEmptyRect(from) || NSIsEmptyRect(to))
		return RunOutputEdge::None;
	if(NSMaxX(from) <= NSMinX(to))
		return RunOutputEdge::Left;
	if(NSMinX(from) >= NSMaxX(to))
		return RunOutputEdge::Right;
	if(NSMaxY(from) <= NSMinY(to))
		return RunOutputEdge::Bottom;
	if(NSMinY(from) >= NSMaxY(to))
		return RunOutputEdge::Top;
	return RunOutputEdge::None;
}

static NSPoint OutputOriginAtEdge(NSRect frame, NSRect bounds, RunOutputEdge edge, CGFloat gap = 0)
{
	NSPoint origin = frame.origin;
	switch(edge)
	{
		case RunOutputEdge::Left:   origin.x = NSMinX(bounds) + gap; break;
		case RunOutputEdge::Right:  origin.x = NSMaxX(bounds) - NSWidth(frame) - gap; break;
		case RunOutputEdge::Bottom: origin.y = NSMinY(bounds) + gap; break;
		case RunOutputEdge::Top:    origin.y = NSMaxY(bounds) - NSHeight(frame) - gap; break;
		case RunOutputEdge::None:   break;
	}
	return origin;
}

static NSRect OutputFrameAtEdge(NSRect frame, NSRect bounds, RunOutputEdge edge)
{
	frame = ConstrainOutputFrame(frame, bounds);
	frame.origin = OutputOriginAtEdge(frame, bounds, edge);
	return frame;
}

static NSRect OutputGripFrame(NSRect frame, RunOutputEdge edge)
{
	if(edge == RunOutputEdge::Left || edge == RunOutputEdge::Right)
	{
		CGFloat length = MIN(EdgeLength, NSHeight(frame));
		return NSMakeRect(edge == RunOutputEdge::Left ? NSMinX(frame) : NSMaxX(frame) - EdgeThickness,
		                  NSMidY(frame) - length / 2, EdgeThickness, length);
	}
	CGFloat length = MIN(EdgeLength, NSWidth(frame));
	return NSMakeRect(NSMidX(frame) - length / 2, edge == RunOutputEdge::Bottom ? NSMinY(frame) : NSMaxY(frame) - EdgeThickness,
	                  length, EdgeThickness);
}

static NSScreen* OutputScreenAtPoint(NSPoint point)
{
	for(NSScreen* screen in NSScreen.screens)
	{
		if(NSPointInRect(point, screen.frame))
			return screen;
	}
	return nil;
}

static NSNumber* OutputScreenNumber(NSScreen* screen)
{
	return screen.deviceDescription[@"NSScreenNumber"];
}

@interface RunOutputWindow : NSPanel
@property (nonatomic, copy) void (^dismissHandler)(void);
@end

@implementation RunOutputWindow
- (BOOL)canBecomeKeyWindow { return (self.styleMask & NSWindowStyleMaskResizable) != 0; }
- (BOOL)canBecomeMainWindow { return NO; }
- (void)cancelOperation:(id)sender { if(self.dismissHandler) self.dismissHandler(); }
@end

@interface RunOutputTrackingView : NSView
@property (nonatomic) NSTrackingArea* trackingArea;
@property (nonatomic, copy) void (^pointerHandler)(NSPoint);
@property (nonatomic, copy) void (^pressHandler)(void);
@end

@implementation RunOutputTrackingView
- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if(self.trackingArea)
		[self removeTrackingArea:self.trackingArea];
	self.trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
	[self addTrackingArea:self.trackingArea];
}
- (void)mouseEntered:(NSEvent*)event { if(self.pointerHandler) self.pointerHandler(NSEvent.mouseLocation); }
- (void)mouseExited:(NSEvent*)event { if(self.pointerHandler) self.pointerHandler(NSEvent.mouseLocation); }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return self.pressHandler != nil; }
- (void)mouseDown:(NSEvent*)event
{
	if(self.pressHandler)
		self.pressHandler();
	else
		[super mouseDown:event];
}
- (BOOL)accessibilityPerformPress
{
	if(!self.pressHandler)
		return NO;
	self.pressHandler();
	return YES;
}
- (void)resetCursorRects
{
	if(self.pressHandler)
		[self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}
- (void)drawRect:(NSRect)dirtyRect
{
	if(!self.pressHandler)
		return;
	[[NSColor.windowBackgroundColor colorWithAlphaComponent:0.96] setFill];
	[[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:4 yRadius:4] fill];
	NSRect mark = NSWidth(self.bounds) > NSHeight(self.bounds) ? NSInsetRect(self.bounds, 22, 3) : NSInsetRect(self.bounds, 3, 22);
	[NSColor.secondaryLabelColor setFill];
	[[NSBezierPath bezierPathWithRoundedRect:mark xRadius:1 yRadius:1] fill];
}
@end

@interface RunOutputMagnetIndicator : NSView
@end

@implementation RunOutputMagnetIndicator
- (NSView*)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)dirtyRect
{
	[NSColor.controlAccentColor setFill];
	[[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:1.5 yRadius:1.5] fill];
}
@end

@interface RunOutputGenieView : NSView
- (instancetype)initWithView:(NSView*)view grip:(NSRect)grip edge:(RunOutputEdge)edge;
- (void)animateFrom:(CGFloat)from to:(CGFloat)to atTime:(CFTimeInterval)time duration:(NSTimeInterval)duration;
- (void)clearAnimation;
@end

static CGFloat AnimateGenieTrack(CALayer* layer, NSString* path, CGFloat from, CGFloat to, CFTimeInterval time, NSTimeInterval duration, CGFloat (^value)(CGFloat))
{
	static constexpr NSUInteger SampleCount = 17;
	NSMutableArray<NSNumber*>* values = [NSMutableArray arrayWithCapacity:SampleCount];
	for(NSUInteger index = 0; index < SampleCount; ++index)
	{
		CGFloat progress = from + (to - from) * index / (SampleCount - 1);
		[values addObject:@(value(progress * progress * (3 - 2 * progress)))];
	}
	CAKeyframeAnimation* animation = [CAKeyframeAnimation animationWithKeyPath:path];
	animation.values = values;
	animation.beginTime = [layer convertTime:time fromLayer:nil];
	animation.duration = duration;
	animation.fillMode = kCAFillModeBackwards;
	[layer addAnimation:animation forKey:@"genie"];
	return values.lastObject.doubleValue;
}

@implementation RunOutputGenieView
{
	CALayer* _mesh;
	CGFloat _depthRatio;
	CGFloat _spanRatio;
	BOOL _horizontal;
	BOOL _reverse;
}

- (instancetype)initWithView:(NSView*)view grip:(NSRect)grip edge:(RunOutputEdge)edge
{
	NSRect bounds = view.bounds;
	if(NSIsEmptyRect(bounds))
		return nil;
	[view layoutSubtreeIfNeeded];
	NSBitmapImageRep* snapshot = [view bitmapImageRepForCachingDisplayInRect:bounds];
	if(!snapshot)
		return nil;
	[view cacheDisplayInRect:bounds toBitmapImageRep:snapshot];
	CGImageRef image = snapshot.CGImage;
	if(!image)
		return nil;

	CGRect pixels = CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image));
	CGColorSpaceRef colors = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef composite = CGBitmapContextCreate(nullptr, pixels.size.width, pixels.size.height, 8, 0, colors, kCGImageAlphaPremultipliedLast);
	CGColorSpaceRelease(colors);
	if(!composite)
		return nil;
	[view.effectiveAppearance performAsCurrentDrawingAppearance:^{
		CGContextSetFillColorWithColor(composite, NSColor.windowBackgroundColor.CGColor);
	}];
	CGPathRef mask = CGPathCreateWithRoundedRect(pixels, 8 * pixels.size.width / NSWidth(bounds), 8 * pixels.size.height / NSHeight(bounds), nullptr);
	CGContextAddPath(composite, mask);
	CGPathRelease(mask);
	CGContextClip(composite);
	CGContextFillRect(composite, pixels);
	CGContextDrawImage(composite, pixels, image);
	CGImageRef texture = CGBitmapContextCreateImage(composite);
	CGContextRelease(composite);
	if(!texture)
		return nil;

	self = [super initWithFrame:NSMakeRect(0, 0, NSWidth(bounds), NSHeight(bounds))];
	if(!self)
	{
		CGImageRelease(texture);
		return nil;
	}

	_horizontal = edge == RunOutputEdge::Left || edge == RunOutputEdge::Right;
	_reverse = edge == RunOutputEdge::Right || edge == RunOutputEdge::Top;
	CGFloat depth = _horizontal ? NSWidth(bounds) : NSHeight(bounds);
	CGFloat span = _horizontal ? NSHeight(bounds) : NSWidth(bounds);
	_depthRatio = (_horizontal ? NSWidth(grip) : NSHeight(grip)) / depth;
	_spanRatio = (_horizontal ? NSHeight(grip) : NSWidth(grip)) / span;

	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	self.layer = [CALayer layer];
	self.wantsLayer = YES;
	_mesh = [CALayer layer];
	CGFloat anchor = _reverse ? 1 : 0;
	_mesh.anchorPoint = _horizontal ? CGPointMake(anchor, 0.5) : CGPointMake(0.5, anchor);
	_mesh.frame = self.bounds;
	[self.layer addSublayer:_mesh];

	NSUInteger length = _horizontal ? pixels.size.width : pixels.size.height;
	NSUInteger count = MIN(length, 72UL);
	CGFloat scale = length / depth;
	for(NSUInteger index = 0; index < count; ++index)
	{
		NSUInteger first = index * length / count;
		NSUInteger last = (index + 1) * length / count;
		CGFloat origin = _reverse ? length - last : first;
		CGFloat width = last - first;
		CALayer* strip = [CALayer layer];
		strip.contents = (__bridge id)texture;
		strip.contentsScale = scale;
		strip.contentsRect = _horizontal ? CGRectMake(origin / length, 0, width / length, 1) : CGRectMake(0, origin / length, 1, width / length);
		strip.allowsEdgeAntialiasing = NO;
		CGFloat start = origin / scale;
		CGFloat thickness = width / scale;
		strip.frame = _horizontal ? CGRectMake(start, 0, thickness, span) : CGRectMake(0, start, span, thickness);
		[_mesh addSublayer:strip];
	}
	[CATransaction commit];
	CGImageRelease(texture);
	return self;
}

- (void)animateFrom:(CGFloat)from to:(CGFloat)to atTime:(CFTimeInterval)time duration:(NSTimeInterval)duration
{
	CGFloat depthRatio = _depthRatio;
	CGFloat spanRatio = _spanRatio;
	self.layer.opacity = AnimateGenieTrack(self.layer, @"opacity", from, to, time, duration, ^CGFloat(CGFloat progress){
		return MIN(1, (1 - progress) * 5);
	});
	CGFloat depthScale = AnimateGenieTrack(_mesh, _horizontal ? @"transform.scale.x" : @"transform.scale.y", from, to, time, duration, ^CGFloat(CGFloat progress){
		return 1 + (depthRatio - 1) * progress;
	});
	_mesh.transform = CATransform3DMakeScale(_horizontal ? depthScale : 1, _horizontal ? 1 : depthScale, 1);

	CGFloat depth = _horizontal ? NSWidth(_mesh.bounds) : NSHeight(_mesh.bounds);
	for(CALayer* strip in _mesh.sublayers)
	{
		CGFloat distance = (_horizontal ? strip.position.x : strip.position.y) / depth;
		CGFloat curvature = cos(M_PI * (_reverse ? 1 - distance : distance));
		CGFloat spanScale = AnimateGenieTrack(strip, _horizontal ? @"transform.scale.y" : @"transform.scale.x", from, to, time, duration, ^CGFloat(CGFloat progress){
			CGFloat pinch = progress + progress * (1 - progress) * curvature;
			return 1 + (spanRatio - 1) * pinch;
		});
		strip.transform = CATransform3DMakeScale(_horizontal ? 1 : spanScale, _horizontal ? spanScale : 1, 1);
	}
}

- (void)clearAnimation
{
	[self.layer removeAllAnimations];
	[_mesh removeAllAnimations];
	for(CALayer* strip in _mesh.sublayers)
		[strip removeAllAnimations];
}
@end

@interface FloatingPanel ()
@property (nonatomic, weak) NSWindow* owner;
@property (nonatomic) RunOutputWindow* window;
@property (nonatomic) RunOutputWindow* gripWindow;
@property (nonatomic) RunOutputWindow* genieWindow;
@property (nonatomic) RunOutputGenieView* genieView;
@property (nonatomic) NSObject* genieTransition;
@property (nonatomic) NSTimer* genieCompletion;
@property (nonatomic) CFTimeInterval genieTime;
@property (nonatomic) CGFloat genieProgress;
@property (nonatomic) BOOL genieClosing;
@property (nonatomic) NSNumber* displayNumber;
@property (nonatomic) RunOutputMagnetIndicator* magnetIndicator;
@property (nonatomic) NSPoint dockedOffset;
@property (nonatomic) NSRect dockedBounds;
@property (nonatomic) NSTimer* tuckTimer;
@property (nonatomic) RunOutputEdge edge;
@property (nonatomic) NSRect dragFrame;
@property (nonatomic) NSRect dragBounds;
@property (nonatomic) RunOutputEdge dragEdge;
@property (nonatomic) RunOutputEdge arrivalEdge;
@property (nonatomic) CGFloat dragEdgeGap;
@property (nonatomic) BOOL presented;
@property (nonatomic, readwrite, getter=isTucked) BOOL tucked;
@property (nonatomic) BOOL dragging;
@property (nonatomic) BOOL waitForGripExit;
@end

@implementation FloatingPanel
- (RunOutputWindow*)makeWindowWithStyle:(NSWindowStyleMask)style contentView:(NSView*)view
{
	RunOutputWindow* window = [[RunOutputWindow alloc] initWithContentRect:view.frame
		styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel | style backing:NSBackingStoreBuffered defer:YES];
	window.level = NSFloatingWindowLevel;
	window.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
	window.hidesOnDeactivate = YES;
	window.opaque = NO;
	window.backgroundColor = NSColor.clearColor;
	window.hasShadow = YES;
	window.releasedWhenClosed = NO;
	window.animationBehavior = NSWindowAnimationBehaviorNone;
	window.contentView = view;
	return window;
}

- (instancetype)initWithContentView:(NSView*)contentView title:(NSString*)title
{
	if(self = [super init])
	{
		__weak FloatingPanel* weakSelf = self;
		RunOutputTrackingView* surface = [[RunOutputTrackingView alloc] initWithFrame:NSMakeRect(0, 0, 560, 300)];
		surface.pointerHandler = ^(NSPoint point){ [weakSelf pointerMovedTo:point]; };
		contentView.frame = surface.bounds;
		contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		[surface addSubview:contentView];
		_magnetIndicator = [RunOutputMagnetIndicator new];
		_magnetIndicator.hidden = YES;
		[surface addSubview:_magnetIndicator];
		_window = [self makeWindowWithStyle:NSWindowStyleMaskResizable contentView:surface];
		_window.title = title;
		_window.contentMinSize = NSMakeSize(300, 145);
		_window.dismissHandler = ^{
			FloatingPanel* panel = weakSelf;
			if(panel.dismissHandler)
				panel.dismissHandler();
			else
				[panel dismiss];
		};
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(panelBecameKey:)
			name:NSWindowDidBecomeKeyNotification object:_window];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(panelResignedKey:)
			name:NSWindowDidResignKeyNotification object:_window];

		RunOutputTrackingView* grip = [[RunOutputTrackingView alloc] initWithFrame:NSMakeRect(0, 0, EdgeThickness, EdgeLength)];
		grip.pointerHandler = ^(NSPoint point){ [weakSelf pointerMovedTo:point]; };
		grip.pressHandler = ^{ [weakSelf revealAnimated:YES]; };
		grip.toolTip = [@"Show " stringByAppendingString:title];
		grip.accessibilityElement = YES;
		grip.accessibilityRole = NSAccessibilityButtonRole;
		grip.accessibilityLabel = grip.toolTip;
		_gripWindow = [self makeWindowWithStyle:0 contentView:grip];
		_gripWindow.title = grip.accessibilityLabel;
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(screensChanged:)
			name:NSApplicationDidChangeScreenParametersNotification object:nil];
	}
	return self;
}

- (void)dealloc
{
	[_tuckTimer invalidate];
	[_genieCompletion invalidate];
	[NSNotificationCenter.defaultCenter removeObserver:self];
	for(NSWindow* window in @[ _window, _gripWindow ])
	{
		[window.parentWindow removeChildWindow:window];
		[window orderOut:nil];
	}
	[_genieWindow.parentWindow removeChildWindow:_genieWindow];
	[_genieWindow orderOut:nil];
}

- (NSScreen*)targetScreen
{
	for(NSScreen* screen in NSScreen.screens)
	{
		if([self.displayNumber isEqual:OutputScreenNumber(screen)])
			return screen;
	}
	return self.owner.screen ?: NSScreen.mainScreen;
}

- (BOOL)floatsIndependently
{
	NSScreen* ownerScreen = self.owner.screen ?: NSScreen.mainScreen;
	return self.isPinned || (self.displayNumber && ![self.displayNumber isEqual:OutputScreenNumber(ownerScreen)]);
}

- (void)updateWindowPolicy
{
	BOOL independent = [self floatsIndependently];
	for(RunOutputWindow* window in @[ self.window, self.gripWindow ])
	{
		if(independent && window.parentWindow)
			[window.parentWindow removeChildWindow:window];
		NSWindowCollectionBehavior behavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
		if(independent)
			behavior |= NSWindowCollectionBehaviorCanJoinAllSpaces;
		if(window.collectionBehavior != behavior)
			window.collectionBehavior = behavior;
		window.hidesOnDeactivate = !self.isPinned;
	}
}

- (void)orderOutputWindow:(RunOutputWindow*)window
{
	if(!self.presented || !self.owner)
		return;
	if([self floatsIndependently])
		window.level = NSFloatingWindowLevel;
	else if(window.parentWindow != self.owner)
		[self.owner addChildWindow:window ordered:NSWindowAbove];
	if(self.isPinned)
		[window orderFrontRegardless];
	else if(self.owner.isVisible && !self.owner.isMiniaturized)
		[window orderFront:nil];
	else if(window.isVisible)
		[window orderOut:nil];
}

- (void)orderPresentedWindow
{
	[self orderOutputWindow:self.tucked ? self.gripWindow : self.window];
}

- (void)removeWindow:(NSWindow*)window
{
	[window.parentWindow removeChildWindow:window];
	[window orderOut:nil];
}

- (void)showInWindow:(NSWindow*)owner
{
	if(!owner)
		return;
	if(self.owner != owner)
	{
		[self dismiss];
		[self stopObservingOwner];
		self.owner = owner;
		self.edge = RunOutputEdge::None;
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ownerMoved:) name:NSWindowDidMoveNotification object:owner];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ownerMoved:) name:NSWindowDidChangeScreenNotification object:owner];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ownerClosed:) name:NSWindowWillCloseNotification object:owner];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ownerVisibilityChanged:) name:NSWindowDidMiniaturizeNotification object:owner];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ownerVisibilityChanged:) name:NSWindowDidDeminiaturizeNotification object:owner];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ownerVisibilityChanged:) name:NSWindowDidBecomeMainNotification object:owner];
		NSRect parentFrame = owner.frame;
		NSRect frame = self.window.frame;
		frame.size.width = MIN(700, MAX(400, NSWidth(parentFrame) * 0.5));
		CGFloat verticalOrigin = self.opensNearBottom ? NSMinY(parentFrame) + 36 : NSMaxY(parentFrame) - 72 - NSHeight(frame);
		frame.origin = NSMakePoint(NSMidX(parentFrame) - NSWidth(frame) / 2, verticalOrigin);
		NSScreen* screen = owner.screen ?: NSScreen.mainScreen;
		self.displayNumber = OutputScreenNumber(screen);
		[self.window setFrame:screen ? ConstrainOutputFrame(frame, screen.visibleFrame) : frame display:NO];
	}
	self.presented = YES;
	[self reveal];
}

- (void)focus
{
	[self reveal];
	if(self.window.isVisible)
		[self.window makeKeyWindow];
}

- (void)refreshWindowOrdering
{
	if(!self.dragging && !self.genieWindow)
		[self orderPresentedWindow];
}

- (void)dismiss
{
	self.presented = self.tucked = self.dragging = NO;
	self.magnetIndicator.hidden = YES;
	[self cancelTuck];
	[self cancelGenie];
	BOOL wasKey = self.window.isKeyWindow;
	[self removeWindow:self.gripWindow];
	[self removeWindow:self.window];
	if(wasKey && self.owner.isVisible && !self.owner.isMiniaturized && NSApp.isActive)
		[self.owner makeKeyWindow];
}

- (void)ownerClosed:(NSNotification*)notification
{
	[self dismiss];
	[self stopObservingOwner];
	self.owner = nil;
}

- (void)stopObservingOwner
{
	if(self.owner)
		[NSNotificationCenter.defaultCenter removeObserver:self name:nil object:self.owner];
}

- (void)ownerVisibilityChanged:(NSNotification*)notification
{
	[self finishGenie];
	[self orderPresentedWindow];
}

- (void)panelBecameKey:(NSNotification*)notification
{
	if(self.keepsOpenWhileKey)
	{
		[self cancelTuck];
		if(self.owner.isVisible && !self.owner.isMiniaturized && !self.owner.isMainWindow)
			[self.owner makeMainWindow];
	}
}

- (void)panelResignedKey:(NSNotification*)notification
{
	if(self.keepsOpenWhileKey && !self.tucked && NSApp.isActive)
		[self pointerMovedTo:NSEvent.mouseLocation];
}

- (void)ownerMoved:(NSNotification*)notification
{
	if(!self.presented || self.dragging)
		return;
	[self finishGenie];
	if(self.edge == RunOutputEdge::None && self.window.parentWindow == self.owner)
		self.displayNumber = OutputScreenNumber(self.owner.screen);
	[self updateWindowPolicy];
	if(self.edge != RunOutputEdge::None)
		[self applyDockedFrames];
	[self orderPresentedWindow];
}

- (void)screensChanged:(NSNotification*)notification
{
	if(!self.presented || self.dragging)
		return;
	[self finishGenie];
	NSScreen* screen = [self targetScreen];
	self.displayNumber = OutputScreenNumber(screen);
	[self updateWindowPolicy];
	if(self.edge != RunOutputEdge::None)
	{
		if(screen)
			self.dockedBounds = screen.visibleFrame;
		[self applyDockedFrames];
	}
	else if(screen)
		[self.window setFrame:ConstrainOutputFrame(self.window.frame, screen.visibleFrame) display:YES];
	[self orderPresentedWindow];
}

- (void)setPinned:(BOOL)pinned
{
	if(_pinned == pinned)
		return;
	_pinned = pinned;
	[self reveal];
	if(!pinned)
		[self pointerMovedTo:NSEvent.mouseLocation];
}

- (void)updateMagnetIndicator:(RunOutputEdge)edge intensity:(CGFloat)intensity
{
	self.magnetIndicator.hidden = edge == RunOutputEdge::None || intensity <= 0;
	if(self.magnetIndicator.hidden)
		return;
	NSRect grip = OutputGripFrame(self.window.contentView.bounds, edge);
	BOOL vertical = edge == RunOutputEdge::Left || edge == RunOutputEdge::Right;
	self.magnetIndicator.frame = vertical ? NSInsetRect(grip, 2.5, 12) : NSInsetRect(grip, 12, 2.5);
	self.magnetIndicator.alphaValue = intensity;
}

- (void)applyDockedFrames
{
	NSRect frame = self.window.frame;
	frame.origin = NSMakePoint(NSMinX(self.dockedBounds) + self.dockedOffset.x, NSMinY(self.dockedBounds) + self.dockedOffset.y);
	frame = OutputFrameAtEdge(frame, self.dockedBounds, self.edge);
	[self.window setFrame:frame display:!self.tucked];
	[self.gripWindow setFrame:OutputGripFrame(frame, self.edge) display:self.tucked];
}

- (void)beginDrag
{
	[self cancelTuck];
	[self finishGenie];
	self.dragging = YES;
	self.dragFrame = self.window.frame;
	self.dragEdge = self.edge;
	NSScreen* screen = [self targetScreen];
	self.dragBounds = self.edge != RunOutputEdge::None ? self.dockedBounds : (screen ? screen.visibleFrame : NSZeroRect);
	self.dragEdgeGap = 0;
	self.arrivalEdge = RunOutputEdge::None;
	self.edge = RunOutputEdge::None;
}

- (NSScreen*)dragScreenAtPoint:(NSPoint)point
{
	return OutputScreenAtPoint(point) ?: [self targetScreen];
}

- (BOOL)prepareDisplayNumber:(NSNumber*)displayNumber
{
	if(self.displayNumber == displayNumber || [self.displayNumber isEqual:displayNumber])
		return NO;
	self.displayNumber = displayNumber;
	[self updateWindowPolicy];
	return YES;
}

- (void)moveBy:(NSSize)offset atPoint:(NSPoint)point
{
	if(!self.dragging)
		return;
	NSScreen* screen = [self dragScreenAtPoint:point];
	BOOL changedDisplay = [self prepareDisplayNumber:OutputScreenNumber(screen)];
	BOOL snapped = [self moveBy:offset inVisibleFrame:screen ? screen.visibleFrame : NSZeroRect];
	if(changedDisplay)
		[self orderPresentedWindow];
	if(snapped && self.window.isVisible)
		[NSHapticFeedbackManager.defaultPerformer performFeedbackPattern:NSHapticFeedbackPatternAlignment performanceTime:NSHapticFeedbackPerformanceTimeNow];
}

- (BOOL)moveBy:(NSSize)offset inVisibleFrame:(NSRect)bounds
{
	if(!self.dragging)
		return NO;

	NSRect previous = self.dragFrame;
	NSRect frame = previous;
	frame.origin.x += offset.width;
	frame.origin.y += offset.height;
	BOOL sameDisplay = NSEqualRects(self.dragBounds, bounds);
	if(!sameDisplay)
		self.arrivalEdge = OutputArrivalEdge(self.dragBounds, bounds);
	if(self.arrivalEdge != RunOutputEdge::None && OutputEdgeGap(frame, bounds, self.arrivalEdge) >= AttractionDistance)
		self.arrivalEdge = RunOutputEdge::None;
	RunOutputEdge previousEdge = sameDisplay ? self.dragEdge : RunOutputEdge::None;
	RunOutputEdge edge = previousEdge;
	if(edge != RunOutputEdge::None)
	{
		CGFloat delta = OutputEdgeGap(frame, bounds, edge) - OutputEdgeGap(previous, bounds, edge);
		self.dragEdgeGap = MAX(0, self.dragEdgeGap + delta);
		if(self.dragEdgeGap >= ReleaseDistance)
		{
			frame.origin = OutputOriginAtEdge(frame, bounds, edge, self.dragEdgeGap);
			edge = RunOutputEdge::None;
		}
	}
	if(edge == RunOutputEdge::None && !NSIsEmptyRect(bounds))
	{
		edge = OutputEdgeNearFrame(frame, bounds, SnapDistance, self.arrivalEdge, sameDisplay ? &previous : nullptr);
		self.dragEdgeGap = MAX(0, OutputEdgeGap(frame, bounds, edge));
	}

	self.dragBounds = bounds;
	self.dragFrame = frame;
	self.dragEdge = edge;
	NSRect preview = edge == RunOutputEdge::None ? frame : OutputFrameAtEdge(frame, bounds, edge);
	RunOutputEdge indicatorEdge = edge;
	CGFloat intensity = 1;
	if(edge == RunOutputEdge::None && !NSIsEmptyRect(bounds))
	{
		indicatorEdge = OutputEdgeNearFrame(frame, bounds, AttractionDistance, self.arrivalEdge);
		if(indicatorEdge != RunOutputEdge::None)
		{
			CGFloat gap = OutputEdgeGap(frame, bounds, indicatorEdge);
			CGFloat progress = MAX(0, MIN(1, (AttractionDistance - gap) / (AttractionDistance - SnapDistance)));
			intensity = progress * progress * (3 - 2 * progress);
			preview.origin = OutputOriginAtEdge(frame, bounds, indicatorEdge, gap * (1 - intensity));
		}
	}
	NSRect displayed = self.window.frame;
	if(!NSEqualSizes(preview.size, displayed.size))
		[self.window setFrame:preview display:YES];
	else if(!NSEqualPoints(preview.origin, displayed.origin))
		[self.window setFrameOrigin:preview.origin];
	[self updateMagnetIndicator:indicatorEdge intensity:intensity];
	return edge != RunOutputEdge::None && edge != previousEdge;
}

- (void)endDragAtPoint:(NSPoint)point
{
	if(!self.dragging)
		return;
	NSScreen* screen = [self dragScreenAtPoint:point];
	if(screen)
	{
		[self prepareDisplayNumber:OutputScreenNumber(screen)];
		[self endDragInVisibleFrame:screen.visibleFrame atPoint:point];
	}
	else
	{
		self.dragging = NO;
		self.magnetIndicator.hidden = YES;
	}
}

- (void)endDragInVisibleFrame:(NSRect)bounds atPoint:(NSPoint)point
{
	if(!self.dragging)
		return;
	[self moveBy:NSZeroSize inVisibleFrame:bounds];
	self.dragging = NO;
	self.magnetIndicator.hidden = YES;
	self.edge = self.dragEdge;
	if(self.edge == RunOutputEdge::None)
	{
		[self.window setFrame:ConstrainOutputFrame(self.window.frame, bounds) display:YES];
		[self orderPresentedWindow];
	}
	else
	{
		self.dockedOffset = NSMakePoint(NSMinX(self.window.frame) - NSMinX(bounds), NSMinY(self.window.frame) - NSMinY(bounds));
		self.dockedBounds = bounds;
		if(self.isPinned)
			[self orderPresentedWindow];
		else
			[self tuckWithPointerAt:point];
	}
}

- (void)cancelTuck
{
	[self.tuckTimer invalidate];
	self.tuckTimer = nil;
}

- (void)cancelGenie
{
	self.genieTransition = nil;
	[self.genieCompletion invalidate];
	self.genieCompletion = nil;
	if(self.genieWindow)
	{
		[self removeWindow:self.genieWindow];
		[self.genieView clearAnimation];
		self.genieWindow.contentView = nil;
	}
	self.genieWindow = nil;
	if(!self.tucked)
		self.genieView = nil;
}

- (void)finishGenie
{
	if(!self.genieWindow)
		return;
	if(!self.tucked)
		[self removeWindow:self.gripWindow];
	[self orderPresentedWindow];
	[self cancelGenie];
	if(!self.tucked)
		[self pointerMovedTo:NSEvent.mouseLocation];
}

- (BOOL)startGenie
{
	if(NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion || !self.owner.isVisible || self.owner.isMiniaturized)
	{
		[self cancelGenie];
		return NO;
	}
	CGFloat from = self.tucked ? 0 : 1;
	BOOL needsOrdering = !self.genieWindow;
	if(!needsOrdering)
	{
		CGFloat elapsed = (CACurrentMediaTime() - self.genieTime) / GenieDuration;
		from = MAX(0, MIN(1, self.genieProgress + (self.genieClosing ? elapsed : -elapsed)));
	}
	else
	{
		NSRect frame = self.window.frame;
		if(self.tucked || !self.genieView || !NSEqualSizes(self.genieView.bounds.size, frame.size))
		{
			NSRect grip = NSOffsetRect(self.gripWindow.frame, -NSMinX(frame), -NSMinY(frame));
			self.genieView = [[RunOutputGenieView alloc] initWithView:self.window.contentView grip:grip edge:self.edge];
		}
		if(!self.genieView)
			return NO;

		self.genieWindow = [self makeWindowWithStyle:0 contentView:self.genieView];
		self.genieWindow.ignoresMouseEvents = YES;
		self.genieWindow.hasShadow = NO;
		self.genieWindow.collectionBehavior = self.gripWindow.collectionBehavior;
		[self.genieWindow setFrame:frame display:NO];
	}

	CGFloat to = self.tucked ? 1 : 0;
	NSTimeInterval duration = fabs(to - from) * GenieDuration;
	if(duration < 0.001)
	{
		[self cancelGenie];
		return NO;
	}
	self.genieProgress = from;
	self.genieClosing = self.tucked;
	self.genieTime = CACurrentMediaTime();
	NSObject* transition = [NSObject new];
	self.genieTransition = transition;
	__weak FloatingPanel* weakSelf = self;
	void (^finish)(void) = ^{
		FloatingPanel* panel = weakSelf;
		if(panel.genieTransition == transition)
			[panel finishGenie];
	};
	[self.genieCompletion invalidate];
	self.genieCompletion = [NSTimer timerWithTimeInterval:duration + 0.05 repeats:NO block:^(NSTimer* timer){ finish(); }];
	[NSRunLoop.mainRunLoop addTimer:self.genieCompletion forMode:NSRunLoopCommonModes];
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	[CATransaction setCompletionBlock:finish];
	[self.genieView animateFrom:from to:to atTime:self.genieTime duration:duration];
	if(needsOrdering)
		[self orderOutputWindow:self.genieWindow];
	[CATransaction commit];
	return YES;
}

- (void)tuckWithPointerAt:(NSPoint)point
{
	if(!self.presented || self.isPinned || self.edge == RunOutputEdge::None || self.dragging)
		return;
	self.tucked = YES;
	[self applyDockedFrames];
	self.waitForGripExit = NSPointInRect(point, self.gripWindow.frame);
	BOOL wasKey = self.window.isKeyWindow;
	[self orderPresentedWindow];
	[self startGenie];
	[self removeWindow:self.window];
	if(wasKey && self.owner.isVisible && !self.owner.isMiniaturized && NSApp.isActive)
		[self.owner makeKeyWindow];
}

- (void)reveal
{
	[self revealAnimated:NO];
}

- (void)revealAnimated:(BOOL)animated
{
	if(!self.presented)
		return;
	[self cancelTuck];
	BOOL wasTucked = self.tucked;
	self.tucked = NO;
	if(animated && (wasTucked ? [self startGenie] : self.genieWindow != nil))
		return;
	[self cancelGenie];
	[self removeWindow:self.gripWindow];
	[self updateWindowPolicy];
	if(self.edge != RunOutputEdge::None)
		[self applyDockedFrames];
	[self orderPresentedWindow];
}

- (BOOL)holdsOpenForInteraction
{
	return self.keepsOpenWhileKey && (self.window.isKeyWindow || self.window.attachedSheet != nil);
}

- (void)pointerMovedTo:(NSPoint)point
{
	if(!self.presented || self.isPinned || self.edge == RunOutputEdge::None || self.dragging)
		return;
	if(self.tucked)
	{
		if(!NSPointInRect(point, self.gripWindow.frame))
			self.waitForGripExit = NO;
		else if(!self.waitForGripExit)
			[self revealAnimated:YES];
	}
	else if(self.genieWindow)
		return;
	else if([self holdsOpenForInteraction])
		[self cancelTuck];
	else if(NSPointInRect(point, self.window.frame))
		[self cancelTuck];
	else if(!self.tuckTimer)
	{
		__weak FloatingPanel* weakSelf = self;
		self.tuckTimer = [NSTimer timerWithTimeInterval:0.35 repeats:NO block:^(NSTimer* timer){
			FloatingPanel* panel = weakSelf;
			panel.tuckTimer = nil;
			NSPoint pointer = NSEvent.mouseLocation;
			if(!panel || [panel holdsOpenForInteraction] || NSPointInRect(pointer, panel.window.frame))
				return;
			if(NSEvent.pressedMouseButtons)
				[panel pointerMovedTo:pointer];
			else
				[panel tuckWithPointerAt:pointer];
		}];
		[NSRunLoop.mainRunLoop addTimer:self.tuckTimer forMode:NSRunLoopCommonModes];
	}
}
@end

@interface FloatingPanelDragBar ()
@property (nonatomic) NSPoint lastPoint;
@property (nonatomic) BOOL didDrag;
@end

@implementation FloatingPanelDragBar
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (NSView*)hitTest:(NSPoint)point
{
	NSView* hit = [super hitTest:point];
	for(NSView* view = hit; view && view != self; view = view.superview)
	{
		if([view isKindOfClass:NSButton.class])
			return hit;
	}
	return hit ? self : nil;
}
- (void)mouseDown:(NSEvent*)event
{
	self.lastPoint = [self.window convertPointToScreen:event.locationInWindow];
	self.didDrag = NO;
}
- (void)mouseDragged:(NSEvent*)event
{
	NSPoint point = [self.window convertPointToScreen:event.locationInWindow];
	NSSize offset = NSMakeSize(point.x - self.lastPoint.x, point.y - self.lastPoint.y);
	if(!self.didDrag)
	{
		if(hypot(offset.width, offset.height) < 3)
			return;
		self.didDrag = YES;
		[self.panel beginDrag];
	}
	self.lastPoint = point;
	[self.panel moveBy:offset atPoint:point];
}
- (void)mouseUp:(NSEvent*)event
{
	if(self.didDrag)
	{
		NSPoint point = [self.window convertPointToScreen:event.locationInWindow];
		[self.panel moveBy:NSMakeSize(point.x - self.lastPoint.x, point.y - self.lastPoint.y) atPoint:point];
		[self.panel endDragAtPoint:point];
	}
}
@end

@implementation FloatingPanelPinButton
{
	NSString* _panelName;
}

- (instancetype)initWithPanelName:(NSString*)name
{
	if(self = [super initWithFrame:NSZeroRect])
	{
		_panelName = [name copy];
		self.title = @"";
		self.imagePosition = NSImageOnly;
		self.controlSize = NSControlSizeSmall;
		self.bordered = NO;
		self.target = self;
		self.action = @selector(togglePin:);
		[self setButtonType:NSButtonTypePushOnPushOff];
		[self updatePin];
	}
	return self;
}

- (void)setPanel:(FloatingPanel*)panel
{
	_panel = panel;
	[self updatePin];
}

- (void)togglePin:(id)sender
{
	self.panel.pinned = !self.panel.isPinned;
	[self updatePin];
}

- (void)updatePin
{
	BOOL pinned = self.panel.isPinned;
	self.state = pinned ? NSControlStateValueOn : NSControlStateValueOff;
	self.image = [NSImage imageWithSystemSymbolName:pinned ? @"pin.fill" : @"pin" accessibilityDescription:nil];
	self.contentTintColor = pinned ? NSColor.controlAccentColor : nil;
	self.toolTip = pinned ? [@"Unpin " stringByAppendingString:_panelName] : [NSString stringWithFormat:@"Keep %@ on top", _panelName];
	self.accessibilityLabel = self.toolTip;
}
@end
