#import "GitWorkspacePanes.h"
#import "GitWorkspaceData.h"
#import "GitDiffView.h"

typedef NSString* (^SettingsOperation)(void);

namespace {
NSArray<NSArray*>* GeneralFields()
{
	return @[@[@"Committer Name", @"user.name"], @[@"Committer Email", @"user.email"],
		@[@"GitMoji", @"textmate.convertGitMoji", @"Convert GitMoji to Text on Commit"],
		@[@"Commit Message Prompt", @"textmate.commitPrompt"], @[@"Commit Template", @"commit.template", @"file"],
		@[@"Signing", @"commit.gpgsign", @"Sign Commits"], @[@"Signing Format", @"gpg.format"], @[@"Signing Key", @"user.signingkey"],
		@[@"Allowed Signers File", @"gpg.ssh.allowedSignersFile", @"file"],
		@[@"Issue Tracker URL", @"textmate.issueTrackerURL"], @[@"Issue Number Prefix", @"textmate.issueNumberPrefix"]];
}

NSArray<NSArray*>* FlowFields()
{
	return @[@[@"Production Branch", @"gitflow.branch.master", @"main"], @[@"Development Branch", @"gitflow.branch.develop", @"develop"],
		@[@"Feature Prefix", @"gitflow.prefix.feature", @"feature/"], @[@"Release Prefix", @"gitflow.prefix.release", @"release/"],
		@[@"Hotfix Prefix", @"gitflow.prefix.hotfix", @"hotfix/"], @[@"Support Prefix", @"gitflow.prefix.support", @"support/"],
		@[@"Version Tag Prefix", @"gitflow.prefix.versiontag", @""]];
}

NSString* Trim(NSString* text) { return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }
NSDictionary* LocalTool(NSString* root, NSArray* args, BOOL write = NO) { return GitRepositoryCommand(root, args, write, write ? 90 : 10); }

BOOL CommandSucceeded(NSDictionary* result) { return !result[@"error"] && ![result[@"status"] intValue]; }

NSButton* Button(NSString* title, id target, SEL action)
{
	NSButton* button = [NSButton buttonWithTitle:title target:target action:action];
	button.bezelStyle = NSBezelStyleRounded;
	return button;
}

NSStackView* VStack(NSArray<NSView*>* views, CGFloat gap)
{
	NSStackView* stack = [NSStackView stackViewWithViews:views];
	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.alignment = NSLayoutAttributeLeading;
	stack.spacing = gap;
	return stack;
}

NSTextField* Secondary(NSString* text)
{
	NSTextField* label = GitLabel(text, 12, NSFontWeightRegular);
	label.textColor = NSColor.secondaryLabelColor;
	[label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	return label;
}

NSTextField* Help(NSString* text)
{
	NSTextField* label = [NSTextField wrappingLabelWithString:text];
	label.font = [NSFont systemFontOfSize:12];
	label.textColor = NSColor.secondaryLabelColor;
	return label;
}
}

@interface GitWorkspaceSettingsPane () <NSTextViewDelegate, NSTextFieldDelegate>
@end

@interface GitSettingsFormView : NSView
@end

@implementation GitSettingsFormView
- (BOOL)isFlipped { return YES; }
@end

@implementation GitWorkspaceSettingsPane
{
	NSUInteger _generation;
	BOOL _busy;
	BOOL _dirty;
	BOOL _settingValues;
	NSInteger _tab;
	NSDictionary* _data;
	NSView* _body;
	NSView* _footer;
	NSLayoutConstraint* _bodyToFooter;
	NSLayoutConstraint* _bodyToBottom;
	NSSegmentedControl* _tabs;
	NSTextField* _name;
	NSTextField* _status;
	NSButton* _save;
	NSButton* _reload;
	NSMutableDictionary<NSString*, NSControl*>* _fields;
	NSMutableDictionary<NSString*, NSPopUpButton*>* _valueMenus;
	NSTextField* _identityName;
	NSTextField* _identityEmail;
	NSTextField* _identityInitial;
	NSButton* _identityEdit;
	NSTextView* _rules;
	NSTextField* _descriptionField;
}

- (void)loadView
{
	self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 850, 580)];
	NSImage* image = [[NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:nil]
		imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:25 weight:NSFontWeightRegular]];
	NSImageView* icon = [NSImageView imageViewWithImage:image];
	icon.contentTintColor = NSColor.secondaryLabelColor;
	_name = GitLabel(@"Repository Settings", 13, NSFontWeightSemibold);
	[_name setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[_name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	_tabs = [NSSegmentedControl segmentedControlWithLabels:@[@"General", @"Git LFS", @"Git Flow", @"Ignores", @"Excludes"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeTab:)];
	_tabs.controlSize = NSControlSizeSmall;
	_tabs.segmentStyle = NSSegmentStyleRounded;
	_tabs.selectedSegment = _tab;
	_tabs.accessibilityLabel = @"Repository settings sections";
	NSStackView* title = [NSStackView stackViewWithViews:@[icon, _name, _tabs]];
	title.spacing = 10;
	[icon.widthAnchor constraintEqualToConstant:26].active = YES;
	NSView* header = GitPaneHeader(title, 52, 20);
	_body = [[NSView alloc] init];
	_status = GitLabel(@"", 11, NSFontWeightRegular);
	_save = Button(@"Save Changes", self, @selector(save:));
	_reload = Button(@"Reload", self, @selector(reload:));
	_footer = GitPaneFooter(_status, _save);
	NSStackView* footerRow = (NSStackView*)_save.superview;
	_reload.controlSize = NSControlSizeSmall;
	[footerRow insertArrangedSubview:_reload atIndex:1];
	for(NSView* child in @[header, _body, _footer]) {
		child.translatesAutoresizingMaskIntoConstraints = NO;
		[self.view addSubview:child];
		[NSLayoutConstraint activateConstraints:@[[child.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [child.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
	}
	_bodyToFooter = [_body.bottomAnchor constraintEqualToAnchor:_footer.topAnchor];
	_bodyToBottom = [_body.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
	[NSLayoutConstraint activateConstraints:@[
		[header.topAnchor constraintEqualToAnchor:self.view.topAnchor], [_body.topAnchor constraintEqualToAnchor:header.bottomAnchor],
		_bodyToFooter, [_footer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
	]];
	[self render];
}

- (void)setRepository:(NSString*)repository
{
	if(_repository == repository || [_repository isEqual:repository]) return;
	_repository = [repository copy];
	++_generation;
	_data = nil;
	_dirty = NO;
	if(self.isViewLoaded) [self render];
}

- (void)refresh
{
	[self loadViewIfNeeded];
	if(_dirty || _busy) return;
	NSUInteger generation = ++_generation;
	NSString* root = _repository;
	_name.stringValue = root.lastPathComponent ?: @"Repository Settings";
	if(!root.length) { [self render]; return; }
	NSInteger tab = _tab;
	[self status:@"Loading repository settings…"];
	__weak GitWorkspaceSettingsPane* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableDictionary* data = [NSMutableDictionary dictionary];
		if(tab == 0 || tab == 2) {
			NSMutableDictionary* configuration = [NSMutableDictionary dictionary];
			for(NSArray* field in tab == 0 ? GeneralFields() : FlowFields()) {
				NSString* key = field[1];
				configuration[key] = GitWorkspaceConfig(root, key) ?: @"";
			}
			data[@"config"] = configuration;
			if(tab == 0) {
				if(NSString* description = GitWorkspacePath(root, @"description")) {
					data[@"path"] = description;
					[data addEntriesFromDictionary:GitWorkspaceReadFile(description)];
				}
			} else {
				data[@"tool"] = @(CommandSucceeded(LocalTool(root, @[@"flow", @"version"])));
				data[@"branches"] = GitWorkspaceReviewRefs(root);
			}
		} else if(tab == 1) {
			BOOL available = CommandSucceeded(LocalTool(root, @[@"lfs", @"version"]));
			data[@"tool"] = @(available);
			data[@"patterns"] = available ? (GitWorkspaceText(LocalTool(root, @[@"lfs", @"track"])) ?: @"") : @"";
			data[@"info"] = available ? (GitWorkspaceText(LocalTool(root, @[@"lfs", @"ls-files"])) ?: @"") : @"";
		} else {
			NSString* path = tab == 3 ? [root stringByAppendingPathComponent:@".gitignore"] : GitWorkspacePath(root, @"info/exclude");
			if(path) data[@"path"] = path;
			[data addEntriesFromDictionary:GitWorkspaceReadFile(path)];
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			GitWorkspaceSettingsPane* self = weakSelf;
			if(!self || generation != self->_generation || self->_dirty) return;
			self->_data = data;
			[self render];
		});
	});
}

- (void)status:(NSString*)text
{
	_status.stringValue = text ?: @"";
	_status.toolTip = text;
	[self updateFooter];
}

- (void)updateFooter
{
	BOOL visible = _tab != 0 || _dirty || _busy || (_data && _status.stringValue.length);
	_footer.hidden = !visible;
	if(visible) { _bodyToBottom.active = NO; _bodyToFooter.active = YES; }
	else { _bodyToFooter.active = NO; _bodyToBottom.active = YES; }
}

- (void)refreshControls
{
	_save.enabled = !_busy && _repository.length > 0 && _dirty;
	_reload.enabled = !_busy && _repository.length > 0;
	_tabs.enabled = !_busy;
	for(NSControl* field in _fields.allValues) field.enabled = !_busy;
	for(NSControl* menu in _valueMenus.allValues) menu.enabled = !_busy;
	_identityEdit.enabled = !_busy;
	_descriptionField.enabled = !_busy && _data[@"data"] != nil;
	_rules.editable = !_busy && _data[@"data"] != nil;
	[self updateFooter];
}

- (void)markDirty { if(!_settingValues && !_busy) { _dirty = YES; [self status:@"Unsaved changes"]; [self refreshControls]; } }
- (void)controlTextDidChange:(NSNotification*)notification { [self markDirty]; }
- (void)textDidChange:(NSNotification*)notification { [self markDirty]; }
- (IBAction)toggleField:(id)sender { [self markDirty]; }

- (void)discardChangesThen:(void(^)(void))proceed cancelled:(void(^)(void))cancel
{
	if(!_dirty) { proceed(); return; }
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = @"Discard unsaved settings?";
	alert.informativeText = @"Save Changes before leaving this settings section to keep your edits.";
	[alert addButtonWithTitle:@"Discard Changes"];
	[alert addButtonWithTitle:@"Keep Editing"];
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		if(response == NSAlertFirstButtonReturn) { self->_dirty = NO; proceed(); }
		else if(cancel) cancel();
	}];
}

- (IBAction)changeTab:(NSSegmentedControl*)sender
{
	NSInteger next = sender.selectedSegment;
	if(next == _tab || _busy || self.view.window.attachedSheet) return;
	[self discardChangesThen:^{
		self->_tab = next;
		self->_data = nil;
		[self render];
		[self refresh];
	} cancelled:^{ sender.selectedSegment = self->_tab; }];
}

- (IBAction)reload:(id)sender
{
	if(_busy || self.view.window.attachedSheet) return;
	[self discardChangesThen:^{ [self refresh]; } cancelled:nil];
}

- (void)showContent:(NSView*)content inScrollView:(BOOL)scroll
{
	NSView* container = content;
	if(scroll) {
		NSScrollView* view = GitScrollView(content);
		container = view;
		content.translatesAutoresizingMaskIntoConstraints = NO;
		[NSLayoutConstraint activateConstraints:@[
			[content.topAnchor constraintEqualToAnchor:view.contentView.topAnchor], [content.leadingAnchor constraintEqualToAnchor:view.contentView.leadingAnchor],
			[content.widthAnchor constraintEqualToAnchor:view.contentView.widthAnchor],
		]];
	}
	container.translatesAutoresizingMaskIntoConstraints = NO;
	[_body addSubview:container];
	[NSLayoutConstraint activateConstraints:@[
		[container.leadingAnchor constraintEqualToAnchor:_body.leadingAnchor], [container.trailingAnchor constraintEqualToAnchor:_body.trailingAnchor],
		[container.topAnchor constraintEqualToAnchor:_body.topAnchor], [container.bottomAnchor constraintEqualToAnchor:_body.bottomAnchor],
	]];
}

- (void)showForm:(NSArray<NSView*>*)rows
{
	NSView* canvas = [[GitSettingsFormView alloc] init];
	BOOL general = _tab == 0;
	NSStackView* form = VStack(rows, general ? 11 : 9);
	form.translatesAutoresizingMaskIntoConstraints = NO;
	[canvas addSubview:form];
	NSLayoutConstraint* idealWidth = [form.widthAnchor constraintEqualToConstant:general ? 910 : 610];
	idealWidth.priority = NSLayoutPriorityDefaultHigh;
	[NSLayoutConstraint activateConstraints:@[
		[form.topAnchor constraintEqualToAnchor:canvas.topAnchor constant:general ? 34 : 24], [form.bottomAnchor constraintEqualToAnchor:canvas.bottomAnchor constant:general ? -34 : -24],
		[form.centerXAnchor constraintEqualToAnchor:canvas.centerXAnchor], [form.widthAnchor constraintLessThanOrEqualToAnchor:canvas.widthAnchor constant:-36], idealWidth,
	]];
	for(NSView* row in rows) {
		[row.widthAnchor constraintEqualToAnchor:form.widthAnchor].active = YES;
		if(general && [row.identifier isEqual:@"settings-section"]) {
			NSUInteger index = [rows indexOfObjectIdenticalTo:row];
			if(index) [form setCustomSpacing:28 afterView:rows[index-1]];
			[form setCustomSpacing:17 afterView:row];
		}
	}
	[self showContent:canvas inScrollView:YES];
}

- (NSView*)row:(NSString*)title view:(NSView*)view
{
	NSTextField* label = Secondary(title);
	BOOL general = _tab == 0;
	if(general) label.font = [NSFont systemFontOfSize:13];
	label.alignment = NSTextAlignmentRight;
	label.toolTip = title;
	if(title.length) view.accessibilityLabel = title;
	NSView* spacer = [[NSView alloc] init];
	NSStackView* row = [NSStackView stackViewWithViews:general ? @[label, view, spacer] : @[label, view]];
	row.alignment = NSLayoutAttributeCenterY;
	row.spacing = general ? 20 : 14;
	if(!general) [view setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSLayoutConstraint* labelWidth = [label.widthAnchor constraintEqualToConstant:general ? 160 : 145];
	labelWidth.priority = NSLayoutPriorityRequired-1;
	[NSLayoutConstraint activateConstraints:@[labelWidth, [label.widthAnchor constraintLessThanOrEqualToAnchor:row.widthAnchor multiplier:0.39]]];
	if(general) {
		[row setCustomSpacing:0 afterView:view];
		[row.heightAnchor constraintGreaterThanOrEqualToConstant:25].active = YES;
	}
	return row;
}

- (NSView*)section:(NSString*)name
{
	NSTextField* label = GitLabel(name, 13, NSFontWeightSemibold);
	if(_tab == 0) {
		NSView* row = [self row:name.uppercaseString view:[[NSView alloc] init]];
		NSTextField* title = (NSTextField*)((NSStackView*)row).arrangedSubviews.firstObject;
		title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
		title.textColor = NSColor.labelColor;
		row.identifier = @"settings-section";
		return row;
	}
	return [self row:@"" view:label];
}

- (NSTextField*)field:(NSString*)value placeholder:(NSString*)placeholder
{
	NSTextField* field = [NSTextField textFieldWithString:value ?: @""];
	field.usesSingleLineMode = YES;
	field.font = [NSFont systemFontOfSize:12];
	field.placeholderString = placeholder;
	field.delegate = self;
	[field setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	return field;
}

- (NSView*)identityRow
{
	_fields[@"user.name"] = [self field:_data[@"config"][@"user.name"] placeholder:@"Name"];
	_fields[@"user.email"] = [self field:_data[@"config"][@"user.email"] placeholder:@"Email"];
	_identityName = GitLabel(@"", 13, NSFontWeightMedium);
	_identityEmail = GitLabel(@"", 13, NSFontWeightRegular);
	_identityInitial = GitLabel(@"", 16, NSFontWeightMedium);
	_identityInitial.textColor = NSColor.secondaryLabelColor;
	NSBox* avatar = [[NSBox alloc] init];
	avatar.boxType = NSBoxCustom;
	avatar.titlePosition = NSNoTitle;
	avatar.cornerRadius = 20;
	avatar.borderWidth = 1;
	avatar.borderColor = NSColor.separatorColor;
	avatar.fillColor = [NSColor.secondaryLabelColor colorWithAlphaComponent:0.14];
	avatar.contentViewMargins = NSZeroSize;
	_identityInitial.translatesAutoresizingMaskIntoConstraints = NO;
	[avatar.contentView addSubview:_identityInitial];
	[NSLayoutConstraint activateConstraints:@[
		[avatar.widthAnchor constraintEqualToConstant:40], [avatar.heightAnchor constraintEqualToConstant:40],
		[_identityInitial.centerXAnchor constraintEqualToAnchor:avatar.contentView.centerXAnchor],
		[_identityInitial.centerYAnchor constraintEqualToAnchor:avatar.contentView.centerYAnchor],
	]];
	_identityEdit = Button(@"Edit", self, @selector(editIdentity:));
	_identityEdit.controlSize = NSControlSizeSmall;
	NSStackView* identity = VStack(@[_identityName, _identityEmail], 3);
	for(NSTextField* field in @[_identityName, _identityEmail]) [field setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSStackView* editor = [NSStackView stackViewWithViews:@[avatar, identity, _identityEdit]];
	editor.alignment = NSLayoutAttributeCenterY;
	editor.spacing = 8;
	[self updateIdentity];
	return [self row:@"Committer Identity" view:editor];
}

- (void)updateIdentity
{
	NSString* name = _fields[@"user.name"].stringValue;
	NSString* email = _fields[@"user.email"].stringValue;
	_identityName.stringValue = name.length ? name : @"No name configured";
	_identityEmail.stringValue = email.length ? email : @"No email configured";
	_identityInitial.stringValue = name.length ? [[name substringWithRange:[name rangeOfComposedCharacterSequenceAtIndex:0]] uppercaseString] : @"?";
}

- (IBAction)editIdentity:(id)sender
{
	if(_busy || self.view.window.attachedSheet) return;
	NSString* root = _repository;
	NSTextField* name = [self field:_fields[@"user.name"].stringValue placeholder:@"Committer Name"];
	NSTextField* email = [self field:_fields[@"user.email"].stringValue placeholder:@"Committer Email"];
	for(NSTextField* field in @[name, email]) { field.delegate = nil; field.accessibilityLabel = field.placeholderString; }
	NSStackView* editor = VStack(@[name, email], 8);
	[editor.widthAnchor constraintEqualToConstant:300].active = YES;
	for(NSTextField* field in @[name, email]) [field.widthAnchor constraintEqualToAnchor:editor.widthAnchor].active = YES;
	editor.frame = NSMakeRect(0, 0, 300, 55);
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = @"Edit Committer Identity";
	alert.informativeText = @"Set the name and email used for commits in this repository.";
	alert.accessoryView = editor;
	alert.window.initialFirstResponder = name;
	[alert addButtonWithTitle:@"Done"];
	[alert addButtonWithTitle:@"Cancel"];
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		if(response != NSAlertFirstButtonReturn || ![self.repository isEqual:root] || self->_tab != 0) return;
		self->_fields[@"user.name"].stringValue = Trim(name.stringValue);
		self->_fields[@"user.email"].stringValue = Trim(email.stringValue);
		[self updateIdentity];
		[self markDirty];
	}];
}

- (void)updateValueMenu:(NSString*)key
{
	NSPopUpButton* menu = _valueMenus[key];
	NSString* value = _fields[key].stringValue;
	NSString* summary = value.stringByAbbreviatingWithTildeInPath;
	if(summary.length > 40) summary = [NSString stringWithFormat:@"%@…%@", [summary substringToIndex:14], [summary substringFromIndex:summary.length-23]];
	[menu itemAtIndex:0].title = value.length ? summary : ((NSTextField*)_fields[key]).placeholderString;
	menu.toolTip = value.length ? value : menu.accessibilityLabel;
	[menu itemAtIndex:2].enabled = value.length > 0;
	if([key isEqual:@"user.signingkey"]) {
		for(NSMenuItem* item in [menu itemAtIndex:4].submenu.itemArray)
			item.state = [item.representedObject isEqual:_fields[@"gpg.format"].stringValue] ? NSControlStateValueOn : NSControlStateValueOff;
	}
	[menu synchronizeTitleAndSelectedItem];
}

- (NSPopUpButton*)valueMenuFor:(NSString*)key title:(NSString*)title file:(BOOL)file
{
	NSPopUpButton* picker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
	picker.bezelStyle = NSBezelStyleRounded;
	picker.controlSize = NSControlSizeSmall;
	picker.accessibilityLabel = title;
	picker.menu.autoenablesItems = NO;
	[picker addItemWithTitle:title];
	NSMenuItem* edit = [picker.menu addItemWithTitle:file ? @"Choose File…" : @"Edit…" action:@selector(editMenuValue:) keyEquivalent:@""];
	edit.target = self;
	edit.representedObject = key;
	edit.tag = file ? 1 : 2;
	NSMenuItem* clear = [picker.menu addItemWithTitle:@"Clear" action:@selector(editMenuValue:) keyEquivalent:@""];
	clear.target = self;
	clear.representedObject = key;
	if([key isEqual:@"user.signingkey"]) {
		[picker.menu addItem:NSMenuItem.separatorItem];
		NSMenuItem* format = [picker.menu addItemWithTitle:@"Signing Format" action:NULL keyEquivalent:@""];
		format.submenu = [[NSMenu alloc] init];
		format.submenu.autoenablesItems = NO;
		NSArray* labels = @[@"Default", @"OpenPGP", @"SSH", @"X.509"];
		NSArray* formats = @[@"", @"openpgp", @"ssh", @"x509"];
		for(NSUInteger i = 0; i < labels.count; ++i) {
			NSMenuItem* item = [format.submenu addItemWithTitle:labels[i] action:@selector(setSigningFormat:) keyEquivalent:@""];
			item.target = self;
			item.representedObject = formats[i];
		}
	}
	_valueMenus[key] = picker;
	[self updateValueMenu:key];
	return picker;
}

- (IBAction)setSigningFormat:(NSMenuItem*)sender
{
	if(_busy || _tab != 0) return;
	_fields[@"gpg.format"].stringValue = sender.representedObject;
	[self updateValueMenu:@"user.signingkey"];
	[self markDirty];
}

- (IBAction)editMenuValue:(NSMenuItem*)sender
{
	NSString* root = _repository, *key = sender.representedObject;
	NSTextField* current = (NSTextField*)_fields[key];
	if(_busy || _tab != 0 || !current || !self.view.window || self.view.window.attachedSheet) return;
	void (^stage)(NSString*) = ^(NSString* text){
		if(![self.repository isEqual:root] || self->_fields[key] != current) return;
		current.stringValue = text;
		[self updateValueMenu:key];
		[self markDirty];
	};
	if(sender.tag == 0) { stage(@""); return; }
	if(sender.tag == 1) {
		NSOpenPanel* panel = [NSOpenPanel openPanel];
		panel.canChooseDirectories = NO;
		[panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){ if(response == NSModalResponseOK) stage(panel.URL.path); }];
		return;
	}
	NSTextField* field = [self field:current.stringValue placeholder:current.placeholderString];
	field.delegate = nil;
	field.frame = NSMakeRect(0, 0, 360, 24);
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = current.accessibilityLabel;
	alert.accessoryView = field;
	alert.window.initialFirstResponder = field;
	[alert addButtonWithTitle:@"Done"];
	[alert addButtonWithTitle:@"Cancel"];
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){ if(response == NSAlertFirstButtonReturn) stage(Trim(field.stringValue)); }];
}

