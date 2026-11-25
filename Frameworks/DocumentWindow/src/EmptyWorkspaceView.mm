#import "EmptyWorkspaceView.h"
#include <algorithm>

static CGFloat const kSectionHeaderHeight = 25;

@interface EmptyWorkspaceCanvas : NSView
@end

@implementation EmptyWorkspaceCanvas
- (BOOL)isFlipped { return YES; }
@end

static NSTextField* workspace_label (NSString* text, CGFloat size, NSFontWeight weight, NSColor* color)
{
	NSTextField* label = [NSTextField labelWithString:text];
	label.font = [NSFont systemFontOfSize:size weight:weight];
	label.textColor = color;
	label.maximumNumberOfLines = 1;
	label.lineBreakMode = NSLineBreakByTruncatingTail;
	return label;
}

@implementation EmptyWorkspaceCommandButton
{
	NSTextField* _name;
	NSTextField* _shortcut;
	NSBox* _keycap;
	NSMenuItem* _menuItem;
	NSTrackingArea* _hoverArea;
	BOOL _hovered;
}

- (instancetype)initWithName:(NSString*)name shortcut:(NSString*)shortcut menuItem:(NSMenuItem*)item
{
	if(self = [super initWithFrame:NSZeroRect])
	{
		_menuItem = item;
		self.title = @"";
		self.bordered = NO;
		self.target = self;
		self.action = @selector(performMenuAction:);
		self.accessibilityLabel = name;
		_name = workspace_label(name, 13, NSFontWeightRegular, NSColor.labelColor);
		_shortcut = workspace_label(shortcut, 12, NSFontWeightMedium, NSColor.labelColor);
		_shortcut.alignment = NSTextAlignmentCenter;
		_keycap = [NSBox new];
		_keycap.boxType = NSBoxCustom;
		_keycap.fillColor = NSColor.quaternaryLabelColor;
		_keycap.borderWidth = 0;
		_keycap.cornerRadius = 4;
		_keycap.contentViewMargins = NSZeroSize;
		_keycap.hidden = !shortcut.length;
		[_keycap.contentView addSubview:_shortcut];
		[self addSubview:_name];
		[self addSubview:_keycap];
	}
	return self;
}

- (void)performMenuAction:(id)sender
{
	SEL action = _menuItem.action;
	if(!action)
		return;
	id target = _menuItem.target;
	if(!target && [self.window.delegate respondsToSelector:action])
		target = self.window.delegate;
	target = [NSApp targetForAction:action to:target from:_menuItem];
	if(!target)
		return;
	BOOL enabled = _menuItem.enabled;
	if(_menuItem.menu.autoenablesItems)
	{
		if([target respondsToSelector:@selector(validateMenuItem:)])
			enabled = [(id<NSMenuItemValidation>)target validateMenuItem:[_menuItem copy]];
		else if([target respondsToSelector:@selector(validateUserInterfaceItem:)])
			enabled = [(id<NSUserInterfaceValidations>)target validateUserInterfaceItem:_menuItem];
		else
			enabled = YES;
	}
	if(enabled)
		[NSApp sendAction:action to:target from:_menuItem];
}

- (NSView*)hitTest:(NSPoint)point
{
	return [super hitTest:point] ? self : nil;
}

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if(_hoverArea)
		[self removeTrackingArea:_hoverArea];
	_hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil];
	[self addTrackingArea:_hoverArea];
}

- (void)mouseEntered:(NSEvent*)event
{
	_hovered = YES;
	self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent*)event
{
	_hovered = NO;
	self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
	if(_hovered || self.highlighted)
	{
		[[NSColor.labelColor colorWithAlphaComponent:self.highlighted ? 0.14 : 0.08] setFill];
		[[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0, 1) xRadius:5 yRadius:5] fill];
	}
	[super drawRect:dirtyRect];
}

