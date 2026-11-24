#import "GitDiffView.h"
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <bundles/bundles.h>
#import <file/type.h>
#import <parse/grammar.h>
#import <parse/parse.h>
#import <text/utf16.h>
#import <theme/OakTheme.h>

namespace {
NSString* const DiffLine = @"TextMateDiffLine";
NSString* const DiffBand = @"TextMateDiffBand";
constexpr CGFloat CodeHeight = 19, ChunkHeight = 32, SummaryHeight = 37, BottomPadding = 16;
constexpr CGFloat GutterColumn = 41, HeaderInset = 20;

NSColor* DiffColor(NSString* name, unsigned light, unsigned dark)
{
	return [NSColor colorWithName:name dynamicProvider:^NSColor*(NSAppearance* appearance){
		unsigned rgb = [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqual:NSAppearanceNameDarkAqua] ? dark : light;
		return [NSColor colorWithSRGBRed:(rgb >> 16)/255.0 green:((rgb >> 8)&255)/255.0 blue:(rgb&255)/255.0 alpha:1];
	}];
}
NSColor* DiffBackground() { static NSColor* c = DiffColor(@"DiffBackground", 0xFFFFFF, 0x26292A); return c; }
NSColor* DiffTitleFill()  { static NSColor* c = DiffColor(@"DiffTitleFill", 0xFFFFFF, 0x292B2C); return c; }
NSColor* DiffHeader()     { static NSColor* c = DiffColor(@"DiffHeader", 0xF5F5F5, 0x1E1E1E); return c; }
NSColor* DiffGutter()     { static NSColor* c = DiffColor(@"DiffGutter", 0xFAFAFA, 0x28292A); return c; }
NSColor* DiffBandRule()   { static NSColor* c = DiffColor(@"DiffBandRule", 0xDEDEDE, 0x363636); return c; }
NSColor* DiffGutterRule() { static NSColor* c = DiffColor(@"DiffGutterRule", 0xEAEAEA, 0x333536); return c; }
NSColor* DiffNumber()     { static NSColor* c = DiffColor(@"DiffNumber", 0x777777, 0x858585); return c; }
NSColor* DiffCodeText()   { static NSColor* c = DiffColor(@"DiffCodeText", 0x252525, 0xABABA8); return c; }
NSColor* DiffAnnotation() { static NSColor* c = DiffColor(@"DiffAnnotation", 0x537187, 0x657581); return c; }
NSColor* DiffNumeral()    { static NSColor* c = DiffColor(@"DiffNumeral", 0x774E0A, 0xD5BC68); return c; }
NSColor* DiffAddition()   { static NSColor* c = DiffColor(@"DiffAddition", 0xE5F4E6, 0x2B392E); return c; }
NSColor* DiffDeletion()   { static NSColor* c = DiffColor(@"DiffDeletion", 0xFCEBE8, 0x3D2E2A); return c; }
NSColor* DiffAddedText()  { static NSColor* c = DiffColor(@"DiffAddedText", 0xB3E6B9, 0x3C6140); return c; }
NSColor* DiffRemovedText(){ static NSColor* c = DiffColor(@"DiffRemovedText", 0xF3BCB4, 0x633D36); return c; }
NSColor* DiffAddedEdge()  { static NSColor* c = DiffColor(@"DiffAddedEdge", 0x93C89A, 0x37653B); return c; }
NSColor* DiffRemovedEdge(){ static NSColor* c = DiffColor(@"DiffRemovedEdge", 0xDCABA5, 0x803C32); return c; }

NSFont* DiffFont() { return [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]; }

NSArray<NSString*>* PatchLines(NSString* text)
{
	if(!text.length) return @[];
	// A patch's record separator is LF, even when the file uses CRLF.
	if([text hasSuffix:@"\n"]) text = [text substringToIndex:text.length-1];
	return [text componentsSeparatedByString:@"\n"];
}

struct HunkRange { NSInteger line = 0, count = 1; };

BOOL ReadHunkHeader(NSString* line, HunkRange& before, HunkRange& after)
{
	if(![line hasPrefix:@"@@ -"]) return NO;
	char const* input = line.UTF8String + 4;
	auto readRange = [&](HunkRange& range){
		char* end;
		range.line = strtol(input, &end, 10);
		if(end == input || range.line < 0 || range.line == LONG_MAX) return false;
		range.count = 1;
		input = end;
		if(*input == ',') {
			++input;
			range.count = strtol(input, &end, 10);
			if(end == input || range.count < 0 || range.count == LONG_MAX) return false;
			input = end;
		}
		return true;
	};
	if(!readRange(before) || strncmp(input, " +", 2)) return NO;
	input += 2;
	return readRange(after) && strncmp(input, " @@", 3) == 0;
}

NSString* DiffSummary(NSUInteger chunks, NSUInteger insertions, NSUInteger deletions)
{
	return [NSString stringWithFormat:@"%lu %@, %lu %@, %lu %@", (unsigned long)chunks, chunks == 1 ? @"chunk" : @"chunks",
		(unsigned long)insertions, insertions == 1 ? @"insertion" : @"insertions", (unsigned long)deletions, deletions == 1 ? @"deletion" : @"deletions"];
}

struct PatchShape
{
	NSUInteger chunks = 0, additions = 0, deletions = 0, codeLines = 0, files = 0;
	explicit PatchShape(NSArray<NSString*>* lines)
	{
		BOOL inHunk = NO;
		for(NSString* line in lines) {
			HunkRange before, after;
			if([line hasPrefix:@"diff --git "]) { ++files; inHunk = NO; }
			else if(ReadHunkHeader(line, before, after)) { ++chunks; inHunk = YES; }
			else if(inHunk && line.length) {
				unichar kind = [line characterAtIndex:0];
				if(kind == '+' || kind == '-' || kind == ' ' || kind == '\\') ++codeLines;
				additions += kind == '+';
				deletions += kind == '-';
			}
		}
	}
	CGFloat height() const { return SummaryHeight + (chunks + (files > 1 ? files : 0))*ChunkHeight + codeLines*CodeHeight + BottomPadding; }
};

NSColor* LineFill(unichar kind) { return kind == '+' ? DiffAddition() : kind == '-' ? DiffDeletion() : nil; }

void PaintGutter(NSRect row, CGFloat x, CGFloat width)
{
	[DiffGutter() setFill];
	NSRectFill(NSMakeRect(x, NSMinY(row), width, NSHeight(row)));
	[DiffGutterRule() setFill];
	for(CGFloat boundary : {x+width/2-1, x+width-1})
		NSRectFill(NSMakeRect(boundary, NSMinY(row), 1, NSHeight(row)));
}
}

