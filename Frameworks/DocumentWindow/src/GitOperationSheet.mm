#import "GitOperationSheet.h"
#import "GitDiffView.h"

namespace {
constexpr CGFloat sheetWidth = 480, margin = 20, fieldX = 116, fieldWidth = sheetWidth-fieldX-margin;

CGFloat AddDescription(NSView* parent, NSString* text, CGFloat x, CGFloat y, CGFloat width, NSFont* font, NSColor* color)
{
	NSTextField* field = [NSTextField wrappingLabelWithString:text];
	field.font = font;
	field.textColor = color;
	CGFloat height = ceil([field.cell cellSizeForBounds:NSMakeRect(0, 0, width, CGFLOAT_MAX)].height);
	field.frame = NSMakeRect(x, y, width, height);
	[parent addSubview:field];
	return NSMaxY(field.frame);
}

NSBox* Rule()
{
	NSBox* rule = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, sheetWidth, 1)];
	rule.boxType = NSBoxSeparator;
	return rule;
}

NSImage* OptionsImage(BOOL expanded)
{
	NSImage* image = [NSImage imageWithSystemSymbolName:expanded ? @"chevron.down" : @"chevron.right" accessibilityDescription:nil];
	return [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightSemibold]];
}
}

@interface GitOperationSheetArea : NSView
@end
@implementation GitOperationSheetArea
- (BOOL)isFlipped { return YES; }
@end

@interface GitOperationSheet () <NSComboBoxDelegate>
@end

@implementation GitOperationSheet
{
	NSString* _title;
	NSString* _helpTopic;
	CGFloat _y, _advancedTop;
	GitOperationSheetArea* _advanced;
	GitOperationSheetArea* _footer;
	NSButton* _confirm;
	NSMapTable<NSButton*, NSArray<NSControl*>*>* _optionControls;
	NSComboBox* _branch;
	NSPopUpButton* _remote;
	SEL _remoteAction;
	__weak id _remoteTarget;
}

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithTitle:(NSString*)title detail:(NSString*)detail helpTopic:(NSString*)helpTopic
{
	if(!(self = [super initWithFrame:NSMakeRect(0, 0, sheetWidth, 0)])) return nil;
	_title = [title copy];
	_helpTopic = [helpTopic copy];
	NSImageView* icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
	icon.frame = NSMakeRect(42, 26, 52, 52);
	icon.imageScaling = NSImageScaleProportionallyUpOrDown;
	[self addSubview:icon];
	CGFloat titleEnd = AddDescription(self, title, fieldX, 21, fieldWidth, [NSFont systemFontOfSize:15 weight:NSFontWeightBold], NSColor.labelColor);
	CGFloat detailEnd = AddDescription(self, detail, fieldX, titleEnd+6, fieldWidth, [NSFont systemFontOfSize:13], NSColor.labelColor);
	_y = MAX(100, detailEnd+28);
	return self;
}

- (NSView*)fieldArea { return _advanced ?: self; }

- (void)addField:(NSControl*)control label:(NSString*)labelText
{
	NSTextField* label = GitLabel(labelText, 13, NSFontWeightMedium);
	label.alignment = NSTextAlignmentRight;
	label.frame = NSMakeRect(12, _y+5, fieldX-20, label.intrinsicContentSize.height);
	control.frame = NSMakeRect(fieldX, _y, fieldWidth, 26);
	if(!control.accessibilityLabel.length) control.accessibilityLabel = [labelText stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":"]];
	[[self fieldArea] addSubview:label];
	[[self fieldArea] addSubview:control];
	_y += 30;
}

- (NSButton*)addOption:(NSString*)title detail:(NSString*)detail
{
	NSView* parent = [self fieldArea];
	NSButton* checkbox = [NSButton checkboxWithTitle:title target:nil action:NULL];
	checkbox.frame = NSMakeRect(fieldX, _y, fieldWidth, 22);
	[parent addSubview:checkbox];
	_y = detail.length ? AddDescription(parent, detail, fieldX+19, NSMaxY(checkbox.frame)+3, fieldWidth-19, [NSFont systemFontOfSize:11.5], NSColor.secondaryLabelColor)+10 : _y+25;
	return checkbox;
}

- (void)setControls:(NSArray<NSControl*>*)controls enabledWhen:(NSButton*)option checked:(BOOL)checked
{
	if(!_optionControls) _optionControls = [NSMapTable weakToStrongObjectsMapTable];
	[_optionControls setObject:controls forKey:option];
	option.tag = checked;
	option.target = self;
	option.action = @selector(updateOptionControls:);
	[self updateOptionControls:option];
}

- (IBAction)updateOptionControls:(NSButton*)option
{
	BOOL enabled = (option.state == NSControlStateValueOn) == (option.tag != 0);
	for(NSControl* control in [_optionControls objectForKey:option]) control.enabled = enabled;
}

