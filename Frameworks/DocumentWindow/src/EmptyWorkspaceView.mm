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

@interface EmptyWorkspaceShortcutRow : NSView
@property (nonatomic, readonly) NSTextField* name;
@property (nonatomic, readonly) NSTextField* shortcut;
- (instancetype)initWithName:(NSString*)name shortcut:(NSString*)shortcut;
@end

@implementation EmptyWorkspaceShortcutRow
{
	NSBox* _keycap;
}

- (instancetype)initWithName:(NSString*)name shortcut:(NSString*)shortcut
{
	if(self = [super initWithFrame:NSZeroRect])
	{
		_name = workspace_label(name, 13, NSFontWeightRegular, NSColor.labelColor);
		_shortcut = workspace_label(shortcut, 12, NSFontWeightMedium, NSColor.labelColor);
		_shortcut.alignment = NSTextAlignmentCenter;
		_keycap = [NSBox new];
		_keycap.boxType = NSBoxCustom;
		_keycap.fillColor = NSColor.quaternaryLabelColor;
		_keycap.borderWidth = 0;
		_keycap.cornerRadius = 4;
		_keycap.contentViewMargins = NSZeroSize;
		[_keycap.contentView addSubview:_shortcut];
		[self addSubview:_name];
		[self addSubview:_keycap];
	}
	return self;
}

- (void)layout
{
	[super layout];
	CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
	NSSize keys = _shortcut.intrinsicContentSize;
	CGFloat keycapWidth = MIN(ceil(keys.width) + 12, floor(width * 0.45));
	CGFloat keycapHeight = ceil(keys.height) + 2;
	_keycap.frame = NSMakeRect(width - keycapWidth, floor((height - keycapHeight) / 2), keycapWidth, keycapHeight);
	_shortcut.frame = NSMakeRect(3, 1, MAX(0, keycapWidth - 6), keys.height);
	CGFloat nameHeight = _name.intrinsicContentSize.height;
	_name.frame = NSMakeRect(0, floor((height - nameHeight) / 2), MAX(0, width - keycapWidth - 12), nameHeight);
}
@end

@interface EmptyWorkspaceShortcutSection : EmptyWorkspaceCanvas
@property (nonatomic, readonly) NSArray<EmptyWorkspaceShortcutRow*>* rows;
- (instancetype)initWithTitle:(NSString*)title shortcuts:(NSArray<NSArray<NSString*>*>*)shortcuts;
- (void)layoutRowsWithHeight:(CGFloat)rowHeight;
@end

@implementation EmptyWorkspaceShortcutSection
{
	NSTextField* _title;
	NSBox* _separator;
}

- (instancetype)initWithTitle:(NSString*)title shortcuts:(NSArray<NSArray<NSString*>*>*)shortcuts
{
	if(self = [super initWithFrame:NSZeroRect])
	{
		_title = workspace_label(title, 12, NSFontWeightSemibold, NSColor.secondaryLabelColor);
		[self addSubview:_title];
		_separator = [NSBox new];
		_separator.boxType = NSBoxSeparator;
		[self addSubview:_separator];
		NSMutableArray* rows = [NSMutableArray array];
		for(NSArray<NSString*>* pair in shortcuts)
		{
			EmptyWorkspaceShortcutRow* row = [[EmptyWorkspaceShortcutRow alloc] initWithName:pair[0] shortcut:pair[1]];
			[self addSubview:row];
			[rows addObject:row];
		}
		_rows = [rows copy];
	}
	return self;
}

- (void)layoutRowsWithHeight:(CGFloat)rowHeight
{
	CGFloat width = NSWidth(self.bounds);
	_title.frame = NSMakeRect(0, 0, width, _title.intrinsicContentSize.height);
	_separator.frame = NSMakeRect(0, 20, width, 1);
	CGFloat y = kSectionHeaderHeight;
	for(EmptyWorkspaceShortcutRow* row in _rows)
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
		self.drawsBackground = NO;
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

- (void)setFileShortcuts:(NSArray<NSArray<NSString*>*>*)files toolShortcuts:(NSArray<NSArray<NSString*>*>*)tools
{
	[_files removeFromSuperview];
	[_tools removeFromSuperview];
	_files = files.count ? [[EmptyWorkspaceShortcutSection alloc] initWithTitle:@"Files & Projects" shortcuts:files] : nil;
	_tools = tools.count ? [[EmptyWorkspaceShortcutSection alloc] initWithTitle:@"Tools & Panels" shortcuts:tools] : nil;
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