CGFloat GitDiffInlineHeight(NSDictionary* patch)
{
	NSString* text = patch[@"error"] ?: patch[@"text"];
	NSArray* lines = PatchLines(text);
	PatchShape shape(lines);
	return !patch[@"error"] && shape.chunks ? shape.height() : MAX(1, lines.count)*CodeHeight + BottomPadding;
}

@interface GitDiffTextView : NSTextView
@property CGFloat gutterWidth;
@property BOOL inlinePatch;
@end

@interface GitDiffLayoutManager : NSLayoutManager
@end

@implementation GitDiffLayoutManager
- (void)paintRange:(NSRange)glyphRange origin:(NSPoint)origin foreground:(BOOL)foreground
{
	NSTextStorage* storage = self.textStorage;
	if(!storage.length) return;
	[self enumerateLineFragmentsForGlyphRange:glyphRange usingBlock:^(NSRect line, NSRect used, NSTextContainer* container, NSRange glyphs, BOOL* stop){
		if(!glyphs.length) return;
		NSRange characters = [self characterRangeForGlyphRange:glyphs actualGlyphRange:NULL];
		NSUInteger character = characters.location;
		if(character >= storage.length) return;
		GitDiffTextView* view = (GitDiffTextView*)container.textView;
		NSDictionary* info = [storage attribute:DiffLine atIndex:character effectiveRange:NULL];
		NSNumber* band = [storage attribute:DiffBand atIndex:character effectiveRange:NULL];
		NSRect rect = NSOffsetRect(line, origin.x, origin.y);
		rect.origin.x = 0;
		rect.size.width = NSWidth(view.bounds);
		if(band && !foreground) {
			[(view.inlinePatch ? DiffBackground() : DiffHeader()) setFill];
			NSRectFill(rect);
			[DiffBandRule() setFill];
			NSRectFill(NSMakeRect(0, NSMaxY(rect)-1, rect.size.width, 1));
		}
		if(!info) return;
		BOOL firstFragment = character == 0 || [storage.string characterAtIndex:character-1] == '\n';
		NSUInteger end = NSMaxRange(characters);
		BOOL lastFragment = end >= storage.length || [storage.string characterAtIndex:end-1] == '\n';
		unichar kind = [info[@"kind"] unsignedShortValue];
		CGFloat column = view.gutterWidth / 2;
		CGFloat codeX = origin.x + view.gutterWidth;
		if(!foreground) {
			PaintGutter(rect, origin.x, view.gutterWidth);
			if(NSColor* color = LineFill(kind)) {
				[color setFill];
				NSRectFill(NSMakeRect(codeX, NSMinY(rect), MAX(0, NSMaxX(rect)-codeX), rect.size.height));
				[(kind == '+' ? DiffAddedEdge() : DiffRemovedEdge()) setFill];
				if(lastFragment && [info[@"edge"] boolValue])
					NSRectFill(NSMakeRect(codeX, NSMaxY(rect)-1, MAX(0, NSMaxX(rect)-codeX), 1));
				if(firstFragment && [info[@"startsAddition"] boolValue])
					NSRectFill(NSMakeRect(codeX, NSMinY(rect), MAX(0, NSMaxX(rect)-codeX), 1));
			}
			return;
		}
		if(firstFragment) {
			NSDictionary* attributes = @{ NSFontAttributeName: DiffFont(), NSForegroundColorAttributeName: DiffNumber() };
			for(NSUInteger index = 0; index < 2; ++index) {
				NSString* number = info[index == 0 ? @"old" : @"new"];
				NSSize size = [number sizeWithAttributes:attributes];
				[number drawAtPoint:NSMakePoint(origin.x+(index+1)*column-8-size.width, NSMidY(rect)-size.height/2) withAttributes:attributes];
			}
		}
		if(lastFragment && [info[@"endsInNewline"] boolValue]) {
			NSRect marker = NSOffsetRect(used, origin.x, origin.y);
			[@"¬" drawAtPoint:NSMakePoint(NSMaxX(marker)-1, NSMidY(rect)-[DiffFont() boundingRectForFont].size.height/2) withAttributes:@{
				NSFontAttributeName: DiffFont(), NSForegroundColorAttributeName: DiffAnnotation() }];
		}
		if(kind == '\\') {
			NSDictionary* style = @{ NSFontAttributeName: DiffFont(), NSForegroundColorAttributeName: DiffAnnotation() };
			CGFloat y = NSMidY(rect)-[@"·" sizeWithAttributes:style].height/2;
			for(NSUInteger glyph = glyphs.location; glyph < NSMaxRange(glyphs); ++glyph) {
				NSUInteger offset = [self characterIndexForGlyphAtIndex:glyph];
				if(offset >= storage.length || [storage.string characterAtIndex:offset] != ' ') continue;
				CGFloat x = origin.x+NSMinX(line)+[self locationForGlyphAtIndex:glyph].x;
				[@"·" drawAtPoint:NSMakePoint(x, y) withAttributes:style];
			}
		}
	}];
}
- (void)drawBackgroundForGlyphRange:(NSRange)glyphs atPoint:(NSPoint)origin
{
	[self paintRange:glyphs origin:origin foreground:NO];
	[super drawBackgroundForGlyphRange:glyphs atPoint:origin];
}
- (void)drawGlyphsForGlyphRange:(NSRange)glyphs atPoint:(NSPoint)origin
{
	[super drawGlyphsForGlyphRange:glyphs atPoint:origin];
	[self paintRange:glyphs origin:origin foreground:YES];
}
@end

@implementation GitDiffTextView
- (void)drawRect:(NSRect)rect
{
	if(self.gutterWidth) PaintGutter(rect, self.textContainerOrigin.x, self.gutterWidth);
	[super drawRect:rect];
}
@end

@interface GitDiffScrollView : NSScrollView
@property BOOL inlinePatch;
@end

@implementation GitDiffScrollView
- (void)scrollWheel:(NSEvent*)event
{
	if(self.inlinePatch && !(event.modifierFlags & NSEventModifierFlagShift) && fabs(event.scrollingDeltaY) >= fabs(event.scrollingDeltaX))
		[self.superview.enclosingScrollView scrollWheel:event];
	else [super scrollWheel:event];
}
@end