- (NSTextField*)inlineField:(NSString*)value placeholder:(NSString*)hint width:(CGFloat)width
{
	NSTextField* field = [self field:value placeholder:hint];
	field.bordered = NO;
	field.bezeled = NO;
	field.drawsBackground = NO;
	field.font = [NSFont systemFontOfSize:13];
	field.lineBreakMode = NSLineBreakByTruncatingMiddle;
	field.placeholderAttributedString = [[NSAttributedString alloc] initWithString:hint attributes:@{NSForegroundColorAttributeName: NSColor.secondaryLabelColor}];
	NSLayoutConstraint* ideal = [field.widthAnchor constraintEqualToConstant:width];
	ideal.priority = NSLayoutPriorityDefaultHigh;
	ideal.active = YES;
	return field;
}

- (NSView*)configRow:(NSArray*)spec flow:(BOOL)flow
{
	NSString* title = spec[0], *key = spec[1];
	NSString* value = _data[@"config"][key];
	NSString* option = spec.count > 2 ? spec[2] : nil;
	NSControl* field;
	NSView* editor;
	BOOL checkbox = !flow && option && ![option isEqual:@"file"];
	if(checkbox) {
		NSButton* button = [NSButton checkboxWithTitle:option target:self action:@selector(toggleField:)];
		button.state = [value.lowercaseString isEqual:@"true"] || [value.lowercaseString isEqual:@"yes"] || [value.lowercaseString isEqual:@"on"] || value.intValue != 0;
		field = button;
		editor = button;
	} else {
		NSString* hint = flow ? option : [key isEqual:@"textmate.issueTrackerURL"] ? @"https://example.com/issues/{id}" : [key isEqual:@"textmate.issueNumberPrefix"] ? @"#" : [key isEqual:@"gpg.format"] ? @"openpgp, ssh, or x509" : @"Not configured";
		field = [self field:value placeholder:hint];
		editor = field;
		if(!flow) {
			NSDictionary* empty = @{@"commit.template": @"No Commit Template", @"gpg.ssh.allowedSignersFile": @"No Allowed Signers File", @"textmate.commitPrompt": @"No prompts available", @"user.signingkey": @"No Signing Key"};
			if(empty[key]) {
				((NSTextField*)field).placeholderString = empty[key];
				_fields[key] = field;
				editor = [self valueMenuFor:key title:title file:[option isEqual:@"file"]];
			} else editor = field = [self inlineField:value placeholder:[key isEqual:@"textmate.issueNumberPrefix"] ? @"#" : @"Not configured" width:[key isEqual:@"textmate.issueNumberPrefix"] ? 120 : 390];
		}
	}
	field.accessibilityLabel = title;
	field.toolTip = title;
	_fields[key] = field;
	return [self row:title view:editor];
}