- (NSRect)focusRingMaskBounds { return NSInsetRect(self.bounds, 0, 1); }
- (void)drawFocusRingMask
{
	[[NSBezierPath bezierPathWithRoundedRect:self.focusRingMaskBounds xRadius:5 yRadius:5] fill];
}

- (void)layout
{
	[super layout];
	CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
	NSSize keys = _shortcut.intrinsicContentSize;
	CGFloat keycapWidth = _keycap.hidden ? 0 : MIN(ceil(keys.width) + 12, floor(width * 0.45));
	CGFloat keycapHeight = ceil(keys.height) + 2;
	_keycap.frame = NSMakeRect(width - keycapWidth, floor((height - keycapHeight) / 2), keycapWidth, keycapHeight);
	_shortcut.frame = NSMakeRect(3, 1, MAX(0, keycapWidth - 6), keys.height);
	CGFloat nameHeight = _name.intrinsicContentSize.height;
	_name.frame = NSMakeRect(0, floor((height - nameHeight) / 2), MAX(0, width - (keycapWidth ? keycapWidth + 12 : 0)), nameHeight);
}
@end

@interface EmptyWorkspaceShortcutSection : EmptyWorkspaceCanvas
@property (nonatomic, readonly) NSArray<EmptyWorkspaceCommandButton*>* rows;
- (instancetype)initWithTitle:(NSString*)title commands:(NSArray<EmptyWorkspaceCommandButton*>*)commands;
- (void)layoutRowsWithHeight:(CGFloat)rowHeight;
@end

@implementation EmptyWorkspaceShortcutSection
{
	NSTextField* _title;
	NSBox* _separator;
}

- (instancetype)initWithTitle:(NSString*)title commands:(NSArray<EmptyWorkspaceCommandButton*>*)commands
{
	if(self = [super initWithFrame:NSZeroRect])
	{
		_title = workspace_label(title, 12, NSFontWeightSemibold, NSColor.secondaryLabelColor);
		[self addSubview:_title];
		_separator = [NSBox new];
		_separator.boxType = NSBoxSeparator;
		[self addSubview:_separator];
		_rows = [commands copy];
		for(EmptyWorkspaceCommandButton* row in _rows)
			[self addSubview:row];
	}
	return self;
}

- (void)layoutRowsWithHeight:(CGFloat)rowHeight
{
	CGFloat width = NSWidth(self.bounds);
	_title.frame = NSMakeRect(0, 0, width, _title.intrinsicContentSize.height);
	_separator.frame = NSMakeRect(0, 20, width, 1);
	CGFloat y = kSectionHeaderHeight;
	for(EmptyWorkspaceCommandButton* row in _rows)
	{
		row.frame = NSMakeRect(0, y, width, rowHeight);
		[row setNeedsLayout:YES];
		y += rowHeight;
	}
}
@end

@implementation EmptyWorkspaceView
{
	NSTextField* _descriptionLabel;
	EmptyWorkspaceShortcutSection* _files;
	EmptyWorkspaceShortcutSection* _tools;
}

- (instancetype)initWithFrame:(NSRect)frame
{
	if(self = [super initWithFrame:frame])
	{
		self.drawsBackground = YES;
		self.hasVerticalScroller = YES;
		self.scrollerStyle = NSScrollerStyleOverlay;
		self.autohidesScrollers = YES;
		self.verticalScrollElasticity = NSScrollElasticityNone;
		self.documentView = [EmptyWorkspaceCanvas new];
		_heading = workspace_label(@"", 24, NSFontWeightSemibold, NSColor.labelColor);
		_heading.alignment = NSTextAlignmentCenter;
		_descriptionLabel = [NSTextField wrappingLabelWithString:@""];
		_descriptionLabel.alignment = NSTextAlignmentCenter;
		_descriptionLabel.font = [NSFont systemFontOfSize:13];
		_descriptionLabel.textColor = NSColor.secondaryLabelColor;
		[self.documentView addSubview:_heading];
		[self.documentView addSubview:_descriptionLabel];
		[self setProjectOpen:NO];
	}
	return self;
}