namespace {
struct DiffSyntax
{
	DiffSyntax(NSString* path, NSString* themeUUID, NSUInteger length)
	{
		if(!path.length || !themeUUID.length || length > 48*1024) return;
		std::string type = file::type_from_path(path.fileSystemRepresentation);
		if(type == NULL_STR || type == "text.plain") return;
		for(auto const& item : bundles::query(bundles::kFieldGrammarScope, type, scope::wildcard, bundles::kItemTypeGrammar))
			if((grammar = parse::parse_grammar(item))) break;
		if(auto item = bundles::lookup(themeUUID.UTF8String)) theme = [[OakTheme alloc] initWithBundleItem:item];
	}

	void reset()
	{
		if(grammar && theme) { oldState = grammar->seed(); newState = grammar->seed(); }
	}

	void style(NSString* text, unichar operation, NSMutableAttributedString* line)
	{
		if(!oldState || !newState || text.length > 2000 || operation == '\\') return;
		std::string bytes = text.UTF8String ?: "";
		if(bytes.empty()) return;
		std::map<size_t, scope::scope_t> current, removed;
		if(operation != '+') oldState = parse::parse(bytes.data(), bytes.data()+bytes.size(), oldState, removed, false);
		if(operation != '-') newState = parse::parse(bytes.data(), bytes.data()+bytes.size(), newState, current, false);
		auto const& scopes = operation == '-' ? removed : current;
		NSUInteger offset = 0;
		for(auto point = scopes.begin(); point != scopes.end(); ++point) {
			auto next = std::next(point);
			size_t end = next == scopes.end() ? bytes.size() : next->first;
			NSUInteger size = utf16::distance(bytes.data()+point->first, bytes.data()+end);
			if(offset+size > line.length) break;
			NSColor* color = [theme stylesForScope:point->second].foregroundColor;
			if(color && size) [line addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(offset, size)];
			offset += size;
		}
	}

	parse::grammar_ptr grammar;
	parse::stack_ptr oldState, newState;
	OakTheme* theme = nil;
};
}

NSTextField* GitLabel(NSString* text, CGFloat size, NSFontWeight weight)
{
	NSTextField* label = [NSTextField labelWithString:text];
	label.font = [NSFont systemFontOfSize:size weight:weight];
	label.lineBreakMode = NSLineBreakByTruncatingMiddle;
	return label;
}

NSView* GitBadge(NSString* text, NSColor* fill)
{
	NSBox* badge = [[NSBox alloc] init];
	badge.boxType = NSBoxCustom;
	badge.titlePosition = NSNoTitle;
	badge.borderWidth = 0;
	badge.cornerRadius = 4;
	badge.fillColor = fill;
	badge.contentViewMargins = NSZeroSize;
	NSTextField* label = GitLabel(text, 11, NSFontWeightMedium);
	label.textColor = NSColor.whiteColor;
	label.translatesAutoresizingMaskIntoConstraints = NO;
	[badge.contentView addSubview:label];
	[NSLayoutConstraint activateConstraints:@[
		[badge.heightAnchor constraintEqualToConstant:16],
		[label.leadingAnchor constraintEqualToAnchor:badge.contentView.leadingAnchor constant:4],
		[label.trailingAnchor constraintEqualToAnchor:badge.contentView.trailingAnchor constant:-4],
		[label.centerYAnchor constraintEqualToAnchor:badge.contentView.centerYAnchor],
	]];
	return badge;
}

NSButton* GitIconButton(NSString* symbol, NSString* label, id target, SEL action)
{
	NSImage* image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
	image = image ?: [NSImage imageWithSystemSymbolName:@"ellipsis" accessibilityDescription:label];
	NSButton* button = image ? [NSButton buttonWithImage:image target:target action:action] : [NSButton buttonWithTitle:label target:target action:action];
	button.bezelStyle = NSBezelStyleAccessoryBarAction;
	button.bordered = NO;
	button.toolTip = label;
	button.accessibilityLabel = label;
	return button;
}

NSScrollView* GitScrollView(NSView* document)
{
	NSScrollView* scroll = [[NSScrollView alloc] init];
	scroll.drawsBackground = NO;
	scroll.hasVerticalScroller = YES;
	scroll.autohidesScrollers = YES;
	scroll.documentView = document;
	return scroll;
}