- (void)render
{
	_settingValues = YES;
	for(NSView* view in [_body.subviews copy]) [view removeFromSuperview];
	_fields = [NSMutableDictionary dictionary];
	_valueMenus = [NSMutableDictionary dictionary];
	_identityName = _identityEmail = _identityInitial = nil;
	_identityEdit = nil;
	_rules = nil;
	_descriptionField = nil;
	_save.hidden = (_tab == 1 || !_repository.length);
	_tabs.selectedSegment = _tab;
	if(!_data) {
		NSString* text = _repository.length ? @"Loading repository settings…" : @"Open a folder in a Git repository to configure it.";
		NSTextField* empty = Secondary(text);
		empty.translatesAutoresizingMaskIntoConstraints = NO;
		[_body addSubview:empty];
		[NSLayoutConstraint activateConstraints:@[[empty.centerXAnchor constraintEqualToAnchor:_body.centerXAnchor], [empty.centerYAnchor constraintEqualToAnchor:_body.centerYAnchor]]];
		[self status:@""];
	} else if(_tab == 0) {
		NSMutableArray* rows = [NSMutableArray arrayWithObject:[self section:@"General"]];
		[rows addObject:[self row:@"Name" view:GitLabel(_repository.lastPathComponent, 13, NSFontWeightRegular)]];
		NSButton* reveal = GitIconButton(@"arrow.right.circle", @"Reveal in Finder", self, @selector(revealPath:));
		NSTextField* path = GitLabel(_repository.stringByAbbreviatingWithTildeInPath, 13, NSFontWeightRegular);
		[path setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
		[rows addObject:[self row:@"Path" view:[NSStackView stackViewWithViews:@[path, reveal]]]];
		_descriptionField = [self inlineField:Trim(_data[@"text"]) placeholder:@"Repository description" width:480];
		_descriptionField.enabled = _data[@"data"] != nil;
		[rows addObject:[self row:@"User Description" view:_descriptionField]];
		[rows addObject:[self identityRow]];
		_fields[@"gpg.format"] = [self field:_data[@"config"][@"gpg.format"] placeholder:nil];
		for(NSArray* field in GeneralFields()) {
			if([@[@"user.name", @"user.email", @"gpg.format"] containsObject:field[1]]) continue;
			if([field[1] isEqual:@"commit.gpgsign"]) [rows addObject:[self section:@"Signing"]];
			if([field[1] isEqual:@"textmate.issueTrackerURL"]) [rows addObject:[self section:@"Issue Tracking"]];
			[rows addObject:[self configRow:field flow:NO]];
		}
		[self showForm:rows];
		[self status:_data[@"error"]];
	} else if(_tab == 2) {
		NSMutableArray* rows = [NSMutableArray arrayWithObject:[self section:@"Git Flow"]];
		BOOL installed = [_data[@"tool"] boolValue];
		[rows addObject:Help(installed ? @"Choose the production and development branches and the prefixes that Git Flow uses for topic branches." : @"You can save a Git Flow configuration here. Install git-flow to start or finish topic branches from this view.")];
		for(NSArray* field in FlowFields()) [rows addObject:[self configRow:field flow:YES]];
		NSButton* defaults = Button(@"Use Defaults", self, @selector(useFlowDefaults:));
		NSButton* start = Button(@"Start Topic…", self, @selector(flowAction:));
		NSButton* finish = Button(@"Finish Topic…", self, @selector(flowAction:));
		finish.tag = 1;
		start.enabled = finish.enabled = installed && [_data[@"config"][@"gitflow.branch.master"] length] && [_data[@"config"][@"gitflow.branch.develop"] length];
		[rows addObject:[self row:@"Actions" view:[NSStackView stackViewWithViews:@[defaults, start, finish]]]];
		[self showForm:rows];
		[self status:installed ? @"" : @"git-flow is not installed." ];
	} else if(_tab == 1) {
		BOOL installed = [_data[@"tool"] boolValue];
		NSMutableArray* rows = [NSMutableArray arrayWithObject:[self section:@"Git LFS"]];
		[rows addObject:Help(installed ? @"Track file patterns in .gitattributes and store large file contents through Git LFS." : @"Install Git LFS to track large files. Reload this page after installation.")];
		if(installed) {
			NSArray* buttons = @[@"Set Up Repository", @"Track Pattern…", @"Untrack Pattern…", @"Pull LFS Files"];
			NSMutableArray* actions = [NSMutableArray array];
			for(NSUInteger i = 0; i < buttons.count; ++i) { NSButton* button = Button(buttons[i], self, @selector(lfsAction:)); button.tag = i; [actions addObject:button]; }
			[rows addObject:[NSStackView stackViewWithViews:actions]];
			[rows addObject:[self section:@"Tracking Patterns"]];
			[rows addObject:Help([_data[@"patterns"] length] ? Trim(_data[@"patterns"]) : @"No patterns are tracked.")];
			[rows addObject:[self section:@"LFS Files"]];
			[rows addObject:Help([_data[@"info"] length] ? Trim(_data[@"info"]) : @"No LFS files in the current revision.")];
		} else {
			NSButton* help = Button(@"Git LFS Installation Guide", self, @selector(openLFSGuide:));
			[rows addObject:[self row:@"" view:help]];
		}
		[self showForm:rows];
		[self status:installed ? @"" : @"git-lfs is not installed."];
	} else {
		NSView* editor = [[NSView alloc] init];
		NSTextField* hint = Help(_tab == 3 ? @"Patterns in .gitignore are shared when you commit the file. Enter one pattern per line." : @"Patterns in info/exclude apply only to this repository on your Mac. Enter one pattern per line.");
		_rules = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
		_rules.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
		_rules.string = _data[@"text"] ?: @"";
		_rules.editable = _data[@"data"] != nil;
		_rules.richText = NO;
		_rules.automaticQuoteSubstitutionEnabled = _rules.automaticDashSubstitutionEnabled = _rules.automaticTextReplacementEnabled = NO;
		_rules.delegate = self;
		_rules.accessibilityLabel = _tab == 3 ? @"Git Ignore Rules" : @"Local Git Exclude Rules";
		_rules.textContainerInset = NSMakeSize(8, 8);
		_rules.autoresizingMask = NSViewWidthSizable;
		_rules.textContainer.widthTracksTextView = YES;
		NSScrollView* scroll = GitScrollView(_rules);
		scroll.borderType = NSBezelBorder;
		for(NSView* view in @[hint, scroll]) {
			view.translatesAutoresizingMaskIntoConstraints = NO;
			[editor addSubview:view];
			[NSLayoutConstraint activateConstraints:@[[view.leadingAnchor constraintEqualToAnchor:editor.leadingAnchor constant:20], [view.trailingAnchor constraintEqualToAnchor:editor.trailingAnchor constant:-20]]];
		}
		[NSLayoutConstraint activateConstraints:@[[hint.topAnchor constraintEqualToAnchor:editor.topAnchor constant:14], [scroll.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:12], [scroll.bottomAnchor constraintEqualToAnchor:editor.bottomAnchor]]];
		[self showContent:editor inScrollView:NO];
		[self status:_data[@"error"] ?: _data[@"path"]];
	}
	_settingValues = NO;
	[self refreshControls];
}

- (IBAction)revealPath:(id)sender
{
	if(_repository.length) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:_repository isDirectory:YES]]];
}