- (void)setProjectOpen:(BOOL)projectOpen
{
	_heading.stringValue = projectOpen ? @"No open tabs" : @"No project open";
	_descriptionLabel.stringValue = projectOpen ? @"Open a project file or create a new tab." : @"Open a folder or create a new document.";
	[self setNeedsLayout:YES];
}

- (void)setFileCommands:(NSArray<EmptyWorkspaceCommandButton*>*)files toolCommands:(NSArray<EmptyWorkspaceCommandButton*>*)tools
{
	[_files removeFromSuperview];
	[_tools removeFromSuperview];
	_files = files.count ? [[EmptyWorkspaceShortcutSection alloc] initWithTitle:@"Files & Projects" commands:files] : nil;
	_tools = tools.count ? [[EmptyWorkspaceShortcutSection alloc] initWithTitle:@"Tools & Panels" commands:tools] : nil;
	if(_files)
		[self.documentView addSubview:_files];
	if(_tools)
		[self.documentView addSubview:_tools];
	[self setNeedsLayout:YES];
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	[self setNeedsLayout:YES];
}

- (void)layout
{
	[super layout];
	NSSize viewport = self.contentView.bounds.size;
	if(viewport.width <= 0 || viewport.height <= 0)
		return;

	CGFloat availableWidth = MAX(0, viewport.width - 40);
	BOOL sideBySide = _files && _tools && availableWidth >= 460;
	CGFloat width = MIN(availableWidth, sideBySide ? 520 : 344);
	CGFloat x = floor((viewport.width - width) / 2);
	CGFloat titleHeight = ceil(_heading.intrinsicContentSize.height);
	_descriptionLabel.preferredMaxLayoutWidth = width;
	CGFloat descriptionHeight = ceil(_descriptionLabel.intrinsicContentSize.height);
	CGFloat introductionHeight = titleHeight + 7 + descriptionHeight;
	CGFloat introductionGap = viewport.height >= 360 ? 26 : 16;
	CGFloat sectionGap = sideBySide ? 28 : 14;
	NSUInteger columns = sideBySide ? 2 : 1;
	NSUInteger sectionCount = (_files != nil) + (_tools != nil);
	NSUInteger sectionLines = sideBySide ? 1 : sectionCount;
	NSUInteger rowCount = sideBySide ? MAX(_files.rows.count, _tools.rows.count) : _files.rows.count + _tools.rows.count;
	CGFloat fixedHeight = introductionHeight + (sectionCount ? introductionGap + sectionLines * kSectionHeaderHeight + (sectionLines - 1) * sectionGap : 0);
	CGFloat rowHeight = rowCount ? std::clamp(floor((viewport.height - fixedHeight - 24) / rowCount), 21.0, 30.0) : 0;
	CGFloat height = fixedHeight + rowCount * rowHeight;
	CGFloat canvasHeight = MAX(viewport.height, height + 24);
	[self.documentView setFrameSize:NSMakeSize(viewport.width, canvasHeight)];

	CGFloat y = floor((canvasHeight - height) / 2);
	_heading.frame = NSMakeRect(x, y, width, titleHeight);
	_descriptionLabel.frame = NSMakeRect(x, y + titleHeight + 7, width, descriptionHeight);
	y += introductionHeight + introductionGap;
	CGFloat sectionWidth = (width - (columns - 1) * sectionGap) / columns;
	for(EmptyWorkspaceShortcutSection* section : { _files, _tools })
	{
		if(!section)
			continue;
		CGFloat sectionHeight = kSectionHeaderHeight + section.rows.count * rowHeight;
		section.frame = NSMakeRect(x, y, sectionWidth, sectionHeight);
		[section layoutRowsWithHeight:rowHeight];
		if(sideBySide)
			x += sectionWidth + sectionGap;
		else
			y += sectionHeight + sectionGap;
	}
}
@end
