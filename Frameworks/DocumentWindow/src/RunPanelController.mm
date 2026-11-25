#import "RunPanelController.h"
#import "FloatingPanel.h"
#import "ProjectDebugSession.h"
#import "ProjectRun.h"
#import "ProjectRunSession.h"
#import <OakAppKit/OakUIConstructionFunctions.h>

@interface RunSidebarHeader : NSView
@property (nonatomic) NSView* launchGroup;
@property (nonatomic) NSButton* gear;
@property (nonatomic) NSButton* actionsButton;
@end

@implementation RunSidebarHeader
- (void)layout
{
	[super layout];
	CGFloat width = NSWidth(self.bounds);
	self.gear.frame = NSMakeRect(MAX(0, width-57), 6, 24, 24);
	self.actionsButton.frame = NSMakeRect(MAX(0, width-32), 6, 24, 24);
	self.launchGroup.frame = NSMakeRect(8, 6, MAX(40, width-70), 24);
}
@end

@interface RunSidebarList : NSView
@end

@implementation RunSidebarList
- (BOOL)isFlipped { return YES; }
@end

static NSStackView* RunSidebarStack(NSArray<NSView*>* views)
{
	NSStackView* stack = [NSStackView stackViewWithViews:views];
	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.alignment = NSLayoutAttributeLeading;
	stack.spacing = 0;
	for(NSView* view in views)
		[view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
	return stack;
}

static constexpr CGFloat kRunSectionChevronWidth = 12;
static constexpr CGFloat kRunSectionTitleSpacing = 5;

@interface RunSidebarSection : NSView
@property (nonatomic, readonly) NSButton* heading;
@property (nonatomic) NSView* body;
@property (nonatomic) BOOL expanded;
@property (nonatomic, copy) void (^didExpand)(void);
- (instancetype)initWithTitle:(NSString*)title body:(NSView*)body;
@end

@implementation RunSidebarSection
{
	NSArray<NSLayoutConstraint*>* _bodyConstraints;
	NSLayoutConstraint* _collapsed;
}

- (instancetype)initWithTitle:(NSString*)title body:(NSView*)body
{
	if(self = [super initWithFrame:NSZeroRect])
	{
		_heading = [NSButton buttonWithTitle:title target:self action:@selector(toggle:)];
		_heading.bordered = NO;
		_heading.imagePosition = NSImageLeft;
		_heading.alignment = NSTextAlignmentLeft;
		_heading.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
		_heading.contentTintColor = NSColor.secondaryLabelColor;
		_heading.accessibilityRole = NSAccessibilityDisclosureTriangleRole;
		_heading.accessibilityLabel = title;
		[_heading setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
		_body = body;
		OakAddAutoLayoutViewsToSuperview(@[ _heading ], self);
		NSLayoutConstraint* trailing = [_heading.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8];
		trailing.priority = NSLayoutPriorityRequired - 10;
		[NSLayoutConstraint activateConstraints:@[
			[_heading.topAnchor constraintEqualToAnchor:self.topAnchor],
			[_heading.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kOakSidebarDisclosureCenter + 4 - kRunSectionChevronWidth / 2],
			trailing,
			[_heading.heightAnchor constraintEqualToConstant:25],
		]];
		_collapsed = [_heading.bottomAnchor constraintEqualToAnchor:self.bottomAnchor];
		[self setExpanded:NO];
	}
	return self;
}

- (void)setExpanded:(BOOL)expanded
{
	_expanded = expanded;
	_heading.image = OakSidebarDisclosureImage(expanded, kRunSectionChevronWidth, kRunSectionTitleSpacing);
	_heading.accessibilityExpanded = expanded;
	if(expanded && !_body.superview)
	{
		_collapsed.active = NO;
		OakAddAutoLayoutViewsToSuperview(@[ _body ], self);
		NSLayoutConstraint* trailing = [_body.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8];
		trailing.priority = NSLayoutPriorityRequired - 10;
		NSLayoutConstraint* leading = [_body.leadingAnchor constraintEqualToAnchor:_heading.leadingAnchor constant:kRunSectionChevronWidth + kRunSectionTitleSpacing];
		leading.priority = NSLayoutPriorityRequired - 11;
		_bodyConstraints = @[
			[_body.topAnchor constraintEqualToAnchor:_heading.bottomAnchor],
			leading,
			trailing,
			[_body.widthAnchor constraintGreaterThanOrEqualToConstant:0],
			[_body.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
		];
		[NSLayoutConstraint activateConstraints:_bodyConstraints];
		if(self.didExpand)
			self.didExpand();
	}
	else if(!expanded)
	{
		[NSLayoutConstraint deactivateConstraints:_bodyConstraints ?: @[]];
		[_body removeFromSuperview];
		_bodyConstraints = nil;
		_collapsed.active = YES;
	}
}

- (void)toggle:(id)sender { self.expanded = !self.expanded; }
@end

enum class RunOutputEscapeState { Text, Escape, CSI };

static NSColor* RunOutputRGBColor(NSInteger red, NSInteger green, NSInteger blue)
{
	if(red < 0 || red > 255 || green < 0 || green > 255 || blue < 0 || blue > 255)
		return nil;
	return [NSColor colorWithSRGBRed:red/255.0 green:green/255.0 blue:blue/255.0 alpha:1];
}

static NSColor* RunOutputIndexedColor(NSInteger index)
{
	if(index < 0 || index > 255)
		return nil;
	if(index < 16)
	{
		static NSArray<NSColor*>* palette;
		static dispatch_once_t once;
		dispatch_once(&once, ^{
			static constexpr uint32_t light[] = { 0x242424, 0xA6262C, 0x186333, 0x775900, 0x2055A6, 0x852183, 0x00646D, 0x525252,
			                                      0x646464, 0xCA262D, 0x008043, 0x866000, 0x0962C9, 0xA43BA4, 0x007785, 0x333333 };
			static constexpr uint32_t dark[] = { 0xA0A0A0, 0xF17D81, 0x76C68C, 0xD1AE63, 0x83ADF2, 0xDB8DD7, 0x69BECD, 0xDFDFDF,
			                                     0xB4B4B4, 0xFF9B9D, 0xA3ECB4, 0xF1CC7B, 0xA5C7FF, 0xF3AFEE, 0x8EE3F0, 0xF8F8F8 };
			NSMutableArray<NSColor*>* colors = [NSMutableArray arrayWithCapacity:16];
			for(NSUInteger entry = 0; entry < 16; ++entry)
			{
				[colors addObject:[NSColor colorWithName:nil dynamicProvider:^NSColor*(NSAppearance* appearance){
					NSString* match = [appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
					uint32_t rgb = [match isEqual:NSAppearanceNameDarkAqua] ? dark[entry] : light[entry];
					return RunOutputRGBColor(rgb >> 16, (rgb >> 8) & 0xff, rgb & 0xff);
				}]];
			}
			palette = [colors copy];
		});
		return palette[index];
	}
	if(index < 232)
	{
		static constexpr NSInteger levels[] = { 0, 95, 135, 175, 215, 255 };
		NSInteger cube = index - 16;
		return RunOutputRGBColor(levels[cube/36], levels[(cube/6)%6], levels[cube%6]);
	}
	NSInteger gray = 8 + 10*(index-232);
	return RunOutputRGBColor(gray, gray, gray);
}

@interface RunPanelController ()
@property (nonatomic) NSButton* configurationButton;
@property (nonatomic) NSMenu* configurationMenu;
@property (nonatomic) ProjectRunConfiguration* selectedConfiguration;
@property (nonatomic) NSButton* runButton;
@property (nonatomic) NSButton* configureButton;
@property (nonatomic) NSTextField* status;
@property (nonatomic) NSTextField* sidebarHint;
@property (nonatomic) NSTextView* output;
@property (nonatomic, readwrite) NSView* outputView;
@property (nonatomic) FloatingPanel* outputPanel;
@property (nonatomic, weak) FloatingPanelDragBar* outputDragBar;
@property (nonatomic) FloatingPanelPinButton* outputPinButton;
@property (nonatomic) NSBox* debugToolbar;
@property (nonatomic) NSLayoutConstraint* debugToolbarCenter;
@property (nonatomic, weak) NSView* debugToolbarEditor;
@property (nonatomic) NSButton* debugActionButton;
@property (nonatomic) NSButton* debugStopButton;
@property (nonatomic) NSButton* debugRestartButton;
@property (nonatomic) NSArray<NSButton*>* stepButtons;
@property (nonatomic) NSStackView* frameRows;
@property (nonatomic) NSButton* goroutinesButton;
@property (nonatomic) NSStackView* breakpointRows;
@property (nonatomic) RunSidebarSection* variableSection;
@property (nonatomic) RunSidebarSection* watchSection;
@property (nonatomic) RunSidebarSection* frameSection;
@property (nonatomic) BOOL revealedPauseSections;
@property (nonatomic) NSStackView* variableRows;
@property (nonatomic) NSStackView* watchRows;
@property (nonatomic) NSTextField* watchInput;
@property (nonatomic) NSString* editingWatchExpression;
@property (nonatomic) NSUInteger watchRevision;
@property (nonatomic) BOOL hasSelectedFrame;
@property (nonatomic) ProjectRunSession* session;
@property (nonatomic) ProjectDebugSession* debugger;
@property (nonatomic) ProjectDebugPlan* preparingDebugPlan;
@property (nonatomic, copy) void (^restartAction)(void);
@property (nonatomic) BOOL restartPending;
@property (nonatomic) NSMutableSet<NSArray*>* trustedPlans;
@property (nonatomic) NSMutableData* pendingOutput;
@property (nonatomic) RunOutputEscapeState outputEscapeState;
@property (nonatomic) NSMutableString* outputColorParameters;
@property (nonatomic) NSColor* outputForeground;
@property (nonatomic) BOOL confirming;
@property (nonatomic) NSUInteger trustGeneration;
@end

static NSButton* DebugControl(NSString* symbol, NSString* title, id target, SEL action)
{
	NSImage* image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
	NSButton* button = image ? [NSButton buttonWithImage:image target:target action:action] : [NSButton buttonWithTitle:title target:target action:action];
	button.controlSize = NSControlSizeSmall;
	button.toolTip = title;
	button.accessibilityLabel = title;
	return button;
}

static NSButton* FloatingDebugControl(NSString* symbol, NSString* title, id target, SEL action)
{
	NSButton* button = DebugControl(symbol, title, target, action);
	button.bezelStyle = NSBezelStyleAccessoryBarAction;
	button.showsBorderOnlyWhileMouseInside = YES;
	[button.widthAnchor constraintEqualToConstant:27].active = YES;
	[button.heightAnchor constraintEqualToConstant:24].active = YES;
	return button;
}

@implementation RunPanelController
- (instancetype)init
{
	if(self = [super initWithNibName:nil bundle:nil])
	{
		_session = [ProjectRunSession new];
		_debugger = [ProjectDebugSession new];
		_trustedPlans = [NSMutableSet set];
		_pendingOutput = [NSMutableData data];
		__weak RunPanelController* weakSelf = self;
		_session.didStartCommand = ^(ProjectRunCommand* command){
			[weakSelf flushOutput];
			[weakSelf appendOutput:[NSString stringWithFormat:@"\n%@\n$ %@\n", command.directory, command.displayCommand]];
		};
		_session.didReadOutput = ^(NSData* data){ [weakSelf consumeOutput:data]; };
		_session.didFinish = ^(int exitCode, BOOL stopped, NSError* error){
			RunPanelController* panel = weakSelf;
			[panel flushOutput];
			ProjectDebugPlan* debugPlan = panel.preparingDebugPlan;
			panel.preparingDebugPlan = nil;
			if(debugPlan && !error && !stopped && exitCode == 0)
			{
				[panel startDebugger:debugPlan];
				return;
			}
			NSString* message = error ? error.localizedDescription : stopped ? @"Stopped" : [NSString stringWithFormat:@"Exited with code %d", exitCode];
			if(debugPlan && !stopped)
				message = [@"Pre-launch task failed: " stringByAppendingString:message];
			[panel appendOutput:[NSString stringWithFormat:@"\n%@\n", message]];
			panel.status.stringValue = message;
			[panel restartWhenIdle];
			[panel updateControls];
		};
		_debugger.didReadOutput = ^(NSString* text){ [weakSelf consumeOutputText:text]; };
		_debugger.didChangeState = ^(ProjectDebugState state, NSString* detail){
			RunPanelController* panel = weakSelf;
			panel.status.stringValue = detail ?: @"";
			if(state != ProjectDebugPaused && panel.clearExecutionLine)
				panel.clearExecutionLine();
			if(state == ProjectDebugStarting || state == ProjectDebugStopping || state == ProjectDebugIdle)
				[panel refreshBreakpointResults];
			if(state == ProjectDebugIdle)
			{
				[panel flushOutput];
				if(detail.length)
					[panel appendOutput:[NSString stringWithFormat:@"\n%@\n", detail]];
				[panel restartWhenIdle];
			}
			[panel updateControls];
		};
		_debugger.didChangeFrames = ^(NSArray* frames){ [weakSelf displayFrames:frames]; };
		_debugger.didChangeVariables = ^(NSArray* variables){ [weakSelf displayVariables:variables]; };
		_debugger.didChangeBreakpointResults = ^(NSString* path){ [weakSelf refreshBreakpointResults]; };
	}
	return self;
}

- (void)loadView
{
	NSView* content = [NSView new];
	RunSidebarHeader* header = [RunSidebarHeader new];
	header.gear = self.configureButton = DebugControl(@"gearshape", @"Configure Run & Debug…", self, @selector(configure:));
	header.actionsButton = DebugControl(@"ellipsis", @"Run & Debug actions", self, @selector(showSidebarActions:));
	header.gear.bordered = header.actionsButton.bordered = NO;

	self.runButton = DebugControl(@"play", @"Start selected configuration", self, @selector(startSelectedConfiguration:));
	self.runButton.bordered = NO;
	self.runButton.contentTintColor = NSColor.systemGreenColor;
	self.configurationButton = [NSButton buttonWithTitle:@"No run configurations"
		image:[[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:nil]
			imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:9 weight:NSFontWeightSemibold]]
		target:self action:@selector(showConfigurations:)];
	self.configurationButton.bordered = NO;
	self.configurationButton.alignment = NSTextAlignmentLeft;
	self.configurationButton.font = [NSFont systemFontOfSize:12];
	self.configurationButton.imagePosition = NSImageTrailing;
	self.configurationButton.imageHugsTitle = NO;
	self.configurationButton.cell.lineBreakMode = NSLineBreakByTruncatingTail;
	self.configurationButton.accessibilityRole = NSAccessibilityPopUpButtonRole;
	self.configurationButton.accessibilityLabel = @"Run configuration";
	[self.configurationButton setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	self.configurationMenu = [[NSMenu alloc] initWithTitle:@"Run Configurations"];
	self.configurationMenu.autoenablesItems = NO;

	NSBox* group = [NSBox new];
	group.boxType = NSBoxCustom;
	group.titlePosition = NSNoTitle;
	group.borderColor = NSColor.separatorColor;
	group.borderWidth = 1;
	group.cornerRadius = 5;
	group.contentViewMargins = NSZeroSize;
	group.fillColor = NSColor.clearColor;
	NSView* surface = group.contentView;
	NSBox* separator = [NSBox new];
	separator.boxType = NSBoxCustom;
	separator.titlePosition = NSNoTitle;
	separator.borderWidth = 0;
	separator.fillColor = NSColor.separatorColor;
	OakAddAutoLayoutViewsToSuperview(@[ self.runButton, separator, self.configurationButton ], surface);
	[NSLayoutConstraint activateConstraints:@[
		[self.runButton.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor],
		[self.runButton.centerYAnchor constraintEqualToAnchor:surface.centerYAnchor],
		[self.runButton.widthAnchor constraintEqualToConstant:27],
		[self.runButton.heightAnchor constraintEqualToAnchor:surface.heightAnchor],
		[separator.leadingAnchor constraintEqualToAnchor:self.runButton.trailingAnchor],
		[separator.centerYAnchor constraintEqualToAnchor:surface.centerYAnchor],
		[separator.widthAnchor constraintEqualToConstant:1],
		[separator.heightAnchor constraintEqualToConstant:14],
		[self.configurationButton.leadingAnchor constraintEqualToAnchor:separator.trailingAnchor constant:4],
		[self.configurationButton.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor constant:-5],
		[self.configurationButton.centerYAnchor constraintEqualToAnchor:surface.centerYAnchor],
		[self.configurationButton.heightAnchor constraintEqualToAnchor:surface.heightAnchor],
	]];
	header.launchGroup = group;
	for(NSView* view in @[ group, header.gear, header.actionsButton ])
		[header addSubview:view];

	self.sidebarHint = [self sidebarNote:@""];
	self.frameRows = RunSidebarStack(@[]);
	self.breakpointRows = RunSidebarStack(@[]);
	self.variableRows = RunSidebarStack(@[]);
	self.watchRows = RunSidebarStack(@[]);
	self.watchInput = [NSTextField textFieldWithString:@""];
	self.watchInput.controlSize = NSControlSizeSmall;
	self.watchInput.placeholderString = @"Add expression";
	self.watchInput.accessibilityLabel = @"Watch expression";
	self.watchInput.target = self;
	self.watchInput.action = @selector(commitWatchExpression:);
	[self.watchInput setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSButton* addWatch = DebugControl(@"plus", @"Save watch expression", self, @selector(commitWatchExpression:));
	addWatch.bordered = NO;
	NSStackView* watchEditor = [NSStackView stackViewWithViews:@[ self.watchInput, addWatch ]];
	watchEditor.alignment = NSLayoutAttributeCenterY;
	watchEditor.spacing = 3;
	NSStackView* watch = RunSidebarStack(@[ watchEditor, self.watchRows ]);

	self.variableSection = [[RunSidebarSection alloc] initWithTitle:@"VARIABLES" body:self.variableRows];
	self.watchSection = [[RunSidebarSection alloc] initWithTitle:@"WATCH" body:watch];
	self.goroutinesButton = [NSButton buttonWithTitle:@"Goroutines…" image:[NSImage imageWithSystemSymbolName:@"chevron.up.chevron.down" accessibilityDescription:nil]
	                                        target:self action:@selector(showGoroutines:)];
	self.goroutinesButton.bordered = NO;
	self.goroutinesButton.alignment = NSTextAlignmentLeft;
	self.goroutinesButton.imagePosition = NSImageRight;
	self.goroutinesButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
	NSStackView* callStack = RunSidebarStack(@[ self.goroutinesButton, self.frameRows ]);
	self.frameSection = [[RunSidebarSection alloc] initWithTitle:@"CALL STACK" body:callStack];
	RunSidebarSection* breakpoints = [[RunSidebarSection alloc] initWithTitle:@"BREAKPOINTS" body:self.breakpointRows];
	NSStackView* sections = RunSidebarStack(@[ self.variableSection, self.watchSection, self.frameSection, breakpoints ]);
	[sections addArrangedSubview:self.sidebarHint];
	[self.sidebarHint.widthAnchor constraintEqualToAnchor:sections.widthAnchor].active = YES;
	NSScrollView* scroll = [NSScrollView new];
	scroll.drawsBackground = NO;
	scroll.hasVerticalScroller = YES;
	scroll.scrollerStyle = NSScrollerStyleOverlay;
	scroll.autohidesScrollers = YES;
	NSView* list = [RunSidebarList new];
	scroll.documentView = list;
	list.translatesAutoresizingMaskIntoConstraints = NO;
	OakAddAutoLayoutViewsToSuperview(@[ sections ], list);
	OakAddAutoLayoutViewsToSuperview(@[ header, scroll ], content);
	[NSLayoutConstraint activateConstraints:@[
		[header.heightAnchor constraintEqualToConstant:36],
		[header.topAnchor constraintEqualToAnchor:content.topAnchor],
		[header.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
		[header.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
		[scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor],
		[scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
		[scroll.heightAnchor constraintGreaterThanOrEqualToConstant:0],
		[list.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
		[list.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
		[list.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
		[sections.topAnchor constraintEqualToAnchor:list.topAnchor],
		[sections.leadingAnchor constraintEqualToAnchor:list.leadingAnchor],
		[sections.trailingAnchor constraintEqualToAnchor:list.trailingAnchor],
		[sections.bottomAnchor constraintEqualToAnchor:list.bottomAnchor],
	]];
	[self buildOutputView];
	[self buildDebugToolbar];
	self.view = content;
	[self displayVariables:@[]];
	[self displayFrames:@[]];
	self.watchSection.expanded = self.watchExpressions.count > 0;
	[self reloadBreakpoints];
	[self updateControls];
}

- (NSTextField*)sidebarNote:(NSString*)text
{
	NSTextField* note = [NSTextField wrappingLabelWithString:text];
	note.font = [NSFont systemFontOfSize:11];
	note.textColor = NSColor.secondaryLabelColor;
	note.maximumNumberOfLines = 2;
	[note setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	return note;
}

- (void)buildOutputView
{
	NSVisualEffectView* output = [NSVisualEffectView new];
	output.material = NSVisualEffectMaterialPopover;
	output.blendingMode = NSVisualEffectBlendingModeBehindWindow;
	output.wantsLayer = YES;
	output.layer.cornerRadius = 8;
	output.layer.masksToBounds = YES;
	output.accessibilityLabel = @"Output";

	NSTextField* title = OakCreateLabel(@"Output", [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]);
	self.status = OakCreateLabel(@"", [NSFont systemFontOfSize:11]);
	self.status.textColor = NSColor.secondaryLabelColor;
	self.status.lineBreakMode = NSLineBreakByTruncatingTail;
	[self.status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[self.status setContentHuggingPriority:NSLayoutPriorityDefaultLow-1 forOrientation:NSLayoutConstraintOrientationHorizontal];

	NSTextField* channel = OakCreateLabel(@"Run & Debug", [NSFont systemFontOfSize:11]);
	channel.textColor = NSColor.secondaryLabelColor;
	self.outputPinButton = [[FloatingPanelPinButton alloc] initWithPanelName:@"Output"];
	NSButton* clear = DebugControl(@"trash", @"Clear Output", self, @selector(clearOutput:));
	NSButton* hide = DebugControl(@"xmark", @"Hide Output", self, @selector(hideOutput:));
	clear.bordered = hide.bordered = NO;
	FloatingPanelDragBar* bar = [FloatingPanelDragBar stackViewWithViews:@[ title, self.status, channel, self.outputPinButton, clear, hide ]];
	bar.alignment = NSLayoutAttributeCenterY;
	bar.spacing = 10;
	bar.toolTip = @"Drag Output to a screen edge to tuck it away";
	[bar setClippingResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];

	NSScrollView* scroll = [NSTextView scrollableTextView];
	scroll.drawsBackground = NO;
	scroll.hasVerticalScroller = YES;
	self.output = (NSTextView*)scroll.documentView;
	self.output.drawsBackground = NO;
	self.output.editable = NO;
	self.output.richText = NO;
	self.output.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
	self.output.textContainerInset = NSMakeSize(8, 5);
	self.output.accessibilityLabel = @"Run output";

	NSView* divider = OakCreateNSBoxSeparator();
	OakAddAutoLayoutViewsToSuperview(@[ bar, divider, scroll ], output);
	[NSLayoutConstraint activateConstraints:@[
		[bar.topAnchor constraintEqualToAnchor:output.topAnchor],
		[bar.leadingAnchor constraintEqualToAnchor:output.leadingAnchor constant:10],
		[bar.trailingAnchor constraintEqualToAnchor:output.trailingAnchor constant:-8],
		[bar.heightAnchor constraintEqualToConstant:32],
		[divider.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
		[divider.leadingAnchor constraintEqualToAnchor:output.leadingAnchor],
		[divider.trailingAnchor constraintEqualToAnchor:output.trailingAnchor],
		[divider.heightAnchor constraintEqualToConstant:1],
		[scroll.topAnchor constraintEqualToAnchor:divider.bottomAnchor],
		[scroll.leadingAnchor constraintEqualToAnchor:output.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:output.trailingAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor:output.bottomAnchor],
	]];
	self.outputView = output;
	self.outputDragBar = bar;
}

- (void)buildDebugToolbar
{
	self.debugToolbar = [NSBox new];
	self.debugToolbar.boxType = NSBoxCustom;
	self.debugToolbar.titlePosition = NSNoTitle;
	self.debugToolbar.contentViewMargins = NSZeroSize;
	self.debugToolbar.cornerRadius = 7;
	self.debugToolbar.fillColor = NSColor.windowBackgroundColor;
	self.debugToolbar.borderColor = NSColor.separatorColor;
	self.debugToolbar.borderWidth = 1;
	self.debugToolbar.wantsLayer = YES;
	NSShadow* shadow = [NSShadow new];
	shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:0.25];
	shadow.shadowOffset = NSMakeSize(0, -2);
	shadow.shadowBlurRadius = 8;
	self.debugToolbar.shadow = shadow;
	self.debugToolbar.accessibilityElement = YES;
	self.debugToolbar.accessibilityRole = NSAccessibilityToolbarRole;
	self.debugToolbar.accessibilityLabel = @"Debug toolbar";

	NSTextField* grip = OakCreateLabel(@"⠿", [NSFont systemFontOfSize:13 weight:NSFontWeightMedium]);
	grip.textColor = NSColor.secondaryLabelColor;
	grip.alignment = NSTextAlignmentCenter;
	grip.toolTip = @"Drag debug toolbar horizontally";
	[grip.widthAnchor constraintEqualToConstant:16].active = YES;
	[grip addGestureRecognizer:[[NSPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragDebugToolbar:)]];

	self.debugActionButton = FloatingDebugControl(@"pause.fill", @"Pause", self, @selector(pauseDebugging:));
	self.stepButtons = @[ FloatingDebugControl(@"arrow.turn.down.right", @"Step Over (F10)", self, @selector(stepOver:)),
	                      FloatingDebugControl(@"arrow.down.to.line", @"Step Into (F11)", self, @selector(stepIn:)),
	                      FloatingDebugControl(@"arrow.up.to.line", @"Step Out (Shift-F11)", self, @selector(stepOut:)) ];
	OakBackgroundFillView* separator = OakCreateVerticalLine(OakBackgroundFillViewStyleNone);
	separator.activeBackgroundColor = separator.inactiveBackgroundColor = NSColor.separatorColor;
	[separator.widthAnchor constraintEqualToConstant:1].active = YES;
	[separator.heightAnchor constraintEqualToConstant:14].active = YES;
	self.debugStopButton = FloatingDebugControl(@"stop.fill", @"Stop (Shift-F5)", self, @selector(stop:));
	self.debugStopButton.contentTintColor = NSColor.systemRedColor;
	self.debugRestartButton = FloatingDebugControl(@"arrow.clockwise", @"Restart (Control-Shift-F5)", self, @selector(restart:));

	NSStackView* actions = [NSStackView stackViewWithViews:@[ grip, self.debugActionButton, self.stepButtons[0], self.stepButtons[1],
	                                                        self.stepButtons[2], separator, self.debugRestartButton, self.debugStopButton ]];
	actions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	actions.alignment = NSLayoutAttributeCenterY;
	actions.edgeInsets = NSEdgeInsetsMake(4, 6, 4, 6);
	actions.spacing = 3;
	NSView* surface = self.debugToolbar.contentView;
	OakAddAutoLayoutViewsToSuperview(@[ actions ], surface);
	[NSLayoutConstraint activateConstraints:@[
		[actions.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor],
		[actions.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor],
		[actions.topAnchor constraintEqualToAnchor:surface.topAnchor],
		[actions.bottomAnchor constraintEqualToAnchor:surface.bottomAnchor],
	]];
}

- (void)attachDebugToolbarToView:(NSView*)container aboveEditor:(NSView*)editor
{
	(void)self.view;
	if(self.debugToolbar.superview == container)
		return;
	[self.debugToolbar removeFromSuperview];
	self.debugToolbarEditor = editor;
	self.debugToolbar.translatesAutoresizingMaskIntoConstraints = NO;
	[container addSubview:self.debugToolbar positioned:NSWindowAbove relativeTo:nil];
	self.debugToolbarCenter = [self.debugToolbar.centerXAnchor constraintEqualToAnchor:editor.centerXAnchor];
	self.debugToolbarCenter.priority = NSLayoutPriorityDefaultHigh;
	[NSLayoutConstraint activateConstraints:@[
		self.debugToolbarCenter,
		[self.debugToolbar.topAnchor constraintEqualToAnchor:editor.topAnchor constant:8],
		[self.debugToolbar.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:8],
		[self.debugToolbar.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-8],
	]];
}

- (void)dragDebugToolbar:(NSPanGestureRecognizer*)gesture
{
	NSView* container = self.debugToolbar.superview;
	if(!container)
		return;
	CGFloat inset = NSWidth(self.debugToolbar.frame)/2 + 8;
	CGFloat left = NSMinX(container.bounds) + inset;
	CGFloat right = NSMaxX(container.bounds) - inset;
	CGFloat moved = NSMidX(self.debugToolbar.frame) + [gesture translationInView:container].x;
	CGFloat center = MAX(left, MIN(right, moved));
	NSView* editor = self.debugToolbarEditor;
	self.debugToolbarCenter.constant = center - NSMidX([editor convertRect:editor.bounds toView:container]);
	[gesture setTranslation:NSZeroPoint inView:container];
	[container layoutSubtreeIfNeeded];
}

- (BOOL)isRunning { return self.session.isRunning || self.debugger.state != ProjectDebugIdle; }
- (BOOL)canStep { return self.debugger.canStep; }
- (BOOL)canRestart
{
	return self.restartAction && !self.confirming && !self.restartPending &&
	       !self.session.isStopping && self.debugger.state != ProjectDebugStopping;
}

- (void)showSidebarActions:(NSButton*)sender
{
	NSMenu* menu = [NSMenu new];
	menu.autoenablesItems = NO;
	for(NSArray* entry in @[
		@[ @"Run Without Debugging", NSStringFromSelector(@selector(run:)), @(self.configurationButton.enabled) ],
		@[ @"Start Debugging", NSStringFromSelector(@selector(debug:)), @(self.configurationButton.enabled && self.selectedConfiguration.supportsDebugging) ],
		@[ @"Restart Last Run", NSStringFromSelector(@selector(restart:)), @(self.canRestart) ],
		@[ @"Show Output", NSStringFromSelector(@selector(showOutput:)), @YES ],
		@[ @"Reload Configurations", NSStringFromSelector(@selector(refresh:)), @(!self.isRunning && !self.confirming) ],
		@[ @"Hide Run & Debug", NSStringFromSelector(@selector(hide:)), @YES ],
	])
	{
		NSMenuItem* item = [menu addItemWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""];
		item.target = self;
		item.enabled = [entry[2] boolValue];
	}
	[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:sender];
}

- (void)showConfigurations:(NSButton*)sender
{
	NSRect bounds = sender.bounds;
	CGFloat edge = sender.userInterfaceLayoutDirection == NSUserInterfaceLayoutDirectionRightToLeft ? NSMaxX(bounds) : NSMinX(bounds);
	CGFloat below = sender.isFlipped ? NSMaxY(bounds) + 4 : NSMinY(bounds) - 4;
	self.configurationMenu.minimumWidth = NSWidth(bounds);
	[self.configurationMenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(edge, below) inView:sender];
}

- (void)selectConfiguration:(NSMenuItem*)sender
{
	self.selectedConfiguration = sender.representedObject;
	self.configurationButton.title = sender.title ?: @"No run configurations";
	self.configurationButton.accessibilityValue = self.configurationButton.title;
	self.configurationButton.toolTip = sender.title;
	for(NSMenuItem* item in self.configurationMenu.itemArray)
		item.state = item == sender ? NSControlStateValueOn : NSControlStateValueOff;
	[self updateControls];
}

- (void)startSelectedConfiguration:(id)sender
{
	if(self.session.isRunning)
		[self stop:sender];
	else if(self.selectedConfiguration.supportsDebugging)
		[self debug:sender];
	else
		[self run:sender];
}

- (void)refresh:(id)sender
{
	(void)self.view;
	ProjectRunConfiguration* previous = self.selectedConfiguration;
	NSMutableArray<NSError*>* errors = [NSMutableArray array];
	NSArray* folders = self.foldersProvider ? self.foldersProvider() : @[];
	NSArray<ProjectRunConfiguration*>* configurations = [ProjectRunConfiguration configurationsForFolders:folders errors:errors];
	[self.configurationMenu removeAllItems];
	NSMenuItem* selected = nil;
	for(ProjectRunConfiguration* config in configurations)
	{
		NSString* title = folders.count > 1 ? config.title : config.task ? [config.name stringByAppendingString:@" (Task)"] : config.name;
		NSMenuItem* choice = [[NSMenuItem alloc] initWithTitle:title action:@selector(selectConfiguration:) keyEquivalent:@""];
		choice.target = self;
		choice.representedObject = config;
		choice.toolTip = config.root;
		[self.configurationMenu addItem:choice];
		if([config.identifier isEqual:previous.identifier])
			selected = choice;
	}
	[self selectConfiguration:selected ?: self.configurationMenu.itemArray.firstObject];

	if(!self.isRunning)
	{
		self.status.stringValue = errors.count ? @"Some configurations could not be loaded" :
			configurations.count ? @"Ready" : folders.count ? @"Choose Configure Run & Debug to create a launch.json." : @"Open a project folder or workspace to configure Run & Debug.";
		self.sidebarHint.stringValue = errors.count || !configurations.count ? self.status.stringValue : @"";
		for(NSError* error in errors)
			[self appendOutput:[NSString stringWithFormat:@"%@\n", error.localizedDescription]];
	}
	[self reloadBreakpoints];
}

- (void)configure:(id)sender
{
	(void)self.view;
	NSArray<NSDictionary<NSString*, NSString*>*>* folders = self.foldersProvider ? self.foldersProvider() : @[];
	if(!folders.count)
	{
		self.status.stringValue = @"Open a project folder or workspace to configure Run & Debug.";
		self.sidebarHint.stringValue = self.status.stringValue;
		return;
	}
	if(folders.count == 1)
	{
		[self configureFolder:folders.firstObject[@"path"]];
		return;
	}

	ProjectRunConfiguration* selected = self.selectedConfiguration;
	NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Configure Workspace Folder"];
	NSMenuItem* preferred = nil;
	for(NSDictionary* folder in folders)
	{
		NSMenuItem* item = [menu addItemWithTitle:folder[@"name"] action:@selector(takeConfigurationFolderFrom:) keyEquivalent:@""];
		item.target = self;
		item.representedObject = folder[@"path"];
		item.toolTip = folder[@"path"];
		if([item.representedObject isEqual:selected.root])
			preferred = item;
	}
	[menu popUpMenuPositioningItem:preferred atLocation:NSMakePoint(0, NSHeight(self.configureButton.bounds)) inView:self.configureButton];
}

- (void)takeConfigurationFolderFrom:(NSMenuItem*)sender
{
	[self configureFolder:sender.representedObject];
}

- (void)configureFolder:(NSString*)folder
{
	NSError* error = nil;
	NSURL* url = [ProjectRunConfiguration openOrCreateLaunchConfigurationInFolder:folder error:&error];
	if(!url)
	{
		self.status.stringValue = @"Could not open launch.json";
		[self appendOutput:[NSString stringWithFormat:@"%@\n", error.localizedDescription]];
		[self showOutput:nil];
		return;
	}
	[self refresh:self];
	if(self.openConfiguration)
		self.openConfiguration(url);
}

- (void)updateControls
{
	ProjectRunConfiguration* config = self.selectedConfiguration;
	self.configurationButton.enabled = !self.isRunning && !self.confirming && config != nil;
	BOOL debugging = self.debugger.state != ProjectDebugIdle;
	BOOL paused = self.debugger.state == ProjectDebugPaused;
	BOOL running = self.session.isRunning;
	self.runButton.enabled = self.configurationButton.enabled || (running && !self.session.isStopping && !debugging);
	NSString* launchAction = running ? @"Stop" : config.supportsDebugging ? @"Start Debugging (F5)" : @"Run Without Debugging (Control-F5)";
	self.runButton.image = [NSImage imageWithSystemSymbolName:running ? @"stop.fill" : @"play" accessibilityDescription:launchAction];
	self.runButton.contentTintColor = running ? NSColor.systemRedColor : NSColor.systemGreenColor;
	self.runButton.toolTip = self.runButton.accessibilityLabel = launchAction;
	self.debugToolbar.hidden = !debugging;
	self.debugStopButton.enabled = debugging && self.debugger.state != ProjectDebugStopping;
	self.debugRestartButton.enabled = self.canRestart;
	SEL action = paused ? @selector(continueDebugging:) : @selector(pauseDebugging:);
	if(self.debugActionButton.action != action)
	{
		NSString* title = paused ? @"Continue (F5)" : @"Pause";
		self.debugActionButton.image = [NSImage imageWithSystemSymbolName:paused ? @"play.fill" : @"pause.fill" accessibilityDescription:title];
		self.debugActionButton.contentTintColor = paused ? NSColor.systemGreenColor : nil;
		self.debugActionButton.toolTip = self.debugActionButton.accessibilityLabel = title;
		self.debugActionButton.action = action;
	}
	self.debugActionButton.enabled = paused ? self.canStep : self.debugger.canPause;
	self.goroutinesButton.enabled = self.canStep;
	NSNumber* goroutine = self.debugger.selectedThreadID;
	self.goroutinesButton.title = paused && goroutine ? [NSString stringWithFormat:@"Goroutine %@", goroutine] : @"Goroutines…";
	for(NSButton* button in self.stepButtons)
		button.enabled = self.canStep;
	if(!debugging)
		self.revealedPauseSections = NO;
	if(paused && !self.revealedPauseSections)
	{
		self.revealedPauseSections = YES;
		self.variableSection.expanded = YES;
		self.frameSection.expanded = YES;
	}
}

- (void)run:(id)sender { [self startSelectionForDebugging:NO]; }

- (void)debug:(id)sender
{
	if(self.canStep)
		[self.debugger continueExecution];
	else
		[self startSelectionForDebugging:YES];
}

- (void)startSelectionForDebugging:(BOOL)debugging
{
	if(self.isRunning || self.confirming)
		return;
	ProjectRunConfiguration* previous = self.selectedConfiguration;
	[self refresh:nil];
	ProjectRunConfiguration* configuration = self.selectedConfiguration;
	if(previous && ![previous.identifier isEqual:configuration.identifier])
	{
		self.status.stringValue = @"The selected configuration changed. Choose a configuration before starting.";
		self.sidebarHint.stringValue = self.status.stringValue;
		return;
	}
	if(!configuration)
	{
		[self.view.window makeFirstResponder:self.configureButton];
		return;
	}
	NSError* error = nil;
	NSString* file = self.fileProvider ? self.fileProvider() : nil;
	NSDictionary* environment = ProjectRunDefaultEnvironment();
	ProjectDebugPlan* debugPlan = debugging ? [configuration debugPlanForFile:file environment:environment error:&error] : nil;
	NSArray<ProjectRunCommand*>* commands = debugging ? (debugPlan ? [debugPlan.tasks arrayByAddingObject:debugPlan.adapter] : nil) :
		[configuration commandsForFile:file environment:environment error:&error];
	if(!commands)
	{
		self.status.stringValue = debugging ? @"Cannot debug configuration" : @"Cannot run configuration";
		[self appendOutput:[NSString stringWithFormat:@"%@\n", error.localizedDescription]];
		[self showOutput:nil];
		return;
	}

	NSMutableArray* identity = [NSMutableArray arrayWithArray:@[ configuration.root, @(debugging) ]];
	NSMutableArray* summary = [NSMutableArray array];
	for(ProjectRunCommand* command in commands)
	{
		[identity addObject:@[ command.directory, command.executable, command.arguments, command.environment ]];
		[summary addObject:[NSString stringWithFormat:@"%@\n%@", command.directory, command.displayCommand]];
	}
	if(debugPlan)
	{
		NSDictionary* launch = debugPlan.launchArguments;
		[identity addObject:launch];
		[summary addObject:[NSString stringWithFormat:@"Go target: %@\nArguments: %@",
		                    launch[@"program"], [launch[@"args"] componentsJoinedByString:@" "]]];
		if(launch[@"buildFlags"])
			[summary addObject:[NSString stringWithFormat:@"Go build flags: %@", [launch[@"buildFlags"] componentsJoinedByString:@" "]]];
	}
	NSArray* key = [identity copy];
	if([self.trustedPlans containsObject:key])
	{
		[self startCommands:commands configuration:configuration debugPlan:debugPlan];
		return;
	}

	NSAlert* alert = [NSAlert new];
	NSString* verb = debugging ? @"Debug" : @"Run";
	alert.messageText = [NSString stringWithFormat:@"%@ “%@”?", verb, configuration.title];
	alert.alertStyle = NSAlertStyleWarning;
	NSString* preview = [summary componentsJoinedByString:@"\n\n"];
	if(preview.length > 4000)
		preview = [[preview substringToIndex:4000] stringByAppendingString:@"…"];
	alert.informativeText = [NSString stringWithFormat:@"This runs local programs with your permissions. Only continue if you trust the folder and these commands.\n\n%@", preview];
	[alert addButtonWithTitle:verb];
	[alert addButtonWithTitle:@"Cancel"];
	alert.buttons.firstObject.keyEquivalent = @"";
	alert.buttons.lastObject.keyEquivalent = @"\r";
	self.confirming = YES;
	NSUInteger generation = self.trustGeneration;
	[self updateControls];
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		self.confirming = NO;
		if(response == NSAlertFirstButtonReturn && self.view.window && generation == self.trustGeneration)
		{
			[self.trustedPlans addObject:key];
			[self startCommands:commands configuration:configuration debugPlan:debugPlan];
		}
		[self updateControls];
	}];
}

- (void)startCommands:(NSArray<ProjectRunCommand*>*)commands configuration:(ProjectRunConfiguration*)configuration debugPlan:(ProjectDebugPlan*)debugPlan
{
	__weak typeof(self) weakSelf = self;
	self.restartAction = ^{ [weakSelf startCommands:commands configuration:configuration debugPlan:debugPlan]; };
	[self clearOutput:nil];
	self.pendingOutput.length = 0;
	[self resetOutputFormatting];
	[self showOutput:nil];
	if(debugPlan && !debugPlan.tasks.count)
		[self startDebugger:debugPlan];
	else
	{
		self.preparingDebugPlan = debugPlan;
		self.status.stringValue = debugPlan ? @"Running pre-launch task…" : [@"Running " stringByAppendingString:configuration.title];
		[self.session runCommands:debugPlan ? debugPlan.tasks : commands];
	}
	[self updateControls];
}

- (void)startDebugger:(ProjectDebugPlan*)plan
{
	[self appendOutput:[NSString stringWithFormat:@"$ %@\n", plan.adapter.displayCommand]];
	[self.debugger start:plan breakpoints:self.breakpointsProvider ? self.breakpointsProvider() : @{}];
}

- (void)displayFrames:(NSArray<NSDictionary*>*)frames
{
	for(NSView* row in self.frameRows.arrangedSubviews)
	{
		[self.frameRows removeArrangedSubview:row];
		[row removeFromSuperview];
	}
	for(NSUInteger index = 0; index < frames.count; ++index)
	{
		NSDictionary* frame = frames[index];
		NSString* name = [frame[@"name"] isKindOfClass:NSString.class] ? frame[@"name"] : @"Unknown frame";
		NSDictionary* source = [frame[@"source"] isKindOfClass:NSDictionary.class] ? frame[@"source"] : nil;
		NSString* path = [source[@"path"] isKindOfClass:NSString.class] ? source[@"path"] : nil;
		NSString* title = path.length ? [NSString stringWithFormat:@"%@ — %@:%@", name, path.lastPathComponent, frame[@"line"] ?: @"?"] : name;
		NSButton* row = [self addSidebarRow:title to:self.frameRows symbol:@"chevron.right" action:@selector(selectStackFrame:)];
		row.tag = index;
		row.toolTip = path ? [NSString stringWithFormat:@"%@\n%@", name, path] : name;
	}
	if(frames.count)
		[self selectStackFrameAtIndex:0];
	else
	{
		self.hasSelectedFrame = NO;
		[self refreshWatchResults];
		[self addSidebarNote:@"No paused call stack." to:self.frameRows];
	}
	[self updateControls];
}

- (void)selectStackFrame:(NSButton*)sender { [self selectStackFrameAtIndex:sender.tag]; }

- (void)selectStackFrameAtIndex:(NSUInteger)index
{
	if(index >= self.debugger.frames.count)
		return;
	NSDictionary* frame = self.debugger.frames[index];
	for(NSButton* row in self.frameRows.arrangedSubviews)
	{
		row.contentTintColor = row.tag == index ? NSColor.controlAccentColor : NSColor.labelColor;
		row.accessibilitySelected = row.tag == index;
	}
	[self.debugger selectFrame:frame];
	self.hasSelectedFrame = YES;
	[self refreshWatchResults];
	NSDictionary* source = [frame[@"source"] isKindOfClass:NSDictionary.class] ? frame[@"source"] : nil;
	NSString* path = [source[@"path"] isKindOfClass:NSString.class] ? source[@"path"] : nil;
	NSNumber* line = [frame[@"line"] isKindOfClass:NSNumber.class] ? frame[@"line"] : nil;
	if(path.isAbsolutePath && line.integerValue > 0 && self.showFrame)
		self.showFrame(path, line.unsignedIntegerValue, index == 0 && [self.debugger.selectedThreadID isEqual:self.debugger.stoppedThreadID]);
}

- (void)showGoroutines:(NSButton*)sender
{
	__weak typeof(self) weakSelf = self;
	[self.debugger loadThreads:^(NSArray<NSDictionary*>* threads, NSString* error){
		RunPanelController* panel = weakSelf;
		if(!panel || !sender.window)
			return;
		NSMenu* menu = [NSMenu new];
		for(NSDictionary* thread in threads)
		{
			NSNumber* identifier = thread[@"id"];
			NSString* label = [thread[@"name"] isKindOfClass:NSString.class] ? thread[@"name"] : @"";
			NSString* title = label.length ? label : [NSString stringWithFormat:@"Goroutine %@", identifier];
			NSMenuItem* item = [menu addItemWithTitle:title action:@selector(selectGoroutine:) keyEquivalent:@""];
			item.target = panel;
			item.representedObject = identifier;
			item.state = [identifier isEqual:panel.debugger.selectedThreadID] ? NSControlStateValueOn : NSControlStateValueOff;
		}
		if(!threads.count)
			[menu addItemWithTitle:error ?: @"No goroutines returned." action:nil keyEquivalent:@""];
		[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:sender];
	}];
}

- (void)selectGoroutine:(NSMenuItem*)sender
{
	[self.debugger selectThread:sender.representedObject];
}

- (void)displayVariables:(NSArray<NSDictionary*>*)variables
{
	[self clearDebugRows:self.variableRows];
	NSMutableDictionary<NSString*, NSStackView*>* groups = [NSMutableDictionary dictionary];
	for(NSDictionary* variable in variables)
	{
		NSString* scope = variable[@"scope"];
		NSStackView* rows = groups[scope];
		if(!rows)
		{
			rows = groups[scope] = RunSidebarStack(@[]);
			RunSidebarSection* group = [[RunSidebarSection alloc] initWithTitle:scope body:rows];
			[self addDebugRow:group to:self.variableRows];
			group.expanded = YES;
		}
		[self addDebugValue:variable to:rows depth:0];
	}
	if(!variables.count)
		[self addSidebarNote:@"No variables to show." to:self.variableRows];
}

- (void)clearDebugRows:(NSStackView*)stack
{
	for(NSView* row in stack.arrangedSubviews)
	{
		[stack removeArrangedSubview:row];
		[row removeFromSuperview];
	}
}

- (void)addDebugRow:(NSView*)row to:(NSStackView*)stack
{
	[stack addArrangedSubview:row];
	[row.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
}

- (NSButton*)addDebugValue:(NSDictionary*)value to:(NSStackView*)stack depth:(NSUInteger)depth
{
	NSString* title = [NSString stringWithFormat:@"%@ = %@", value[@"name"], value[@"value"]];
	NSNumber* reference = value[@"variablesReference"];
	NSButton* row;
	if(depth < 6 && [reference isKindOfClass:NSNumber.class] && reference.integerValue > 0)
	{
		NSStackView* children = RunSidebarStack(@[]);
		RunSidebarSection* node = [[RunSidebarSection alloc] initWithTitle:title body:children];
		node.heading.cell.lineBreakMode = NSLineBreakByTruncatingTail;
		node.heading.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
		[self addDebugRow:node to:stack];
		__weak typeof(self) weakSelf = self;
		__weak RunSidebarSection* weakNode = node;
		node.didExpand = ^{
			RunPanelController* panel = weakSelf;
			if(children.arrangedSubviews.count)
				return;
			[panel addSidebarNote:@"Loading…" to:children];
			[panel.debugger loadChildrenOfVariable:reference completion:^(NSArray* values, NSString* error){
				RunPanelController* panel = weakSelf;
				if(!panel || !weakNode)
					return;
				[panel clearDebugRows:children];
				if(!values.count)
					[panel addSidebarNote:error ?: @"No child values." to:children];
				for(NSDictionary* child in values)
					[panel addDebugValue:child to:children depth:depth + 1];
			}];
		};
		row = node.heading;
	}
	else
	{
		row = [self addSidebarRow:title to:stack symbol:@"circle" action:nil];
		row.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
	}
	row.toolTip = title;
	return row;
}

- (void)setWatchExpressions:(NSArray<NSString*>*)expressions
{
	NSMutableOrderedSet* accepted = [NSMutableOrderedSet orderedSet];
	for(id expression in expressions)
	{
		if(![expression isKindOfClass:NSString.class])
			continue;
		NSString* text = [expression stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		if(text.length && text.length <= 1024)
			[accepted addObject:text];
		if(accepted.count == 32)
			break;
	}
	_watchExpressions = accepted.array;
	[self refreshWatchResults];
}

- (void)displayWatchResults:(NSDictionary<NSString*, NSDictionary*>*)results
{
	[self clearDebugRows:self.watchRows];
	for(NSString* expression in self.watchExpressions)
	{
		NSDictionary* result = results[expression];
		NSString* message = self.hasSelectedFrame ? @"Evaluating…" : @"Not paused";
		NSMutableDictionary* value = [result mutableCopy] ?: [NSMutableDictionary dictionary];
		value[@"name"] = expression;
		value[@"value"] = result[@"result"] ?: result[@"error"] ?: message;
		NSButton* row = [self addDebugValue:value to:self.watchRows depth:0];
		if(result[@"error"])
			row.contentTintColor = NSColor.systemOrangeColor;
		NSMenu* menu = [NSMenu new];
		for(NSArray* item in @[ @[ @"Edit Expression", NSStringFromSelector(@selector(editWatchExpression:)) ],
		                         @[ @"Remove Expression", NSStringFromSelector(@selector(removeWatchExpression:)) ] ])
		{
			NSMenuItem* command = [menu addItemWithTitle:item[0] action:NSSelectorFromString(item[1]) keyEquivalent:@""];
			command.target = self;
			command.representedObject = expression;
		}
		row.menu = menu;
		row.accessibilityCustomActions = @[
			[[NSAccessibilityCustomAction alloc] initWithName:@"Edit Expression" handler:^BOOL{
				[menu performActionForItemAtIndex:0];
				return YES;
			}],
			[[NSAccessibilityCustomAction alloc] initWithName:@"Remove Expression" handler:^BOOL{
				[menu performActionForItemAtIndex:1];
				return YES;
			}],
		];
	}
}

- (void)refreshWatchResults
{
	NSUInteger revision = ++self.watchRevision;
	if(!self.watchRows)
		return;
	[self displayWatchResults:@{}];
	if(!self.hasSelectedFrame)
		return;
	NSMutableDictionary* results = [NSMutableDictionary dictionary];
	NSArray<NSString*>* expressions = self.watchExpressions;
	__weak typeof(self) weakSelf = self;
	for(NSString* expression in expressions)
	{
		[self.debugger evaluateWatchExpression:expression completion:^(NSDictionary* value, NSString* error){
			RunPanelController* panel = weakSelf;
			if(!panel || panel.watchRevision != revision)
				return;
			results[expression] = value ?: @{ @"error": error ?: @"No value returned." };
			if(results.count == expressions.count)
				[panel displayWatchResults:results];
		}];
	}
}

- (void)commitWatchExpression:(id)sender
{
	NSString* expression = [self.watchInput.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSMutableArray* expressions = [self.watchExpressions mutableCopy] ?: [NSMutableArray array];
	NSUInteger index = self.editingWatchExpression ? [expressions indexOfObject:self.editingWatchExpression] : NSNotFound;
	NSUInteger duplicate = [expressions indexOfObject:expression];
	if(!expression.length || expression.length > 1024 || (duplicate != NSNotFound && duplicate != index) || (index == NSNotFound && expressions.count >= 32))
	{
		NSBeep();
		return;
	}
	if(index == NSNotFound)
		[expressions addObject:expression];
	else
		expressions[index] = expression;
	self.editingWatchExpression = nil;
	self.watchInput.stringValue = @"";
	self.watchInput.placeholderString = @"Add expression";
	self.watchExpressions = expressions;
	if(self.watchExpressionsDidChange)
		self.watchExpressionsDidChange();
}

- (void)editWatchExpression:(NSMenuItem*)sender
{
	self.editingWatchExpression = sender.representedObject;
	self.watchInput.stringValue = self.editingWatchExpression;
	self.watchInput.placeholderString = @"Edit expression";
	[self.watchInput selectText:self];
}

- (void)removeWatchExpression:(NSMenuItem*)sender
{
	NSString* expression = sender.representedObject;
	NSMutableArray* expressions = [self.watchExpressions mutableCopy];
	[expressions removeObject:expression];
	if([self.editingWatchExpression isEqual:expression])
	{
		self.editingWatchExpression = nil;
		self.watchInput.stringValue = @"";
		self.watchInput.placeholderString = @"Add expression";
	}
	self.watchExpressions = expressions;
	if(self.watchExpressionsDidChange)
		self.watchExpressionsDidChange();
}

- (NSButton*)addSidebarRow:(NSString*)title to:(NSStackView*)stack symbol:(NSString*)symbol action:(SEL)action
{
	NSButton* row = [NSButton buttonWithTitle:title image:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] target:self action:action];
	row.bordered = NO;
	row.imagePosition = NSImageLeft;
	row.alignment = NSTextAlignmentLeft;
	row.font = [NSFont systemFontOfSize:11];
	row.cell.lineBreakMode = NSLineBreakByTruncatingMiddle;
	[row setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[stack addArrangedSubview:row];
	[NSLayoutConstraint activateConstraints:@[
		[row.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
		[row.heightAnchor constraintEqualToConstant:21],
	]];
	return row;
}

- (void)addSidebarNote:(NSString*)text to:(NSStackView*)stack
{
	NSTextField* label = [self sidebarNote:text];
	[stack addArrangedSubview:label];
	[label.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
}

- (void)reloadBreakpoints
{
	if(!self.breakpointRows)
		return;
	[self clearDebugRows:self.breakpointRows];
	NSDictionary<NSString*, NSArray<NSDictionary*>*>* entries = self.breakpointsProvider ? self.breakpointsProvider() : @{};
	for(NSString* path in [entries.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)])
	{
		for(NSDictionary* entry in entries[path])
		{
			NSNumber* line = entry[@"line"];
			BOOL enabled = ![entry[@"enabled"] isEqual:@NO];
			BOOL unverified = enabled && [self isBreakpointUnverifiedAtPath:path line:line.unsignedIntegerValue];
			NSDictionary* result = enabled ? [self.debugger breakpointResultAtPath:path line:line.unsignedIntegerValue] : nil;
			BOOL logpoint = [entry[@"logMessage"] length] > 0;
			NSString* title = [NSString stringWithFormat:@"%@:%@", path.lastPathComponent, line];
			BOOL solid = enabled && !unverified;
			NSString* symbol = logpoint ? (solid ? @"diamond.fill" : @"diamond") : (solid ? @"circle.fill" : @"circle");
			NSButton* row = [self addSidebarRow:title to:self.breakpointRows symbol:symbol action:@selector(revealBreakpoint:)];
			row.identifier = path;
			row.tag = line.integerValue;
			NSMutableString* detail = [NSMutableString stringWithFormat:@"%@:%@", path, line];
			if([entry[@"condition"] length])
				[detail appendFormat:@"\nCondition: %@", entry[@"condition"]];
			if([entry[@"hitCondition"] length])
				[detail appendFormat:@"\nHit count: %@", entry[@"hitCondition"]];
			if(logpoint)
				[detail appendFormat:@"\nLog: %@", entry[@"logMessage"]];
			if(!enabled)
				[detail appendString:@"\nDisabled"];
			else if(unverified)
				[detail appendFormat:@"\n%@", result ? result[@"message"] : @"Waiting for Delve to verify this breakpoint…"];
			else if(result && ![result[@"line"] isEqual:line])
				[detail appendFormat:@"\nVerified at line %@", result[@"line"]];
			row.toolTip = detail;
			row.accessibilityHelp = detail;
			row.contentTintColor = !enabled ? NSColor.secondaryLabelColor : unverified ? NSColor.systemOrangeColor : NSColor.systemRedColor;
			NSMenu* menu = [NSMenu new];
			NSMutableArray* actions = [NSMutableArray array];
			for(NSArray* action in @[
				@[ enabled ? @"Disable Breakpoint" : @"Enable Breakpoint", NSStringFromSelector(@selector(toggleSidebarBreakpoint:)) ],
				@[ @"Edit Breakpoint…", NSStringFromSelector(@selector(editSidebarBreakpoint:)) ],
				@[ @"Remove Breakpoint", NSStringFromSelector(@selector(removeSidebarBreakpoint:)) ],
			])
			{
				NSMenuItem* item = [menu addItemWithTitle:action[0] action:NSSelectorFromString(action[1]) keyEquivalent:@""];
				item.target = self;
				item.representedObject = @[ path, line ];
				NSInteger index = menu.numberOfItems - 1;
				[actions addObject:[[NSAccessibilityCustomAction alloc] initWithName:action[0] handler:^BOOL{
					[menu performActionForItemAtIndex:index];
					return YES;
				}]];
			}
			row.menu = menu;
			row.accessibilityCustomActions = actions;
		}
	}
	if(!entries.count)
		[self addSidebarNote:@"No breakpoints. Press F9 in a Go file to add one." to:self.breakpointRows];
}

- (void)refreshBreakpointResults
{
	[self reloadBreakpoints];
	if(self.breakpointResultsDidChange)
		self.breakpointResultsDidChange();
}

- (BOOL)isBreakpointUnverifiedAtPath:(NSString*)path line:(NSUInteger)line
{
	return self.debugger.state != ProjectDebugIdle && self.debugger.state != ProjectDebugStopping &&
	       ![[self.debugger breakpointResultAtPath:path line:line][@"verified"] isEqual:@YES];
}

- (void)revealBreakpoint:(NSButton*)sender
{
	if(self.showFrame)
	{
		NSDictionary* result = [self.debugger breakpointResultAtPath:sender.identifier line:sender.tag];
		NSUInteger line = [result[@"verified"] isEqual:@YES] ? [result[@"line"] unsignedIntegerValue] : sender.tag;
		self.showFrame(sender.identifier, line, NO);
	}
}

- (NSDictionary*)breakpointAtPath:(NSString*)path line:(NSNumber*)line
{
	for(NSDictionary* breakpoint in self.breakpointsProvider ? self.breakpointsProvider()[path] : nil)
	{
		if([breakpoint[@"line"] isEqual:line])
			return breakpoint;
	}
	return nil;
}

- (void)toggleSidebarBreakpoint:(NSMenuItem*)sender
{
	NSArray* location = sender.representedObject;
	NSString* path = location[0];
	NSNumber* line = location[1];
	NSMutableDictionary* breakpoint = [[self breakpointAtPath:path line:line] mutableCopy];
	if(breakpoint && self.updateBreakpoint)
	{
		breakpoint[@"enabled"] = @([breakpoint[@"enabled"] isEqual:@NO]);
		self.updateBreakpoint(path, line.unsignedIntegerValue, breakpoint);
	}
}

- (void)removeSidebarBreakpoint:(NSMenuItem*)sender
{
	NSArray* location = sender.representedObject;
	if(self.updateBreakpoint)
		self.updateBreakpoint(location[0], [location[1] unsignedIntegerValue], nil);
}

- (void)editSidebarBreakpoint:(NSMenuItem*)sender
{
	NSArray* location = sender.representedObject;
	NSString* path = location[0];
	NSNumber* line = location[1];
	NSDictionary* breakpoint = [self breakpointAtPath:path line:line];
	if(!breakpoint || !self.view.window)
		return;
	NSAlert* alert = [NSAlert new];
	alert.messageText = [NSString stringWithFormat:@"Edit Breakpoint — %@:%@", path.lastPathComponent, line];
	alert.informativeText = @"Leave fields blank for an ordinary breakpoint. A log message prints to Output instead of pausing.";
	NSArray* keys = @[ @"condition", @"hitCondition", @"logMessage" ];
	NSArray* labels = @[ @"Condition", @"Hit Count", @"Log Message" ];
	NSArray* examples = @[ @"value > 0", @">= 3", @"value = {value}" ];
	NSMutableArray<NSTextField*>* fields = [NSMutableArray array];
	NSView* editor = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 330, 81)];
	for(NSUInteger index = 0; index < keys.count; ++index)
	{
		CGFloat baseline = (keys.count - index - 1) * 27;
		NSTextField* label = OakCreateLabel(labels[index], [NSFont systemFontOfSize:12]);
		label.frame = NSMakeRect(0, baseline + 4, 90, 18);
		NSTextField* field = [NSTextField textFieldWithString:breakpoint[keys[index]] ?: @""];
		field.frame = NSMakeRect(94, baseline + 1, 236, 23);
		field.accessibilityLabel = labels[index];
		field.placeholderString = examples[index];
		[editor addSubview:label];
		[editor addSubview:field];
		if(fields.count)
			fields.lastObject.nextKeyView = field;
		[fields addObject:field];
	}
	[alert addButtonWithTitle:@"Save"];
	[alert addButtonWithTitle:@"Cancel"];
	alert.accessoryView = editor;
	[alert.window setInitialFirstResponder:fields.firstObject];
	NSUInteger generation = self.trustGeneration;
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		if(response != NSAlertFirstButtonReturn || generation != self.trustGeneration || !self.updateBreakpoint)
			return;
		NSMutableDictionary* updated = [[self breakpointAtPath:path line:line] mutableCopy];
		if(!updated)
			return;
		for(NSUInteger index = 0; index < keys.count; ++index)
		{
			NSString* text = [fields[index].stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
			updated[keys[index]] = text.length ? text : nil;
		}
		self.updateBreakpoint(path, line.unsignedIntegerValue, updated);
	}];
}

- (void)setBreakpoints:(NSArray<NSDictionary*>*)breakpoints forPath:(NSString*)path
{
	[self.debugger setBreakpoints:breakpoints forPath:path];
	[self reloadBreakpoints];
}
- (void)continueDebugging:(id)sender { [self.debugger continueExecution]; }
- (void)pauseDebugging:(id)sender { [self.debugger pause]; }
- (void)stepOver:(id)sender { [self.debugger stepOver]; }
- (void)stepIn:(id)sender { [self.debugger stepIn]; }
- (void)stepOut:(id)sender { [self.debugger stepOut]; }

- (void)stop:(id)sender
{
	self.restartPending = NO;
	[self stopActiveSession];
}

- (void)restart:(id)sender
{
	if(!self.canRestart)
		return;
	self.restartPending = YES;
	if(self.isRunning)
		[self stopActiveSession];
	else
		[self restartWhenIdle];
}

- (void)restartWhenIdle
{
	if(!self.restartPending || self.isRunning)
		return;
	self.restartPending = NO;
	void (^action)(void) = self.restartAction;
	if(action)
		action();
}

- (void)stopActiveSession
{
	if(!self.isRunning)
		return;
	if(self.debugger.state != ProjectDebugIdle)
		[self.debugger stop];
	else
	{
		[self.session stop];
		self.status.stringValue = @"Stopping…";
	}
	[self updateControls];
}

- (void)hide:(id)sender
{
	if(self.hideHandler)
		self.hideHandler();
}

- (void)showOutput:(id)sender { if(self.showOutputHandler) self.showOutputHandler(); }
- (void)showOutputInWindow:(NSWindow*)window
{
	if(!self.outputPanel)
	{
		(void)self.view;
		self.outputPanel = [[FloatingPanel alloc] initWithContentView:self.outputView title:@"Run & Debug Output"];
		self.outputDragBar.panel = self.outputPanel;
		self.outputPinButton.panel = self.outputPanel;
	}
	[self.outputPanel showInWindow:window];
}
- (void)hideOutput:(id)sender { [self.outputPanel dismiss]; }
- (void)clearOutput:(id)sender
{
	self.output.string = @"";
}

- (void)resetTrust
{
	++self.trustGeneration;
	[self.trustedPlans removeAllObjects];
	self.restartPending = NO;
	self.restartAction = nil;
	[self updateControls];
}

- (void)invalidate
{
	[self.outputPanel dismiss];
	self.preparingDebugPlan = nil;
	[self.debugToolbar removeFromSuperview];
	self.debugToolbarCenter = nil;
	[self.debugger invalidate];
	[self.session invalidate];
	[self resetTrust];
}

- (void)consumeOutput:(NSData*)data
{
	[self.pendingOutput appendData:data];
	auto bytes = static_cast<unsigned char const*>(self.pendingOutput.bytes);
	NSUInteger length = self.pendingOutput.length;
	for(NSUInteger missing = 1; missing <= MIN(length, 4UL); ++missing)
	{
		unsigned char ch = bytes[length-missing];
		if((ch & 0xc0) == 0x80)
			continue;
		NSUInteger width = (ch & 0xe0) == 0xc0 ? 2 : (ch & 0xf0) == 0xe0 ? 3 : (ch & 0xf8) == 0xf0 ? 4 : 1;
		if(width > missing)
			length -= missing;
		break;
	}
	if(length)
	{
		NSData* complete = [self.pendingOutput subdataWithRange:NSMakeRange(0, length)];
		[self.pendingOutput replaceBytesInRange:NSMakeRange(0, length) withBytes:nil length:0];
		[self consumeOutputText:[[NSString alloc] initWithData:complete encoding:NSUTF8StringEncoding] ?:
		                        [[NSString alloc] initWithData:complete encoding:NSISOLatin1StringEncoding]];
	}
}

- (void)flushOutput
{
	if(self.pendingOutput.length)
		[self consumeOutputText:[[NSString alloc] initWithData:self.pendingOutput encoding:NSISOLatin1StringEncoding]];
	self.pendingOutput.length = 0;
	[self resetOutputFormatting];
}

- (void)resetOutputFormatting
{
	_outputEscapeState = RunOutputEscapeState::Text;
	_outputColorParameters = nil;
	_outputForeground = nil;
}

- (void)applyOutputColorParameters
{
	NSArray<NSString*>* parameters = [_outputColorParameters componentsSeparatedByString:@";"];
	for(NSUInteger index = 0; index < parameters.count; ++index)
	{
		NSInteger code = parameters[index].integerValue;
		if(code == 0 || code == 39)
			_outputForeground = nil;
		else if(code >= 30 && code <= 37)
			_outputForeground = RunOutputIndexedColor(code-30);
		else if(code >= 90 && code <= 97)
			_outputForeground = RunOutputIndexedColor(code-90+8);
		else if(code == 38 || code == 48 || code == 58)
		{
			if(++index == parameters.count)
				break;
			NSInteger mode = parameters[index].integerValue;
			NSUInteger width = mode == 5 ? 1 : mode == 2 ? 3 : 0;
			if(!width || parameters.count-index-1 < width)
				break;
			if(code == 38)
			{
				NSColor* color = mode == 5 ? RunOutputIndexedColor(parameters[index+1].integerValue) :
				                 RunOutputRGBColor(parameters[index+1].integerValue, parameters[index+2].integerValue,
				                                   parameters[index+3].integerValue);
				if(color)
					_outputForeground = color;
			}
			index += width;
		}
	}
}

- (void)consumeOutputText:(NSString*)text
{
	NSMutableAttributedString* runs = nil;
	NSUInteger length = text.length;
	for(NSUInteger index = 0; index < length;)
	{
		if(_outputEscapeState == RunOutputEscapeState::Text)
		{
			NSRange escape = [text rangeOfString:@"\033" options:NSLiteralSearch range:NSMakeRange(index, length-index)];
			NSUInteger end = escape.location == NSNotFound ? length : escape.location;
			if(index == 0 && end == length)
			{
				[self appendOutputRuns:[self outputRunForText:text foreground:_outputForeground]];
				return;
			}
			if(end > index)
			{
				if(!runs)
					runs = [NSMutableAttributedString new];
				[runs appendAttributedString:[self outputRunForText:[text substringWithRange:NSMakeRange(index, end-index)]
				                                         foreground:_outputForeground]];
			}
			index = end;
			if(index < length)
			{
				_outputEscapeState = RunOutputEscapeState::Escape;
				++index;
			}
		}
		else
		{
			unichar character = [text characterAtIndex:index];
			if(_outputEscapeState == RunOutputEscapeState::Escape && character == '[')
			{
				_outputEscapeState = RunOutputEscapeState::CSI;
				_outputColorParameters = [NSMutableString string];
				++index;
			}
			else if(_outputEscapeState == RunOutputEscapeState::CSI && character >= ' ' && character <= '~')
			{
				if(character >= '@')
				{
					if(character == 'm' && _outputColorParameters)
						[self applyOutputColorParameters];
					_outputEscapeState = RunOutputEscapeState::Text;
					_outputColorParameters = nil;
				}
				else if((character == ';' || (character >= '0' && character <= '9')) && _outputColorParameters.length < 128)
					[_outputColorParameters appendFormat:@"%C", character];
				else
					_outputColorParameters = nil;
				++index;
			}
			else
			{
				_outputEscapeState = RunOutputEscapeState::Text;
				_outputColorParameters = nil;
			}
		}
	}
	[self appendOutputRuns:runs];
}

- (NSAttributedString*)outputRunForText:(NSString*)text foreground:(NSColor*)color
{
	return [[NSAttributedString alloc] initWithString:text attributes:@{
		NSFontAttributeName: self.output.font, NSForegroundColorAttributeName: color ?: NSColor.textColor
	}];
}

- (void)appendOutput:(NSString*)text
{
	if(text.length)
		[self appendOutputRuns:[self outputRunForText:text foreground:nil]];
}

- (void)appendOutputRuns:(NSAttributedString*)runs
{
	if(!runs.length)
		return;
	NSTextStorage* storage = self.output.textStorage;
	NSScrollView* scroll = self.output.enclosingScrollView;
	BOOL follow = NSMaxY(scroll.contentView.bounds) >= NSHeight(self.output.bounds) - 12;
	[storage beginEditing];
	[storage appendAttributedString:runs];
	if(storage.length > 400000)
	{
		NSRange removed = [storage.string rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, storage.length-350000)];
		[storage deleteCharactersInRange:removed];
	}
	[storage endEditing];
	if(follow)
		[self.output scrollRangeToVisible:NSMakeRange(storage.length, 0)];
}
@end