- (void)run:(NSString*(^)(void))work saved:(BOOL)saved
{
	_busy = YES;
	++_generation;
	[self refreshControls];
	[self status:saved ? @"Saving settings…" : @"Running Git…"];
	NSString* root = _repository;
	__weak GitWorkspaceSettingsPane* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString* error = work();
		dispatch_async(dispatch_get_main_queue(), ^{
			GitWorkspaceSettingsPane* self = weakSelf;
			if(!self) return;
			self->_busy = NO;
			[self refreshControls];
			if(![self.repository isEqual:root]) { [self refresh]; return; }
			if(error) {
				if(!saved && self.repositoryDidChange) self.repositoryDidChange();
				[self status:error];
				return;
			}
			if(saved) self->_dirty = NO;
			if(self.repositoryDidChange) self.repositoryDidChange();
			[self refresh];
		});
	});
}

- (IBAction)save:(id)sender
{
	if(!_save.enabled || self.view.window.attachedSheet) return;
	[self.view.window makeFirstResponder:nil];
	NSString* root = _repository;
	NSString* path = _data[@"path"];
	NSData* originalFile = _data[@"data"];
	NSString* text = _rules ? _rules.string : _descriptionField.enabled ? [_descriptionField.stringValue stringByAppendingString:@"\n"] : nil;
	if(_descriptionField && [Trim(_data[@"text"]) isEqual:Trim(_descriptionField.stringValue)]) text = nil;
	BOOL saveFile = path && originalFile && text != nil;
	if(saveFile && self.hasUnsavedBuffer && self.hasUnsavedBuffer(path)) { [self status:@"Save or close the edited file in TextMate before updating it here."]; return; }
	NSDictionary* old = _data[@"config"];
	NSMutableDictionary* values = [NSMutableDictionary dictionary];
	for(NSString* key in _fields) {
		NSControl* control = _fields[key];
		NSString* value = [control isKindOfClass:NSButton.class] ? (((NSButton*)control).state ? @"true" : @"false") : Trim(control.stringValue);
		if([control isKindOfClass:NSButton.class]) {
			NSString* previous = [old[key] lowercaseString];
			BOOL enabled = [@[@"true", @"yes", @"on"] containsObject:previous] || previous.intValue != 0;
			if(enabled == [value boolValue]) continue;
		}
		if(![value isEqual:old[key]]) values[key] = value;
	}
	NSString* tracker = values[@"textmate.issueTrackerURL"];
	if(tracker.length) {
		NSURLComponents* url = [NSURLComponents componentsWithString:[tracker stringByReplacingOccurrencesOfString:@"{id}" withString:@"1"]];
		if(![@[@"https", @"http"] containsObject:url.scheme.lowercaseString ?: @""] || !url.host.length) { [self status:@"Enter a valid HTTP or HTTPS issue tracker URL."]; return; }
	}
	NSString* signing = values[@"gpg.format"];
	if(signing.length && ![@[@"openpgp", @"ssh", @"x509"] containsObject:signing]) { [self status:@"Use openpgp, ssh, or x509 for Signing Format."]; return; }
	BOOL flow = _tab == 2;
	[self run:^NSString*{
		if(flow) {
			NSString* production = values[@"gitflow.branch.master"] ?: old[@"gitflow.branch.master"], *development = values[@"gitflow.branch.develop"] ?: old[@"gitflow.branch.develop"];
			if(!production.length || !development.length || [production isEqual:development]) return @"Choose different production and development branches.";
			for(NSString* name in @[production, development])
				if(!CommandSucceeded(LocalTool(root, @[@"show-ref", @"--verify", @"--quiet", [@"refs/heads/" stringByAppendingString:name]]))) return [NSString stringWithFormat:@"Create the local branch ‘%@’ before configuring Git Flow.", name];
			for(NSString* key in values) if([key hasPrefix:@"gitflow.prefix."] && ![key isEqual:@"gitflow.prefix.versiontag"] && !CommandSucceeded(LocalTool(root, @[@"check-ref-format", [NSString stringWithFormat:@"refs/heads/%@test", values[key]]]))) return @"Enter valid Git Flow prefixes.";
		}
		if(saveFile) if(NSString* error = GitWorkspaceSaveFile(path, originalFile, text)) return error;
		for(NSString* key in [values.allKeys sortedArrayUsingSelector:@selector(compare:)])
			if(NSString* error = GitWorkspaceSetConfig(root, key, values[key])) return error;
		return nil;
	} saved:YES];
}