- (void)beginOptions
{
	NSButton* options = [NSButton buttonWithTitle:@"Options" image:OptionsImage(NO) target:self action:@selector(toggleOptions:)];
	options.imagePosition = NSImageLeading;
	options.bordered = NO;
	options.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
	options.frame = NSMakeRect(margin, _y+15, 77, 25);
	options.accessibilityExpanded = NO;
	[self addSubview:options];
	_advancedTop = NSMaxY(options.frame)+13;
	_advanced = [[GitOperationSheetArea alloc] initWithFrame:NSMakeRect(0, _advancedTop, sheetWidth, 0)];
	_advanced.hidden = YES;
	NSBox* shading = [[NSBox alloc] initWithFrame:_advanced.bounds];
	shading.boxType = NSBoxCustom;
	shading.titlePosition = NSNoTitle;
	shading.borderWidth = 0;
	shading.fillColor = [NSColor.labelColor colorWithAlphaComponent:0.12];
	shading.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	[_advanced addSubview:shading];
	[_advanced addSubview:Rule()];
	[self addSubview:_advanced];
	_y = 17;
}

- (void)presentInWindow:(NSWindow*)parent firstResponder:(NSView*)firstResponder accept:(void(^)(void))accept
{
	if(!parent || parent.attachedSheet) return;
	if(_advanced) [_advanced setFrameSize:NSMakeSize(sheetWidth, _y+6)];
	_footer = [[GitOperationSheetArea alloc] initWithFrame:NSMakeRect(0, _advanced ? _advancedTop : _y+12, sheetWidth, 60)];
	[_footer addSubview:Rule()];
	if(_helpTopic.length) {
		NSButton* help = [NSButton buttonWithTitle:@"" target:self action:@selector(showHelp:)];
		help.bezelStyle = NSBezelStyleHelpButton;
		help.accessibilityLabel = [NSString stringWithFormat:@"%@ Help", _title];
		help.frame = NSMakeRect(margin, 16, 24, 28);
		[_footer addSubview:help];
	}
	NSButton* cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
	_confirm = [NSButton buttonWithTitle:_title target:self action:@selector(accept:)];
	cancel.keyEquivalent = @"\e";
	_confirm.keyEquivalent = @"\r";
	CGFloat confirmWidth = MAX(76, _confirm.fittingSize.width+8);
	_confirm.frame = NSMakeRect(sheetWidth-margin-confirmWidth, 16, confirmWidth, 28);
	cancel.frame = NSMakeRect(NSMinX(_confirm.frame)-86, 16, 76, 28);
	[_footer addSubview:cancel];
	[_footer addSubview:_confirm];
	[self addSubview:_footer];
	[self setFrameSize:NSMakeSize(sheetWidth, NSMaxY(_footer.frame))];
	[self updateConfirmButton];
	NSPanel* sheet = [[NSPanel alloc] initWithContentRect:self.frame styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];
	sheet.title = _title;
	sheet.titleVisibility = NSWindowTitleHidden;
	sheet.titlebarAppearsTransparent = YES;
	sheet.contentView = self;
	sheet.initialFirstResponder = firstResponder ?: _confirm;
	[parent beginSheet:sheet completionHandler:^(NSModalResponse response){ if(response == NSModalResponseOK) accept(); }];
}

- (IBAction)toggleOptions:(NSButton*)sender
{
	BOOL show = _advanced.hidden;
	_advanced.hidden = !show;
	sender.image = OptionsImage(show);
	sender.accessibilityExpanded = show;
	[_footer setFrameOrigin:NSMakePoint(0, show ? NSMaxY(_advanced.frame) : _advancedTop)];
	[self.window setContentSize:NSMakeSize(sheetWidth, NSMaxY(_footer.frame))];
	[self.window recalculateKeyViewLoop];
}

- (void)requireBranch:(NSComboBox*)branch remote:(NSPopUpButton*)remote
{
	_branch = branch;
	_branch.delegate = self;
	_remote = remote;
	_remoteAction = remote.action;
	_remoteTarget = remote.target;
	remote.target = self;
	remote.action = @selector(selectRemote:);
}

- (void)updateConfirmButton
{
	_confirm.enabled = !_branch || (_remote.indexOfSelectedItem >= 0 && [_branch.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0);
}
- (IBAction)selectRemote:(id)sender
{
	if(_remoteAction && _remoteTarget) [NSApp sendAction:_remoteAction to:_remoteTarget from:sender];
	[self updateConfirmButton];
}
- (void)controlTextDidChange:(NSNotification*)notification { [self updateConfirmButton]; }
- (void)comboBoxSelectionDidChange:(NSNotification*)notification { if(_branch.indexOfSelectedItem >= 0) _confirm.enabled = YES; }
- (IBAction)accept:(id)sender
{
	if(![self.window makeFirstResponder:nil]) return;
	[self updateConfirmButton];
	if(_confirm.enabled) [self.window.sheetParent endSheet:self.window returnCode:NSModalResponseOK];
}
- (IBAction)cancel:(id)sender { [self.window.sheetParent endSheet:self.window returnCode:NSModalResponseCancel]; }
- (IBAction)showHelp:(id)sender
{
	[NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:[@"https://git-scm.com/docs/git-" stringByAppendingString:_helpTopic]]];
}
@end