NSView* GitPaneHeader(NSView* heading, CGFloat height, CGFloat inset)
{
	NSView* header = [[NSView alloc] init];
	if([heading isKindOfClass:NSStackView.class]) ((NSStackView*)heading).distribution = NSStackViewDistributionFill;
	NSBox* separator = [[NSBox alloc] init];
	separator.boxType = NSBoxSeparator;
	for(NSView* view in @[heading, separator]) {
		view.translatesAutoresizingMaskIntoConstraints = NO;
		[header addSubview:view];
	}
	[NSLayoutConstraint activateConstraints:@[
		[header.heightAnchor constraintEqualToConstant:height],
		[heading.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:inset],
		[heading.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-inset],
		[heading.centerYAnchor constraintEqualToAnchor:header.centerYAnchor constant:0.5],
		[separator.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
		[separator.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
		[separator.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
		[separator.heightAnchor constraintEqualToConstant:1],
	]];
	return header;
}

NSView* GitPaneFooter(NSTextField* status, NSButton* action)
{
	NSView* footer = [[NSView alloc] init];
	status.textColor = NSColor.secondaryLabelColor;
	status.maximumNumberOfLines = 1;
	status.lineBreakMode = NSLineBreakByTruncatingTail;
	[status setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSStackView* row = [NSStackView stackViewWithViews:action ? @[status, action] : @[status]];
	row.distribution = NSStackViewDistributionFill;
	row.spacing = 8;
	row.translatesAutoresizingMaskIntoConstraints = NO;
	[footer addSubview:row];
	// Use the History button's height plus its original vertical padding in every pane.
	NSButton* smallButton = action ?: [NSButton buttonWithTitle:@"Ag" target:nil action:NULL];
	smallButton.controlSize = NSControlSizeSmall;
	[NSLayoutConstraint activateConstraints:@[
		[footer.heightAnchor constraintEqualToConstant:smallButton.intrinsicContentSize.height+16],
		[row.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:10],
		[row.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-10],
		[row.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
	]];
	return footer;
}

@interface GitWorkspaceListRow : NSTableRowView
@property (nonatomic) BOOL fullWidthSeparator;
@end

@implementation GitWorkspaceListRow
- (void)drawSelectionInRect:(NSRect)dirtyRect
{
	if(self.selectionHighlightStyle == NSTableViewSelectionHighlightStyleNone) return;
	[[NSColor.labelColor colorWithAlphaComponent:self.emphasized ? 0.26 : 0.16] setFill];
	[[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 7, 1) xRadius:4 yRadius:4] fill];
}
- (void)drawSeparatorInRect:(NSRect)dirtyRect
{
	if(self.selected || self.fullWidthSeparator) return;
	[NSColor.separatorColor setFill];
	CGFloat y = self.isFlipped ? NSHeight(self.bounds)-1 : 0;
	NSRectFillUsingOperation(NSMakeRect(10, y, MAX(0, NSWidth(self.bounds)-20), 1), NSCompositingOperationSourceOver);
}
- (void)drawBackgroundInRect:(NSRect)dirtyRect
{
	[super drawBackgroundInRect:dirtyRect];
	// Changeset outlines hide the table grid, so draw their separators with the row.
	if(!self.fullWidthSeparator) return;
	[NSColor.separatorColor setFill];
	CGFloat y = self.isFlipped ? NSMaxY(self.bounds)-1 : NSMinY(self.bounds);
	NSRectFillUsingOperation(NSMakeRect(NSMinX(self.bounds), y, NSWidth(self.bounds), 1), NSCompositingOperationSourceOver);
}
@end

NSTableRowView* GitListRow(BOOL fullWidthSeparator)
{
	GitWorkspaceListRow* row = [[GitWorkspaceListRow alloc] init];
	row.fullWidthSeparator = fullWidthSeparator;
	return row;
}

@interface GitDisclosureCell : NSButtonCell
@end

@implementation GitDisclosureCell
- (NSRect)imageRectForBounds:(NSRect)bounds
{
	NSSize size = self.image.size;
	return NSMakeRect(NSMidX(bounds)-size.width/2, NSMidY(bounds)-size.height/2, size.width, size.height);
}
@end

@implementation GitOutlineView
- (NSView*)makeViewWithIdentifier:(NSUserInterfaceItemIdentifier)identifier owner:(id)owner
{
	NSView* view = [super makeViewWithIdentifier:identifier owner:owner];
	if(![identifier isEqual:NSOutlineViewDisclosureButtonKey] || ![view isKindOfClass:NSButton.class]) return view;

	// The native disclosure bezel places its glyph above center in these taller
	// rows. Keep AppKit's expansion button and use a centered template image.
	static NSImage* const collapsed = OakSidebarDisclosureImage(NO, 12);
	static NSImage* const expanded = OakSidebarDisclosureImage(YES, 12);
	NSButton* button = (NSButton*)view;
	if([button.cell isKindOfClass:GitDisclosureCell.class]) return button;
	NSButtonCell* cell = [[GitDisclosureCell alloc] initImageCell:collapsed];
	cell.bordered = NO;
	cell.imagePosition = NSImageOnly;
	cell.imageScaling = NSImageScaleNone;
	[cell setButtonType:NSButtonTypeToggle];
	cell.alternateImage = expanded;
	cell.target = button.target;
	cell.action = button.action;
	cell.state = button.state;
	cell.enabled = button.enabled;
	button.cell = cell;
	button.accessibilityRole = NSAccessibilityDisclosureTriangleRole;
	return button;
}
@end

NSArray<NSString*>* GitDiffHunks(NSString* patch)
{
	if(![patch hasPrefix:@"diff --git "] || ![patch containsString:@"\n@@ "] || [[patch substringFromIndex:1] containsString:@"\ndiff --git "]) return @[];
	NSArray* parts = [patch componentsSeparatedByString:@"\n@@ "];
	NSMutableArray* hunks = [NSMutableArray array];
	for(NSUInteger i = 1; i < parts.count; ++i) {
		NSString* hunk = [@"@@ " stringByAppendingString:parts[i]];
		if(![hunk hasSuffix:@"\n"]) hunk = [hunk stringByAppendingString:@"\n"];
		[hunks addObject:hunk];
	}
	return hunks;
}

static NSView* GitDiffHeaderRow(NSArray<NSView*>* labels, NSStackView* controls, CGFloat inset, CGFloat padding)
{
	NSView* row = [[NSView alloc] init];
	NSStackView* leading = [NSStackView stackViewWithViews:labels];
	leading.spacing = 10;
	controls.spacing = 6;
	[controls setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
	for(NSView* subview in @[leading, controls]) {
		subview.translatesAutoresizingMaskIntoConstraints = NO;
		[row addSubview:subview];
		NSLayoutConstraint* fit = [row.heightAnchor constraintEqualToAnchor:subview.heightAnchor constant:2*padding];
		fit.priority = NSLayoutPriorityDefaultLow-1;
		[NSLayoutConstraint activateConstraints:@[
			[subview.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
			[subview.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:padding],
			[subview.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-padding],
			fit,
		]];
	}
	[NSLayoutConstraint activateConstraints:@[
		[leading.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:inset],
		[controls.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-inset],
		[leading.trailingAnchor constraintLessThanOrEqualToAnchor:controls.leadingAnchor constant:-6],
	]];
	return row;
}

namespace {
NSMutableParagraphStyle* DiffParagraph(CGFloat height, CGFloat inset, BOOL wraps = NO)
{
	NSMutableParagraphStyle* style = [[NSMutableParagraphStyle alloc] init];
	style.minimumLineHeight = style.maximumLineHeight = height;
	style.firstLineHeadIndent = style.headIndent = inset;
	style.lineBreakMode = wraps ? NSLineBreakByWordWrapping : NSLineBreakByClipping;
	style.defaultTabInterval = [@"    " sizeWithAttributes:@{NSFontAttributeName: DiffFont()}].width;
	style.tabStops = @[];
	return style;
}

void AppendBand(NSMutableAttributedString* out, NSString* label, NSParagraphStyle* style)
{
	[out appendAttributedString:[[NSAttributedString alloc] initWithString:[label stringByAppendingString:@"\n"] attributes:@{
		NSFontAttributeName: DiffFont(), NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
		NSParagraphStyleAttributeName: style, NSBaselineOffsetAttributeName: @((style.minimumLineHeight-CodeHeight)/2+3), DiffBand: @YES
	}]];
}

// Compare paired replacement lines and emphasize the changed part only.
// Widen to whole graphemes if the boundary falls within a composed character.
NSRange EditedSpan(NSString* text, NSString* other)
{
	NSUInteger left = 0, right = 0;
	while(left < MIN(text.length, other.length) && [text characterAtIndex:left] == [other characterAtIndex:left]) ++left;
	while(right < MIN(text.length, other.length)-left && [text characterAtIndex:text.length-1-right] == [other characterAtIndex:other.length-1-right]) ++right;
	NSRange changed = NSMakeRange(left, text.length-left-right);
	return (left || right) && changed.length ? [text rangeOfComposedCharacterSequencesForRange:changed] : NSMakeRange(0, 0);
}

NSUInteger CollectEdits(NSArray<NSString*>* lines, NSUInteger start, unichar operation, NSMutableArray<NSNumber*>* edits)
{
	NSUInteger index = start;
	while(index < lines.count && [lines[index] length] && [lines[index] characterAtIndex:0] == operation) {
		[edits addObject:@(index++)];
		if(index < lines.count && [lines[index] hasPrefix:@"\\ "]) ++index;
	}
	return index;
}

NSUInteger ChecksumLength(NSString* path)
{
	static NSDictionary* const lengths = @{@"md5": @32, @"sha1": @40, @"sha256": @64, @"sha512": @128};
	return [lengths[path.pathExtension.lowercaseString ?: @""] unsignedIntegerValue];
}

BOOL HighlightChecksum(NSMutableAttributedString* value, NSString* code, NSUInteger length)
{
	if(!length || code.length != length) return NO;
	static NSCharacterSet* const notHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
	if([code rangeOfCharacterFromSet:notHex].location != NSNotFound) return NO;
	NSUInteger number = 0;
	while(number < length && [code characterAtIndex:number] >= '0' && [code characterAtIndex:number] <= '9') ++number;
	if(number) [value addAttribute:NSForegroundColorAttributeName value:DiffNumeral() range:NSMakeRange(0, number)];
	return YES;
}
}

@implementation GitDiffView
{
	NSTextField* _title;
	NSTextField* _footerSummary;
	GitDiffTextView* _textView;
	NSView* _titleBar;
	GitDiffScrollView* _scroll;
	NSImageView* _icon;
	NSDictionary* _lastPatch;
	NSString* _lastSubtitle;
	BOOL _inlinePatch;
	NSArray<NSValue*>* _chunkRanges;
	NSArray<NSNumber*>* _chunkActions;
	BOOL _chunkActionsDisabled;
	void (^_chunkHandler)(NSUInteger, GitRepositoryAction);
	NSMutableDictionary<NSNumber*, NSStackView*>* _chunkControls;
	CGFloat _currentTextWidth;
	CGFloat _measuredInlineHeight;
}

- (instancetype)initWithFrame:(NSRect)frame { return [self initWithFrame:frame inlinePatch:NO]; }

- (instancetype)initWithFrame:(NSRect)frame inlinePatch:(BOOL)inlinePatch
{
	if(!(self = [super initWithFrame:frame])) return nil;
	_inlinePatch = inlinePatch;
	_showsPatch = YES;
	_chunkControls = [NSMutableDictionary dictionary];
	NSView* header = nil;
	NSView* footer = nil;
	if(!inlinePatch) {
		_title = GitLabel(@"Diff", 13, NSFontWeightBold);
		_title.alignment = NSTextAlignmentLeft;
		[_title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
		_icon = [[NSImageView alloc] init];
		_icon.hidden = YES;
		[_icon.widthAnchor constraintEqualToConstant:22].active = YES;
		[_icon.heightAnchor constraintEqualToConstant:22].active = YES;
		_headerControls = [NSStackView stackViewWithViews:@[]];
		header = _titleBar = GitPaneHeader(GitDiffHeaderRow(@[_icon, _title], _headerControls, 10, 0));
		_footerSummary = GitLabel(@"", 11, NSFontWeightRegular);
		_footerSummary.textColor = NSColor.secondaryLabelColor;
		_footerSummary.alignment = NSTextAlignmentCenter;
		[_footerSummary setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
		[_footerSummary setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
		_footerOptions = [NSStackView stackViewWithViews:@[]];
		_footerOptions.spacing = 16;
		[_footerOptions setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
		_footerControls = [NSStackView stackViewWithViews:@[]];
		footer = [[NSView alloc] init];
		for(NSView* view in @[_footerOptions, _footerSummary, _footerControls]) {
			view.translatesAutoresizingMaskIntoConstraints = NO;
			[footer addSubview:view];
			[view.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor].active = YES;
		}
		NSLayoutConstraint* centered = [_footerSummary.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor];
		centered.priority = NSLayoutPriorityDefaultLow-1;
		[NSLayoutConstraint activateConstraints:@[
			[_footerOptions.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:16],
			[_footerControls.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-15],
			[_footerSummary.leadingAnchor constraintGreaterThanOrEqualToAnchor:_footerOptions.trailingAnchor constant:6],
			[_footerSummary.trailingAnchor constraintLessThanOrEqualToAnchor:_footerControls.leadingAnchor constant:-6], centered,
		]];
	}
	_textView = [[GitDiffTextView alloc] initWithFrame:NSMakeRect(0, 0, 500, 32)];
	_textView.inlinePatch = inlinePatch;
	_textView.editable = NO;
	_textView.richText = NO;
	_textView.font = DiffFont();
	_textView.textContainerInset = NSMakeSize(0, 0);
	_textView.horizontallyResizable = YES;
	_textView.verticallyResizable = YES;
	_textView.autoresizingMask = NSViewWidthSizable;
	_textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
	_textView.textContainer.containerSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
	_textView.textContainer.widthTracksTextView = NO;
	_textView.textContainer.lineFragmentPadding = 0;
	_textView.drawsBackground = NO;
	[_textView.textContainer replaceLayoutManager:[GitDiffLayoutManager new]];
	_textView.accessibilityLabel = @"File diff. Old and new line numbers precede each change.";
	_scroll = [[GitDiffScrollView alloc] init];
	_scroll.drawsBackground = NO;
	_scroll.inlinePatch = inlinePatch;
	_scroll.autohidesScrollers = YES;
	_scroll.hasVerticalScroller = !inlinePatch;
	_scroll.hasHorizontalScroller = YES;
	_scroll.documentView = _textView;
	for(NSView* view in (inlinePatch ? @[_scroll] : @[header, _scroll, footer])) {
		view.translatesAutoresizingMaskIntoConstraints = NO;
		[self addSubview:view];
		[NSLayoutConstraint activateConstraints:@[[view.leadingAnchor constraintEqualToAnchor:self.leadingAnchor], [view.trailingAnchor constraintEqualToAnchor:self.trailingAnchor]]];
	}
	if(inlinePatch) {
		[NSLayoutConstraint activateConstraints:@[[_scroll.topAnchor constraintEqualToAnchor:self.topAnchor], [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]]];
	} else {
		[NSLayoutConstraint activateConstraints:@[
			[header.topAnchor constraintEqualToAnchor:self.topAnchor], [_scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor],
			[_scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor], [footer.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
			[footer.heightAnchor constraintEqualToConstant:30],
		]];
		_scroll.contentView.postsBoundsChangedNotifications = YES;
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clipBoundsChanged:) name:NSViewBoundsDidChangeNotification object:_scroll.contentView];
		_scroll.contentView.postsFrameChangedNotifications = YES;
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clipFrameChanged:) name:NSViewFrameDidChangeNotification object:_scroll.contentView];
	}
	return self;
}

- (void)drawRect:(NSRect)rect
{
	if(_inlinePatch) return;
	[DiffBackground() setFill];
	NSRectFill(rect);
	[DiffTitleFill() setFill];
	NSRectFill(NSIntersectionRect(rect, _titleBar.frame));
}

- (NSImage*)fileIcon { return _icon.image; }
- (void)setFileIcon:(NSImage*)icon { _icon.image = icon; _icon.hidden = !icon; }
- (void)setShowsPatch:(BOOL)value { if(_showsPatch != value) { _showsPatch = value; _lastPatch = nil; } }
- (void)setSyntaxPath:(NSString*)value { if(![_syntaxPath isEqual:value]) { _syntaxPath = [value copy]; _lastPatch = nil; } }
- (void)setSyntaxThemeUUID:(NSString*)value { if(![_syntaxThemeUUID isEqual:value]) { _syntaxThemeUUID = [value copy]; _lastPatch = nil; } }
- (void)setChunkActions:(NSArray<NSNumber*>*)actions handler:(void(^)(NSUInteger, GitRepositoryAction))handler
{
	if(![_chunkActions isEqual:actions]) {
		for(NSView* control in _chunkControls.allValues) [control removeFromSuperview];
		[_chunkControls removeAllObjects];
		_chunkActions = [actions copy];
		_lastPatch = nil;
	}
	_chunkHandler = [handler copy];
	self.needsLayout = YES;
}

- (void)setChunkActionsEnabled:(BOOL)enabled
{
	_chunkActionsDisabled = !enabled;
	for(NSStackView* controls in _chunkControls.allValues)
		for(NSButton* button in controls.arrangedSubviews) button.enabled = enabled;
}

- (void)clipBoundsChanged:(NSNotification*)notification { if(_chunkActions.count) self.needsLayout = YES; }
- (void)clipFrameChanged:(NSNotification*)notification { self.needsLayout = YES; }

- (void)setSoftWrap:(BOOL)enabled
{
	if(_softWrap == enabled) return;
	_softWrap = enabled;
	_textView.horizontallyResizable = !enabled;
	_scroll.hasHorizontalScroller = !enabled;
	_currentTextWidth = 0;
	[self updateTextWidth:_scroll.contentSize.width];
	self.needsLayout = YES;
}

- (void)updateTextWidth:(CGFloat)width
{
	if(width <= 0 || _currentTextWidth == width) return;
	_currentTextWidth = width;
	_measuredInlineHeight = 0;
	_textView.minSize = NSMakeSize(width, _textView.minSize.height);
	if(_softWrap || NSWidth(_textView.frame) < width)
		[_textView setFrameSize:NSMakeSize(width, NSHeight(_textView.frame))];
	// Leave room for the end of line marker at the right edge.
	_textView.textContainer.containerSize = NSMakeSize(_softWrap ? MAX(1, width-8) : CGFLOAT_MAX, CGFLOAT_MAX);
}

- (CGFloat)wrappedInlineHeightForWidth:(CGFloat)width
{
	[self updateTextWidth:width];
	if(!_measuredInlineHeight) {
		NSLayoutManager* layout = _textView.layoutManager;
		[layout ensureLayoutForTextContainer:_textView.textContainer];
		_measuredInlineHeight = ceil(NSMaxY([layout usedRectForTextContainer:_textView.textContainer])) + BottomPadding;
	}
	return _measuredInlineHeight;
}

- (void)layout
{
	[super layout];
	[self updateTextWidth:_scroll.contentSize.width];
	[self layoutChunkActions];
}

- (void)layoutChunkActions
{
	if(!_chunkActions.count || !_chunkRanges.count || !_textView.window) return;
	NSLayoutManager* layout = _textView.layoutManager;
	NSRect visible = _scroll.documentVisibleRect;
	NSRange glyphs = [layout glyphRangeForBoundingRect:NSMakeRect(0, NSMinY(visible), NSWidth(_textView.bounds), NSHeight(visible)) inTextContainer:_textView.textContainer];
	NSRange characters = [layout characterRangeForGlyphRange:glyphs actualGlyphRange:NULL];
	NSMutableSet<NSNumber*>* active = [NSMutableSet set];
	[_chunkRanges enumerateObjectsUsingBlock:^(NSValue* range, NSUInteger index, BOOL* stop){
		if(range.rangeValue.location >= NSMaxRange(characters)) { *stop = YES; return; }
		if(!NSIntersectionRange(range.rangeValue, characters).length) return;
		NSNumber* key = @(index);
		[active addObject:key];
		NSStackView* controls = self->_chunkControls[key];
		if(!controls) {
			NSMutableArray* buttons = [NSMutableArray array];
			for(NSNumber* action in self->_chunkActions) {
				NSString* title = action.unsignedIntegerValue == GitRepositoryStage ? @"Stage Chunk" : action.unsignedIntegerValue == GitRepositoryUnstage ? @"Unstage Chunk" : @"Discard Chunk";
				NSButton* button = [NSButton buttonWithTitle:title target:self action:@selector(performChunkAction:)];
				button.controlSize = NSControlSizeSmall;
				button.tag = action.integerValue;
				button.enabled = !self->_chunkActionsDisabled;
				button.identifier = key.stringValue;
				button.accessibilityHelp = [NSString stringWithFormat:@"Chunk %lu", (unsigned long)index+1];
				[buttons addObject:button];
			}
			controls = [NSStackView stackViewWithViews:buttons];
			controls.spacing = 6;
			controls.wantsLayer = YES;
			controls.layer.backgroundColor = DiffHeader().CGColor;
			[self->_textView addSubview:controls];
			self->_chunkControls[key] = controls;
		}
		NSUInteger glyph = [layout glyphIndexForCharacterAtIndex:range.rangeValue.location];
		NSRect line = [layout lineFragmentRectForGlyphAtIndex:glyph effectiveRange:NULL];
		NSSize size = controls.fittingSize;
		controls.frame = NSMakeRect(MAX(0, NSMaxX(visible)-HeaderInset-size.width), NSMidY(line)-size.height/2, size.width, size.height);
	}];
	for(NSNumber* key in _chunkControls.allKeys) if(![active containsObject:key]) {
		[_chunkControls[key] removeFromSuperview];
		[_chunkControls removeObjectForKey:key];
	}
}

- (void)viewDidChangeEffectiveAppearance
{
	[super viewDidChangeEffectiveAppearance];
	[self.effectiveAppearance performAsCurrentDrawingAppearance:^{
		for(NSStackView* controls in self->_chunkControls.allValues) controls.layer.backgroundColor = DiffHeader().CGColor;
	}];
}

- (IBAction)performChunkAction:(NSButton*)sender
{
	NSUInteger index = sender.identifier.integerValue;
	if(!_chunkActionsDisabled && index < _chunkRanges.count && [_chunkActions containsObject:@(sender.tag)] && _chunkHandler)
		_chunkHandler(index, (GitRepositoryAction)sender.tag);
}

- (void)showTitle:(NSString*)title subtitle:(NSString*)subtitle patch:(NSDictionary*)patch
{
	[self showTitle:title subtitle:subtitle patch:patch preserveScroll:NO];
}

- (void)showTitle:(NSString*)title subtitle:(NSString*)subtitle patch:(NSDictionary*)patch preserveScroll:(BOOL)preserve
{
	_title.stringValue = title ?: @"";
	_title.toolTip = title;
	if([_lastPatch isEqual:patch] && [_lastSubtitle isEqual:subtitle]) return;
	NSClipView* clip = _scroll.contentView;
	NSPoint position = preserve ? clip.bounds.origin : NSZeroPoint;
	_lastPatch = [patch copy];
	_lastSubtitle = [subtitle copy];
	NSString* text = patch[@"error"] ?: patch[@"text"] ?: @"";
	NSArray<NSString*>* lines = PatchLines(text);
	PatchShape shape(lines);
	NSMutableAttributedString* display = [[NSMutableAttributedString alloc] init];
	NSMutableArray* chunks = [NSMutableArray array];
	if(_showsPatch && shape.chunks && !patch[@"error"]) {
		NSString* summary = DiffSummary(shape.chunks, shape.additions, shape.deletions);
		_footerSummary.stringValue = summary;
		AppendBand(display, summary, DiffParagraph(SummaryHeight, HeaderInset + (_inlinePatch ? 8 : 0)));
		CGFloat gutterWidth = 2 * GutterColumn;
		for(NSString* line in lines) {
			HunkRange oldRange, newRange;
			if(ReadHunkHeader(line, oldRange, newRange)) {
				NSUInteger largest = MAX((NSUInteger)oldRange.line+oldRange.count, (NSUInteger)newRange.line+newRange.count);
				NSUInteger digits = [@(largest) stringValue].length;
				gutterWidth = MAX(gutterWidth, 2*(16 + (digits+1)*[@"0" sizeWithAttributes:@{NSFontAttributeName: DiffFont()}].width));
			}
		}
		_textView.gutterWidth = gutterWidth;
		_textView.minSize = NSMakeSize(_textView.minSize.width, shape.height());
		NSParagraphStyle* body = DiffParagraph(CodeHeight, gutterWidth+5, YES);
		NSParagraphStyle* heading = DiffParagraph(ChunkHeight, HeaderInset + (_inlinePatch ? 8 : 0));
		DiffSyntax syntax(self.syntaxPath, self.syntaxThemeUUID, text.length);
		NSUInteger checksumLength = ChecksumLength(self.syntaxPath);
		HunkRange oldRange, newRange;
		BOOL inHunk = NO, firstLineOfHunk = NO;
		NSMutableArray<NSNumber*>* deletions = [NSMutableArray array];
		NSMutableArray<NSNumber*>* additions = [NSMutableArray array];
		for(NSUInteger index = 0; index < lines.count;) {
			NSString* line = lines[index];
			if([line hasPrefix:@"diff --git "]) {
				inHunk = NO;
				if(shape.files > 1) AppendBand(display, [line substringFromIndex:11], heading);
				++index;
				continue;
			}
			if(ReadHunkHeader(line, oldRange, newRange)) {
				inHunk = firstLineOfHunk = YES;
				syntax.reset();
				NSUInteger start = display.length;
				NSRange end = [line rangeOfString:@" @@" options:0 range:NSMakeRange(3, line.length-3)];
				AppendBand(display, _chunkActions.count && end.location != NSNotFound ? [line substringToIndex:NSMaxRange(end)] : line, heading);
				[chunks addObject:[NSValue valueWithRange:NSMakeRange(start, display.length-start)]];
				++index;
				continue;
			}
			if(!inHunk || !line.length) { ++index; continue; }
			unichar operation = [line characterAtIndex:0];
			if(operation != '+' && operation != '-' && operation != ' ' && operation != '\\') { ++index; continue; }
			NSUInteger end = index+1, deleteIndex = 0, addIndex = 0;
			[deletions removeAllObjects];
			[additions removeAllObjects];
			if(operation == '-' || operation == '+') {
				NSUInteger boundary = CollectEdits(lines, index, '-', deletions);
				end = CollectEdits(lines, boundary, '+', additions);
			}
			for(NSUInteger row = index; row < end; ++row) {
				NSString* raw = lines[row];
				unichar kind = [raw characterAtIndex:0];
				NSString* code = [raw substringFromIndex:1];
				if([code hasSuffix:@"\r"]) code = [code substringToIndex:code.length-1];
				NSString* old = @"", *newNumber = @"";
				if(kind == '-' || kind == ' ') old = [NSString stringWithFormat:kind == '-' ? @"−%ld" : @"%ld", (long)oldRange.line++];
				if(kind == '+' || kind == ' ') newNumber = [NSString stringWithFormat:kind == '+' ? @"+%ld" : @"%ld", (long)newRange.line++];
				if(firstLineOfHunk && kind == '-') newNumber = [NSString stringWithFormat:@"%ld", (long)MAX(0, newRange.line-(newRange.count > 0))];
				if(firstLineOfHunk && kind == '+') old = [NSString stringWithFormat:@"%ld", (long)MAX(0, oldRange.line-(oldRange.count > 0))];
				if(kind != '\\') firstLineOfHunk = NO;
				BOOL startsAddition = kind == '+' && (row == 0 || ![lines[row-1] hasPrefix:@"+"]);
				BOOL edge = (kind == '+' || kind == '-') && (row+1 == lines.count || ![lines[row+1] hasPrefix:kind == '+' ? @"+" : @"-"]);
				NSDictionary* info = @{ @"old": old, @"new": newNumber, @"kind": @(kind), @"edge": @(edge), @"startsAddition": @(startsAddition),
					@"endsInNewline": @(kind != '\\' || row+1 < lines.count) };
				NSMutableAttributedString* value = [[NSMutableAttributedString alloc] initWithString:[code stringByAppendingString:@"\n"] attributes:@{
					NSFontAttributeName: DiffFont(), NSForegroundColorAttributeName: kind == '\\' ? DiffAnnotation() : DiffCodeText(),
					NSParagraphStyleAttributeName: body, DiffLine: info,
				}];
				BOOL checksum = kind != '\\' && HighlightChecksum(value, code, checksumLength);
				if(kind != '\\' && !checksum) syntax.style(value.string, kind, value);
				NSNumber* pair = nil;
				if(kind == '-') { if(deleteIndex < additions.count) pair = additions[deleteIndex]; ++deleteIndex; }
				if(kind == '+') { if(addIndex < deletions.count) pair = deletions[addIndex]; ++addIndex; }
				if(pair && !checksum) {
					NSString* other = [lines[pair.unsignedIntegerValue] substringFromIndex:1];
					if([other hasSuffix:@"\r"]) other = [other substringToIndex:other.length-1];
					NSRange changed = EditedSpan(code, other);
					if(changed.length) [value addAttribute:NSBackgroundColorAttributeName value:kind == '+' ? DiffAddedText() : DiffRemovedText() range:changed];
				}
				[display appendAttributedString:value];
			}
			index = end;
		}
	} else {
		_footerSummary.stringValue = subtitle ?: @"";
		_textView.gutterWidth = 0;
		_textView.minSize = NSMakeSize(_textView.minSize.width, 0);
		[display appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{
			NSFontAttributeName: DiffFont(), NSForegroundColorAttributeName: NSColor.textColor, NSParagraphStyleAttributeName: DiffParagraph(CodeHeight, HeaderInset, YES)
		}]];
	}
	if(display.length && [display.string hasSuffix:@"\n"]) [display deleteCharactersInRange:NSMakeRange(display.length-1, 1)];
	_chunkRanges = chunks;
	for(NSView* control in _chunkControls.allValues) [control removeFromSuperview];
	[_chunkControls removeAllObjects];
	[_textView.textStorage setAttributedString:display];
	_measuredInlineHeight = 0;
	[_textView setSelectedRange:NSMakeRange(0, 0)];
	if(preserve && _scroll) [_textView.layoutManager ensureLayoutForTextContainer:_textView.textContainer];
	NSRect bounds = clip.bounds;
	bounds.origin = position;
	[clip scrollToPoint:[clip constrainBoundsRect:bounds].origin];
	[_scroll reflectScrolledClipView:clip];
	self.needsLayout = YES;
}
@end

@implementation GitChangeWindowController
{
	GitDiffView* _diff;
	NSUInteger _generation;
}

- (instancetype)init
{
	NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 860, 550)
		styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered defer:NO];
	if((self = [super initWithWindow:window])) {
		window.title = @"Source Control Diff";
		window.minSize = NSMakeSize(420, 230);
		window.releasedWhenClosed = NO;
		_diff = [[GitDiffView alloc] initWithFrame:window.contentView.bounds];
		window.contentView = _diff;
		[window center];
	}
	return self;
}

- (BOOL)softWrap { return _diff.softWrap; }
- (void)setSoftWrap:(BOOL)enabled { _diff.softWrap = enabled; }

- (IBAction)toggleSoftWrap:(id)sender
{
	self.softWrap = !self.softWrap;
	if(self.softWrapChanged) self.softWrapChanged(self.softWrap);
}

- (BOOL)validateMenuItem:(NSMenuItem*)item
{
	if(item.action == @selector(toggleSoftWrap:)) {
		item.title = self.softWrap ? @"Disable Soft Wrap" : @"Enable Soft Wrap";
		return YES;
	}
	return [super validateMenuItem:item];
}

- (void)showChange:(NSDictionary*)change snapshot:(NSDictionary*)snapshot buffers:(NSDictionary*)buffers
{
	NSString* path = change[@"path"];
	GitChangeGroup group = (GitChangeGroup)[change[@"group"] unsignedIntegerValue];
	BOOL unsaved = [change[@"unsaved"] boolValue];
	BOOL isDirectory = [change[@"directory"] boolValue];
	self.window.title = isDirectory ? @"Source Control Details" : @"Source Control Diff";
	NSString* comparison = isDirectory ? @"Untracked folder" : group == GitChangeStaged ? @"Last commit → Staged changes" : group == GitChangeConflict
		? (unsaved ? @"Last commit → Unsaved editor buffer" : @"Merge conflict")
		: (unsaved ? @"Staged version → Unsaved editor buffer" : @"Staged version → Working tree");
	[_diff showTitle:path subtitle:comparison patch:@{ @"text": @"Loading diff…" }];
	[self showWindow:nil];
	NSUInteger generation = ++_generation;
	__weak GitChangeWindowController* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDictionary* patch = GitRepositoryChangeDiff(snapshot, change, buffers);
		dispatch_async(dispatch_get_main_queue(), ^{
			GitChangeWindowController* controller = weakSelf;
			if(controller && controller->_generation == generation)
				[controller->_diff showTitle:path subtitle:comparison patch:patch];
		});
	});
}
@end