- (IBAction)useFlowDefaults:(id)sender
{
	NSString* production = @"main";
	for(NSDictionary* ref in _data[@"branches"]) if([ref[@"local"] boolValue] && [ref[@"name"] isEqual:@"master"]) { production = @"master"; break; }
	for(NSDictionary* ref in _data[@"branches"]) if([ref[@"local"] boolValue] && [ref[@"name"] isEqual:@"main"]) { production = @"main"; break; }
	for(NSArray* spec in FlowFields()) ((NSTextField*)_fields[spec[1]]).stringValue = [spec[1] isEqual:@"gitflow.branch.master"] ? production : spec[2];
	[self markDirty];
}

- (IBAction)openLFSGuide:(id)sender { [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://git-lfs.com/"]]; }

- (void)toolAction:(NSString*)title hint:(NSString*)hint field:(NSTextField*)field extra:(NSView*)extra prepare:(SettingsOperation(^)(NSString*))prepare
{
	if(_dirty) { [self status:@"Save or reload your settings before running this action."]; return; }
	if(_busy || !self.view.window || self.view.window.attachedSheet) return;
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = title;
	alert.informativeText = hint;
	alert.accessoryView = extra ?: field;
	[alert addButtonWithTitle:@"Continue"];
	[alert addButtonWithTitle:@"Cancel"];
	NSString* root = _repository;
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result){
		if(result != NSAlertFirstButtonReturn || ![self.repository isEqual:root]) return;
		NSString* input = Trim(field.stringValue);
		if(field && !input.length) { [self status:@"Enter a value before continuing."]; return; }
		NSString* (^work)(void) = prepare(input);
		if(work) [self run:work saved:NO];
	}];
}

- (IBAction)lfsAction:(NSButton*)sender
{
	NSString* root = _repository;
	NSInteger action = sender.tag;
	NSArray* titles = @[@"Set Up Git LFS", @"Track a File Pattern", @"Untrack a File Pattern", @"Pull LFS Files"];
	NSArray* details = @[@"Install the Git LFS filters and hooks for this repository.", @"Add a pattern to .gitattributes. Existing commits stay unchanged.", @"Remove a pattern from .gitattributes. Existing commits stay unchanged.", @"Download LFS contents and update the files in the working tree."];
	NSTextField* field = action == 1 || action == 2 ? [self field:@"" placeholder:@"For example, *.psd"] : nil;
	field.frame = NSMakeRect(0, 0, 290, 24);
	if((action == 1 || action == 2) && self.hasUnsavedBuffer && self.hasUnsavedBuffer([root stringByAppendingPathComponent:@".gitattributes"])) { [self status:@"Save .gitattributes in the editor before changing LFS patterns."]; return; }
	[self toolAction:titles[action] hint:details[action] field:field extra:nil prepare:^SettingsOperation(NSString* pattern){
		if(action == 3 && self.canChangeWorkingTree && !self.canChangeWorkingTree()) { [self status:@"Save your editor changes before pulling LFS files."]; return nil; }
		NSArray* args = action == 0 ? @[@"lfs", @"install", @"--local"] : action == 3 ? @[@"lfs", @"pull"] : @[@"lfs", action == 1 ? @"track" : @"untrack", @"--", pattern];
		return ^{ return GitWorkspaceError(LocalTool(root, args, YES), @"Git LFS could not finish the operation."); };
	}];
}

- (IBAction)flowAction:(NSButton*)sender
{
	NSString* root = _repository;
	BOOL finish = sender.tag != 0;
	NSPopUpButton* kind = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	[kind addItemsWithTitles:@[@"Feature", @"Release", @"Hotfix"]];
	NSTextField* name = [self field:@"" placeholder:@"Topic name (without prefix)"];
	NSView* form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 330, 28)];
	kind.frame = NSMakeRect(0, 0, 95, 26);
	name.frame = NSMakeRect(100, 3, 230, 23);
	[form addSubview:kind]; [form addSubview:name];
	[self toolAction:finish ? @"Finish Git Flow Topic" : @"Start Git Flow Topic" hint:finish ? @"Git Flow will integrate the topic into its base branches and may create a release tag." : @"Git Flow will create the topic from its configured base branch and check it out." field:name extra:form prepare:^SettingsOperation(NSString* topic){
		if(self.canChangeWorkingTree && !self.canChangeWorkingTree()) { [self status:@"Save your editor changes before running Git Flow."]; return nil; }
		NSString* type = kind.titleOfSelectedItem.lowercaseString;
		return ^NSString*{
			if([topic hasPrefix:@"-"] || !CommandSucceeded(LocalTool(root, @[@"check-ref-format", [@"refs/heads/" stringByAppendingString:topic]]))) return @"Enter a valid topic branch name.";
			NSMutableArray* args = [NSMutableArray arrayWithArray:@[@"-c", @"core.editor=true", @"-c", @"sequence.editor=true", @"flow", type, finish ? @"finish" : @"start"]];
			if(finish && ![type isEqual:@"feature"]) [args addObjectsFromArray:@[@"-m", [@"Release " stringByAppendingString:topic]]];
			[args addObject:topic];
			return GitWorkspaceError(LocalTool(root, args, YES), @"Git Flow could not finish the operation.");
		};
	}];
}
@end
