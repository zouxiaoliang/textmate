#import "GitRevisionView.h"
#import "GitDiffView.h"
#import "GitWorkspaceData.h"

namespace {
NSString* ShortHash(NSString* hash) { return [hash substringToIndex:MIN(8, hash.length)] ?: @""; }

NSString* FriendlyDate(NSString* value, BOOL includeTimeZone)
{
	NSDate* date = [[NSISO8601DateFormatter new] dateFromString:value ?: @""];
	if(!date) return value ?: @"";
	if(!includeTimeZone) return [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterLongStyle timeStyle:NSDateFormatterMediumStyle];
	NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
	formatter.dateStyle = NSDateFormatterLongStyle;
	formatter.timeStyle = NSDateFormatterLongStyle;
	// Git's strict ISO timestamp includes the offset recorded by the author.
	if(value.length >= 6) {
		NSString* offset = [value substringFromIndex:value.length-6];
		if([offset hasPrefix:@"+"] || [offset hasPrefix:@"-"]) {
			NSInteger seconds = [offset substringWithRange:NSMakeRange(1, 2)].integerValue*3600 + [offset substringFromIndex:4].integerValue*60;
			formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:[offset hasPrefix:@"-"] ? -seconds : seconds];
		}
	}
	return [formatter stringFromDate:date];
}

NSString* Author(NSString* name, NSString* email)
{
	return email.length ? [NSString stringWithFormat:@"%@ <%@>", name ?: @"", email] : name ?: @"";
}

NSString* ChangesetSummary(NSDictionary* details, NSUInteger count)
{
	if(!details || details[@"error"]) return @"";
	if(details[@"commits"]) return [NSString stringWithFormat:@"Showing %lu %@", (unsigned long)count, count == 1 ? @"commit" : @"commits"];
	NSString* files = [NSString stringWithFormat:@"Showing %lu %@", (unsigned long)count, count == 1 ? @"changed file" : @"changed files"];
	if(!count || !details[@"additions"]) return files;
	unsigned long additions = [details[@"additions"] unsignedLongValue], deletions = [details[@"deletions"] unsignedLongValue];
	return [files stringByAppendingFormat:@" with %lu %@ and %lu %@", additions, additions == 1 ? @"addition" : @"additions", deletions, deletions == 1 ? @"deletion" : @"deletions"];
}

NSDictionary* FileNode(NSDictionary* entry, BOOL isTree)
{
	NSMutableDictionary* node = [entry mutableCopy];
	if(!isTree) {
		NSMutableDictionary* patch = [@{@"kind": @"patch", @"path": entry[@"path"]} mutableCopy];
		if(entry[@"commit"]) patch[@"commit"] = entry[@"commit"];
		node[@"children"] = @[patch];
	}
	return node;
}

NSColor* FileColor(unichar status)
{
	return status == 'A' ? NSColor.systemGreenColor : status == 'D' ? NSColor.systemRedColor : status == 'U' ? NSColor.systemOrangeColor : NSColor.systemBlueColor;
}
}

@interface GitRevisionOutlineView : GitOutlineView
@end

@implementation GitRevisionOutlineView
- (NSRect)frameOfOutlineCellAtRow:(NSInteger)row
{
	NSRect frame = [super frameOfOutlineCellAtRow:row];
	// Align the native disclosure with the summary text while leaving Tree indentation alone.
	if(!NSIsEmptyRect(frame) && [[self itemAtRow:row] objectForKey:@"code"])
		frame.origin.x += 13;
	return frame;
}
@end

@interface GitRevisionView () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate>
@end

@implementation GitRevisionView
{
	NSString* _root;
	NSDictionary* _revision, *_comparison, *_details;
	BOOL _stash;
	BOOL _metadataCollapsed;
	BOOL _changingExpansion;
	BOOL _visiblePatchUpdateScheduled;
	BOOL _loadingDetails, _loadingTree;
	BOOL _stashActionsEnabled, _stashDiffToolEnabled;
	NSUInteger _generation;
	NSUInteger _treeGeneration;
	NSArray* _entries;
	NSTextField* _hash;
	NSView* _header;
	NSStackView* _heading;
	NSLayoutConstraint* _revisionTop;
	NSLayoutConstraint* _comparisonTop;
	NSSegmentedControl* _tabs;
	NSBox* _stashActions;
	NSArray<NSButton*>* _stashActionButtons;
	NSLayoutConstraint* _actionBarHeight;
	NSLayoutConstraint* _avatarSize;
	NSLayoutConstraint* _metadataTrailing;
	NSLayoutConstraint* _messageLeading;
	NSLayoutConstraint* _messageTrailing;
	NSLayoutConstraint* _summaryTop;
	NSButton* _toggleMetadata;
	NSBox* _avatar;
	NSTextField* _initial;
	NSButton* _expand;
	NSStackView* _metadata;
	NSTextField* _message;
	NSTextField* _summary;
	NSDictionary* _overviewItem;
	NSView* _overview;
	CGFloat _overviewHeight;
	NSOutlineView* _outline;
}

- (instancetype)initWithFrame:(NSRect)frame
{
	if(!(self = [super initWithFrame:frame])) return nil;
	_hash = GitLabel(@"", 13, NSFontWeightSemibold);
	[_hash setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[_hash setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	_tabs = [NSSegmentedControl segmentedControlWithLabels:@[@"Changeset", @"Tree"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeTab:)];
	_tabs.controlSize = NSControlSizeSmall;
	_tabs.selectedSegment = 0;
	_heading = [NSStackView stackViewWithViews:@[_hash, _tabs]];
	_header = GitPaneHeader(_heading);
	_toggleMetadata = GitIconButton(@"chevron.up.chevron.down", @"Show or hide revision metadata", self, @selector(toggleMetadata:));
	_metadata = [NSStackView stackViewWithViews:@[]];
	_metadata.orientation = NSUserInterfaceLayoutOrientationVertical;
	_metadata.alignment = NSLayoutAttributeLeading;
	_metadata.spacing = 2;
	_metadata.edgeInsets = NSEdgeInsetsMake(8, 10, 9, 0);
	NSView* metadataBox = [[NSView alloc] init];
	_avatar = [[NSBox alloc] init];
	_avatar.boxType = NSBoxCustom;
	_avatar.titlePosition = NSNoTitle;
	_avatar.borderWidth = 1;
	_avatar.borderColor = NSColor.separatorColor;
	_avatar.cornerRadius = 26;
	_avatar.fillColor = [NSColor.labelColor colorWithAlphaComponent:0.11];
	_avatar.hidden = YES;
	_initial = GitLabel(@"", 23, NSFontWeightMedium);
	_initial.textColor = NSColor.secondaryLabelColor;
	_initial.translatesAutoresizingMaskIntoConstraints = NO;
	[_avatar.contentView addSubview:_initial];
	[NSLayoutConstraint activateConstraints:@[[_initial.centerXAnchor constraintEqualToAnchor:_avatar.contentView.centerXAnchor], [_initial.centerYAnchor constraintEqualToAnchor:_avatar.contentView.centerYAnchor]]];
	for(NSView* view in @[_metadata, _avatar, _toggleMetadata]) {
		view.translatesAutoresizingMaskIntoConstraints = NO;
		[metadataBox addSubview:view];
	}
	_avatarSize = [_avatar.widthAnchor constraintEqualToConstant:52];
	_metadataTrailing = [_metadata.trailingAnchor constraintEqualToAnchor:metadataBox.trailingAnchor constant:-78];
	[NSLayoutConstraint activateConstraints:@[
		[_metadata.leadingAnchor constraintEqualToAnchor:metadataBox.leadingAnchor], _metadataTrailing,
		[_metadata.topAnchor constraintEqualToAnchor:metadataBox.topAnchor], [_metadata.bottomAnchor constraintEqualToAnchor:metadataBox.bottomAnchor],
		[_toggleMetadata.topAnchor constraintEqualToAnchor:metadataBox.topAnchor constant:6], [_toggleMetadata.trailingAnchor constraintEqualToAnchor:metadataBox.trailingAnchor constant:-9],
		[_avatar.topAnchor constraintEqualToAnchor:metadataBox.topAnchor constant:13], [_avatar.trailingAnchor constraintEqualToAnchor:metadataBox.trailingAnchor constant:-26],
		[_avatar.heightAnchor constraintEqualToAnchor:_avatar.widthAnchor], _avatarSize, [metadataBox.heightAnchor constraintGreaterThanOrEqualToConstant:23],
	]];
	_message = [NSTextField wrappingLabelWithString:@""];
	_message.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
	_message.maximumNumberOfLines = 0;
	_message.lineBreakMode = NSLineBreakByWordWrapping;
	_summary = GitLabel(@"", 11, NSFontWeightRegular);
	_summary.textColor = NSColor.secondaryLabelColor;
	_summary.alignment = NSTextAlignmentRight;
	[_summary setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	_expand = [NSButton buttonWithTitle:@"Expand All" target:self action:@selector(expandAll:)];
	_expand.controlSize = NSControlSizeSmall;
	_expand.bordered = NO;
	_expand.font = _summary.font;
	_expand.alignment = NSTextAlignmentLeft;
	[_expand.widthAnchor constraintEqualToConstant:65].active = YES;
	[_expand.heightAnchor constraintEqualToConstant:26].active = YES;
	NSStackView* summary = [NSStackView stackViewWithViews:@[_expand, _summary]];
	summary.distribution = NSStackViewDistributionFill;
	[summary.heightAnchor constraintEqualToConstant:31].active = YES;
	NSBox* rule = [[NSBox alloc] init];
	rule.boxType = NSBoxSeparator;
	NSView* actionBar = [[NSView alloc] init];
	_stashActions = [[NSBox alloc] init];
	_stashActions.boxType = NSBoxCustom;
	_stashActions.titlePosition = NSNoTitle;
	_stashActions.borderWidth = 1;
	_stashActions.borderColor = NSColor.separatorColor;
	_stashActions.cornerRadius = 8;
	_stashActions.fillColor = NSColor.controlBackgroundColor;
	_stashActions.contentViewMargins = NSZeroSize;
	_stashActions.hidden = YES;
	_stashActions.accessibilityLabel = @"Stash actions";
	NSMutableArray* buttons = [NSMutableArray array];
	NSStackView* controls = [NSStackView stackViewWithViews:@[]];
	controls.spacing = 0;
	for(NSArray* item in @[@[@"APPLY", @54, @"Apply this stash to the working copy"], @[@"DELETE", @62, @"Delete this stash"], @[@"DIFFTOOL", @74, @"Compare the stash in the configured diff tool"]]) {
		if(buttons.count) {
			NSBox* separator = [[NSBox alloc] init];
			separator.boxType = NSBoxSeparator;
			[separator.widthAnchor constraintEqualToConstant:1].active = YES;
			[separator.heightAnchor constraintEqualToConstant:20].active = YES;
			[controls addArrangedSubview:separator];
		}
		NSButton* button = [NSButton buttonWithTitle:item[0] target:self action:@selector(performStashAction:)];
		button.tag = buttons.count;
		button.bordered = NO;
		button.toolTip = item[2];
		button.accessibilityLabel = item[2];
		button.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
		[button.widthAnchor constraintEqualToConstant:[item[1] doubleValue]].active = YES;
		[button.heightAnchor constraintEqualToConstant:20].active = YES;
		[controls addArrangedSubview:button];
		[buttons addObject:button];
	}
	_stashActionButtons = buttons;
	[self setStashActionsEnabled:NO diffToolEnabled:NO];
	controls.translatesAutoresizingMaskIntoConstraints = NO;
	[_stashActions.contentView addSubview:controls];
	[NSLayoutConstraint activateConstraints:@[
		[controls.leadingAnchor constraintEqualToAnchor:_stashActions.contentView.leadingAnchor constant:1],
		[controls.trailingAnchor constraintEqualToAnchor:_stashActions.contentView.trailingAnchor constant:-1],
		[controls.topAnchor constraintEqualToAnchor:_stashActions.contentView.topAnchor constant:1],
		[controls.bottomAnchor constraintEqualToAnchor:_stashActions.contentView.bottomAnchor constant:-1],
	]];
	_actionBarHeight = [actionBar.heightAnchor constraintEqualToConstant:1];
	for(NSView* child in @[rule, _stashActions]) {
		child.translatesAutoresizingMaskIntoConstraints = NO;
		[actionBar addSubview:child];
	}
	[NSLayoutConstraint activateConstraints:@[
		_actionBarHeight, [rule.heightAnchor constraintEqualToConstant:1],
		[rule.leadingAnchor constraintEqualToAnchor:actionBar.leadingAnchor], [rule.trailingAnchor constraintEqualToAnchor:actionBar.trailingAnchor],
		[rule.centerYAnchor constraintEqualToAnchor:actionBar.centerYAnchor],
		[_stashActions.centerXAnchor constraintEqualToAnchor:actionBar.centerXAnchor], [_stashActions.centerYAnchor constraintEqualToAnchor:actionBar.centerYAnchor],
	]];
	NSBox* fileRule = [[NSBox alloc] init];
	fileRule.boxType = NSBoxSeparator;
	_overviewItem = @{ @"kind": @"overview" };
	_overview = [[NSView alloc] init];
	_overview.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
	NSView* previous = nil;
	for(NSView* child in @[metadataBox, actionBar, _message, summary, fileRule]) {
		child.translatesAutoresizingMaskIntoConstraints = NO;
		[_overview addSubview:child];
		CGFloat inset = child == _message ? 12 : child == summary ? 22 : 0;
		NSLayoutConstraint* leading = [child.leadingAnchor constraintEqualToAnchor:_overview.leadingAnchor constant:inset];
		NSLayoutConstraint* trailing = [child.trailingAnchor constraintEqualToAnchor:_overview.trailingAnchor constant:-inset];
		NSLayoutConstraint* top = [child.topAnchor constraintEqualToAnchor:previous ? previous.bottomAnchor : _overview.topAnchor constant:child == _message ? 12 : 0];
		if(child == _message) { _messageLeading = leading; _messageTrailing = trailing; }
		if(child == summary) _summaryTop = top;
		[NSLayoutConstraint activateConstraints:@[leading, trailing, top]];
		previous = child;
	}
	[fileRule.bottomAnchor constraintEqualToAnchor:_overview.bottomAnchor].active = YES;
	[fileRule.heightAnchor constraintEqualToConstant:1].active = YES;
	_outline = [[GitRevisionOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	_outline.style = NSTableViewStylePlain;
	_outline.backgroundColor = NSColor.clearColor;
	_outline.headerView = nil;
	_outline.indentationPerLevel = 11;
	_outline.rowHeight = 28;
	_outline.intercellSpacing = NSZeroSize;
	_outline.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	_outline.accessibilityLabel = @"Revision details and files";
	NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"revisionFile"];
	column.resizingMask = NSTableColumnAutoresizingMask;
	[_outline addTableColumn:column];
	_outline.outlineTableColumn = column;
	NSScrollView* list = GitScrollView(_outline);
	// A legacy scroll bar takes up layout width. Reserve that space even when
	// all the patches are collapsed so the commit message doesn't rewrap.
	list.autohidesScrollers = NO;
	for(NSView* child in @[_header, list]) {
		child.translatesAutoresizingMaskIntoConstraints = NO;
		[self addSubview:child];
		[NSLayoutConstraint activateConstraints:@[
			[child.leadingAnchor constraintEqualToAnchor:self.leadingAnchor], [child.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		]];
	}
	_revisionTop = [list.topAnchor constraintEqualToAnchor:_header.bottomAnchor];
	_comparisonTop = [list.topAnchor constraintEqualToAnchor:self.topAnchor];
	[NSLayoutConstraint activateConstraints:@[
		[_header.topAnchor constraintEqualToAnchor:self.topAnchor], _revisionTop,
		[list.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
	]];
	list.contentView.postsFrameChangedNotifications = YES;
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scrollAreaResized:) name:NSViewFrameDidChangeNotification object:list.contentView];
	list.contentView.postsBoundsChangedNotifications = YES;
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scrollAreaScrolled:) name:NSViewBoundsDidChangeNotification object:list.contentView];
	_outline.dataSource = self;
	_outline.delegate = self;
	_outline.menu = [[NSMenu alloc] init];
	_outline.menu.delegate = self;
	[self updateOverviewHeight];
	return self;
}

- (void)layout
{
	[super layout];
	[self updateMetadataVisibility];
	[self updateOverviewHeight];
}

- (void)scrollAreaResized:(NSNotification*)notification
{
	self.needsLayout = YES;
	[self scheduleVisiblePatches];
}

- (void)scrollAreaScrolled:(NSNotification*)notification { [self scheduleVisiblePatches]; }

- (void)viewDidUnhide
{
	[super viewDidUnhide];
	[self scheduleVisiblePatches];
}

- (void)toggleMetadata:(id)sender
{
	_metadataCollapsed = !_metadataCollapsed;
	[self updateMetadataVisibility];
	[self updateOverviewHeight];
}

- (void)updateMetadataVisibility
{
	for(NSView* row in _metadata.arrangedSubviews) row.hidden = _metadataCollapsed;
	BOOL showAvatar = !_metadataCollapsed && NSWidth(self.bounds) >= (_stash ? 470 : 360) && _initial.stringValue.length;
	_avatar.hidden = !showAvatar;
	_metadataTrailing.constant = !_stash || showAvatar ? -(_avatarSize.constant+26) : -26;
	_toggleMetadata.hidden = !_metadata.arrangedSubviews.count;
}

- (void)updateOverviewHeight
{
	CGFloat width = _outline.enclosingScrollView.contentSize.width;
	// AppKit may resize or recreate the overview row during an expansion. Use
	// the viewport for both the displayed width and the text measurement.
	if(width > 0 && NSWidth(_overview.frame) != width)
		[_overview setFrameSize:NSMakeSize(width, NSHeight(_overview.frame))];
	CGFloat insets = 2*_messageLeading.constant;
	if(width > insets && _message.preferredMaxLayoutWidth != width-insets)
		_message.preferredMaxLayoutWidth = width-insets;
	CGFloat height = ceil(_overview.fittingSize.height);
	if(height == _overviewHeight) return;
	_overviewHeight = height;
	NSInteger row = [_outline rowForItem:_overviewItem];
	if(row >= 0) [self updateHeightOfRow:row];
}

- (void)updateHeightOfRow:(NSInteger)row
{
	[self updateHeightsOfRows:[NSIndexSet indexSetWithIndex:row]];
}

- (void)updateHeightsOfRows:(NSIndexSet*)rows
{
	if(!rows.count) return;
	[NSAnimationContext runAnimationGroup:^(NSAnimationContext* context){
		context.duration = 0;
		context.allowsImplicitAnimation = NO;
		[self->_outline noteHeightOfRowsWithIndexesChanged:rows];
	} completionHandler:nil];
}

- (void)setSoftWrap:(BOOL)enabled
{
	if(_softWrap == enabled) return;
	_softWrap = enabled;
	if(!enabled) {
		NSMutableIndexSet* rows = [NSMutableIndexSet indexSet];
		for(NSInteger row = 0; row < _outline.numberOfRows; ++row)
			if([[_outline itemAtRow:row] objectForKey:@"wrappedHeight"]) [rows addIndex:row];
		[self updateHeightsOfRows:rows];
	}
	[self scheduleVisiblePatches];
}

- (void)addMetadata:(NSString*)label value:(NSString*)text
{
	[self addMetadata:label value:text badge:NO];
}

- (void)addMetadata:(NSString*)label value:(NSString*)text badge:(BOOL)badge
{
	if(!text.length) return;
	CGFloat size = _stash ? 12 : 11;
	NSTextField* name = GitLabel(label, size, NSFontWeightRegular);
	name.alignment = NSTextAlignmentRight;
	name.textColor = NSColor.tertiaryLabelColor;
	[name.widthAnchor constraintEqualToConstant:100].active = YES;
	NSView* value;
	if(badge) {
		value = GitBadge(text, NSColor.systemRedColor);
		value.toolTip = _revision[@"refs"];
	} else {
		NSTextField* field = GitLabel(text, size, NSFontWeightRegular);
		field.textColor = NSColor.secondaryLabelColor;
		field.toolTip = text;
		field.selectable = YES;
		value = field;
	}
	[value setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[value setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSStackView* row = [NSStackView stackViewWithViews:@[name, value]];
	row.distribution = NSStackViewDistributionFill;
	row.spacing = 8;
	[_metadata addArrangedSubview:row];
	if(!badge) [row.trailingAnchor constraintEqualToAnchor:_metadata.trailingAnchor].active = YES;
}

- (void)showRevision:(NSDictionary*)revision repository:(NSString*)root stash:(BOOL)stash
{
	[self showRevision:revision repository:root stash:stash completion:nil];
}

- (void)showRevision:(NSDictionary*)revision repository:(NSString*)root stash:(BOOL)stash completion:(void(^)(void))completion
{
	if(!revision || !root) {
		++_generation;
		_loadingDetails = _loadingTree = NO;
		_revision = _comparison = _details = nil;
		_root = nil;
		return;
	}
	BOOL same = _stash == stash && [_revision[@"id"] isEqual:revision[@"id"]] && [_root isEqual:root] && (!stash || [_revision[@"refs"] isEqual:revision[@"refs"]]);
	if(same && _details && !_loadingDetails) { if(completion) completion(); return; }
	[self loadInRepository:root revision:revision comparison:nil stash:stash completion:completion];
}

- (void)showComparison:(NSDictionary*)comparison repository:(NSString*)root
{
	[self showComparison:comparison repository:root completion:nil];
}

- (void)showComparison:(NSDictionary*)comparison repository:(NSString*)root completion:(void(^)(void))completion
{
	if([_comparison isEqual:comparison] && [_root isEqual:root] && _details && !_details[@"error"] && !_loadingDetails) {
		if(completion) completion();
		return;
	}
	[self loadInRepository:root revision:nil comparison:comparison stash:NO completion:completion];
}

- (void)updateStashLayout
{
	_heading.edgeInsets = NSEdgeInsetsMake(0, _stash ? 10 : 0, 0, 0);
	_hash.textColor = _stash ? NSColor.secondaryLabelColor : NSColor.labelColor;
	_hash.font = [NSFont systemFontOfSize:13 weight:_stash ? NSFontWeightMedium : NSFontWeightSemibold];
	_metadata.spacing = _stash ? 3 : 2;
	_metadata.edgeInsets = NSEdgeInsetsMake(_stash ? 9 : 8, 10, _stash ? 4 : 9, 0);
	_avatarSize.constant = _stash ? 80 : 52;
	_avatar.cornerRadius = _avatarSize.constant/2;
	_initial.font = [NSFont systemFontOfSize:_stash ? 32 : 23 weight:NSFontWeightMedium];
	_actionBarHeight.constant = _stash ? 22 : 1;
	_stashActions.hidden = !_stash;
	_messageLeading.constant = _stash ? 21 : 12;
	_messageTrailing.constant = -_messageLeading.constant;
	_message.font = [NSFont systemFontOfSize:13 weight:_stash ? NSFontWeightRegular : NSFontWeightMedium];
	_summaryTop.constant = _stash ? 8 : 0;
}

- (void)setStashActionsEnabled:(BOOL)enabled diffToolEnabled:(BOOL)diffToolEnabled
{
	_stashActionsEnabled = enabled;
	_stashDiffToolEnabled = diffToolEnabled;
	[self updateStashActionButtons];
}

- (void)updateStashActionButtons
{
	for(NSButton* button in _stashActionButtons) {
		button.enabled = !_loadingDetails && (button.tag == GitStashDiffTool ? _stashDiffToolEnabled : _stashActionsEnabled);
		button.attributedTitle = [[NSAttributedString alloc] initWithString:button.title attributes:@{
			NSFontAttributeName:button.font, NSForegroundColorAttributeName:button.enabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
		}];
	}
}

- (IBAction)performStashAction:(NSButton*)sender
{
	if(_stash && sender.enabled && self.stashActionHandler) self.stashActionHandler((GitStashAction)sender.tag);
}

- (void)loadInRepository:(NSString*)root revision:(NSDictionary*)revision comparison:(NSDictionary*)comparison stash:(BOOL)stash completion:(void(^)(void))completion
{
	NSUInteger generation = ++_generation;
	// Keep the visible rows and scroll position until the replacement is ready.
	_loadingDetails = YES;
	_loadingTree = NO;
	_tabs.enabled = NO;
	_expand.enabled = NO;
	[self updateStashActionButtons];
	__weak GitRevisionView* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDictionary* result;
		if(comparison[@"commits"]) result = GitWorkspaceComparisonCommits(root, comparison[@"commits"], comparison[@"tip"]);
		else if(comparison) {
			NSMutableDictionary* changes = [GitRepositoryRangeChanges(root, comparison[@"range"]) mutableCopy];
			changes[@"message"] = comparison[@"summary"] ?: @"";
			result = changes;
		} else result = stash ? GitRepositoryStashDetails(root, revision[@"id"]) : GitRepositoryCommitDetails(root, revision);
		dispatch_async(dispatch_get_main_queue(), ^{
			GitRevisionView* view = weakSelf;
			if(!view || view->_generation != generation) return;
			[NSAnimationContext runAnimationGroup:^(NSAnimationContext* context){
				context.duration = 0;
				context.allowsImplicitAnimation = NO;
				view->_root = root;
				view->_revision = revision;
				view->_comparison = comparison;
				view->_stash = stash;
				view->_details = result;
				view->_loadingDetails = NO;
				view->_hash.stringValue = comparison[@"title"] ?: ShortHash(revision[@"id"]);
				view->_hash.toolTip = revision[@"id"];
				view->_header.hidden = comparison != nil;
				// Deactivate the old top constraint before installing the replacement.
				(comparison ? view->_revisionTop : view->_comparisonTop).active = NO;
				(comparison ? view->_comparisonTop : view->_revisionTop).active = YES;
				[view updateStashLayout];
				[view updateStashActionButtons];
				view->_tabs.hidden = comparison != nil;
				view->_tabs.selectedSegment = 0;
				view->_tabs.enabled = !result[@"error"];
				[view showDetails:result];
				[view->_outline scrollPoint:NSZeroPoint];
				if(completion) completion();
			} completionHandler:nil];
		});
	});
}

- (void)showDetails:(NSDictionary*)details
{
	for(NSView* row in [_metadata.arrangedSubviews copy]) [row removeFromSuperview];
	if(_comparison) {
		for(NSArray* field in _comparison[@"metadata"]) [self addMetadata:field[0] value:field[1]];
	} else if(details) {
		[self addMetadata:@"Author" value:Author(details[@"author"], details[@"email"])];
		[self addMetadata:@"Author Date" value:FriendlyDate(details[@"date"], _stash)];
		[self addMetadata:@"Committer" value:Author(details[@"committer"], details[@"committerEmail"])];
		[self addMetadata:@"Committer Date" value:FriendlyDate(details[@"committerDate"], _stash)];
		[self addMetadata:@"Refs" value:_stash ? @"stash" : details[@"refs"] badge:_stash];
		[self addMetadata:@"Commit Hash" value:details[@"id"]];
		for(NSString* parent in details[@"parents"]) [self addMetadata:@"Parent Hash" value:parent];
		[self addMetadata:@"Tree Hash" value:details[@"tree"]];
	}
	_message.stringValue = details[@"error"] ?: details[@"message"] ?: @"";
	_message.toolTip = _message.stringValue;
	NSString* author = details[@"author"] ?: _comparison[@"author"];
	_initial.stringValue = author.length ? [[author substringWithRange:[author rangeOfComposedCharacterSequenceAtIndex:0]] uppercaseString] : @"";
	[self updateMetadataVisibility];
	[self changeTab:nil];
}

- (IBAction)changeTab:(id)sender
{
	if(_loadingDetails) return;
	++_treeGeneration;
	_loadingTree = NO;
	if(_tabs.selectedSegment == 0 || !_revision) {
		NSMutableArray* entries = [NSMutableArray array];
		NSArray* files = [_details[@"files"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
			return [a[@"path"] localizedStandardCompare:b[@"path"]];
		}];
		for(NSDictionary* file in files) [entries addObject:FileNode(file, NO)];
		for(NSDictionary* commit in _details[@"commits"]) {
			[entries addObject:[@{@"kind": @"commit", @"commit": commit} mutableCopy]];
		}
		_entries = entries;
		_expand.enabled = _entries.count > 0 && !_details[@"commits"];
		_expand.hidden = _details[@"commits"] != nil;
		_summary.stringValue = ChangesetSummary(_details, _entries.count);
		_summary.toolTip = _summary.stringValue.length ? _summary.stringValue : nil;
		[self updateOverviewHeight];
		[_outline reloadData];
		[self setExpandTitle:NO];
		return;
	}
	_loadingTree = YES;
	_expand.enabled = NO;
	[self loadTreeInItem:nil];
}

- (void)loadTreeInItem:(NSMutableDictionary*)folder
{
	NSString* root = _root, *hash = _revision[@"id"], *path = folder[@"path"];
	NSUInteger generation = _generation, treeGeneration = _treeGeneration;
	__weak GitRevisionView* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDictionary* result = GitRepositoryRevisionTree(root, hash, path);
		dispatch_async(dispatch_get_main_queue(), ^{
			GitRevisionView* view = weakSelf;
			if(!view || generation != view->_generation || treeGeneration != view->_treeGeneration || view->_tabs.selectedSegment != 1) return;
			NSMutableArray* entries = [NSMutableArray array];
			for(NSDictionary* entry in result[@"entries"]) [entries addObject:FileNode(entry, YES)];
			if(folder) { folder[@"children"] = entries; [view->_outline reloadItem:folder reloadChildren:YES]; }
			else {
				view->_loadingTree = NO;
				view->_entries = entries;
				view->_expand.hidden = YES;
				view->_summary.stringValue = result[@"error"] ?: @"Repository tree";
				view->_summary.toolTip = nil;
				[view updateOverviewHeight];
				[view->_outline reloadData];
			}
		});
	});
}

- (NSInteger)outlineView:(NSOutlineView*)view numberOfChildrenOfItem:(NSDictionary*)item { return item ? [item[@"children"] count] : _entries.count + 1; }
- (NSTableRowView*)outlineView:(NSOutlineView*)view rowViewForItem:(NSDictionary*)item
{
	if(item != _overviewItem) return GitListRow(item[@"code"] != nil);
	// Keep the overview in the outline's scroll area without indenting it like a file.
	NSTableRowView* row = [[NSTableRowView alloc] initWithFrame:[view rectOfRow:0]];
	_overview.frame = NSMakeRect(0, 0, view.enclosingScrollView.contentSize.width, NSHeight(row.bounds));
	[row addSubview:_overview];
	return row;
}
- (id)outlineView:(NSOutlineView*)view child:(NSInteger)index ofItem:(NSDictionary*)item { return item ? item[@"children"][index] : index == 0 ? _overviewItem : _entries[index-1]; }
- (BOOL)outlineView:(NSOutlineView*)view isItemExpandable:(NSDictionary*)item { return [item[@"children"] count] || (([item[@"kind"] isEqual:@"tree"] || [item[@"kind"] isEqual:@"commit"]) && !item[@"children"]); }
- (BOOL)outlineView:(NSOutlineView*)view shouldSelectItem:(NSDictionary*)item { return item != _overviewItem && ![item[@"kind"] isEqual:@"patch"]; }
- (BOOL)outlineView:(NSOutlineView*)view shouldExpandItem:(NSMutableDictionary*)item
{
	if(_loadingDetails || _loadingTree) return NO;
	if([item[@"kind"] isEqual:@"tree"] && !item[@"children"]) {
		item[@"children"] = @[@{@"kind": @"placeholder", @"name": @"Loading…"}];
		[self loadTreeInItem:item];
	}
	if([item[@"kind"] isEqual:@"commit"] && !item[@"children"]) {
		item[@"children"] = @[@{@"kind": @"placeholder", @"name": @"Loading…"}];
		NSString* root = _root;
		NSDictionary* commit = item[@"commit"];
		NSUInteger generation = _generation;
		__weak GitRevisionView* weakSelf = self;
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			NSDictionary* detail = GitRepositoryCommitDetails(root, commit);
			dispatch_async(dispatch_get_main_queue(), ^{
				GitRevisionView* self = weakSelf;
				if(!self || self->_generation != generation) return;
				NSMutableArray* files = [NSMutableArray array];
				for(NSDictionary* file in detail[@"files"]) { NSMutableDictionary* entry = [file mutableCopy]; entry[@"commit"] = commit; [files addObject:FileNode(entry, NO)]; }
				item[@"children"] = files.count ? files : @[@{@"kind": @"placeholder", @"name": detail[@"error"] ?: @"No changed files"}];
				if([self->_outline rowForItem:item] >= 0) [self->_outline reloadItem:item reloadChildren:YES];
			});
		});
	}
	return YES;
}

- (CGFloat)outlineView:(NSOutlineView*)view heightOfRowByItem:(NSDictionary*)item
{
	if(item == _overviewItem) return MAX(1, _overviewHeight);
	if([item[@"kind"] isEqual:@"patch"]) {
		NSNumber* height = (_softWrap ? item[@"wrappedHeight"] : nil) ?: item[@"height"];
		return height ? height.doubleValue : GitDiffInlineHeight(nil);
	}
	if(item[@"code"]) return 30;
	return [item[@"kind"] isEqual:@"commit"] ? 43 : 28;
}

- (void)scheduleVisiblePatches
{
	if(_visiblePatchUpdateScheduled) return;
	_visiblePatchUpdateScheduled = YES;
	__weak GitRevisionView* weakSelf = self;
	dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf updateVisiblePatches]; });
}

- (void)updateVisiblePatches
{
	_visiblePatchUpdateScheduled = NO;
	if(_loadingDetails || _loadingTree || self.hiddenOrHasHiddenAncestor || !_outline.enclosingScrollView) return;
	NSRange rows = [_outline rowsInRect:_outline.visibleRect];
	NSMutableIndexSet* resized = [NSMutableIndexSet indexSet];
	for(NSUInteger row = rows.location; row < NSMaxRange(rows); ++row) {
		NSMutableDictionary* item = [_outline itemAtRow:row];
		if(![item[@"kind"] isEqual:@"patch"]) continue;
		NSView* cell = [_outline viewAtColumn:0 row:row makeIfNecessary:NO];
		if(!cell) continue;
		if(!item[@"patch"]) {
			if(!item[@"loading"]) [self loadPatch:item];
			continue;
		}
		GitDiffView* diff = (GitDiffView*)cell.subviews.firstObject;
		if(![diff isKindOfClass:GitDiffView.class]) {
			NSString* path = item[@"path"];
			diff = [[GitDiffView alloc] initWithFrame:cell.bounds inlinePatch:YES];
			diff.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
			diff.softWrap = _softWrap;
			diff.syntaxPath = path;
			diff.syntaxThemeUUID = self.syntaxThemeUUID;
			[diff showTitle:path.lastPathComponent subtitle:@"" patch:item[@"patch"]];
			cell.subviews = @[diff];
		}
		diff.softWrap = _softWrap;
		CGFloat width = NSWidth(cell.bounds);
		if(_softWrap && width > 0) {
			CGFloat height = [diff wrappedInlineHeightForWidth:width];
			NSNumber* previous = item[@"wrappedHeight"] ?: item[@"height"];
			item[@"wrappedHeight"] = @(height);
			if(height != previous.doubleValue) [resized addIndex:row];
		}
	}
	[self updateHeightsOfRows:resized];
}

- (void)loadPatch:(NSMutableDictionary*)item
{
	item[@"loading"] = @YES;
	NSString* root = _root, *path = item[@"path"];
	NSDictionary* revision = item[@"commit"] ?: _revision, *comparison = _comparison;
	BOOL stash = _stash;
	NSUInteger generation = _generation;
	__weak GitRevisionView* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSDictionary* patch;
		if(comparison && !revision) {
			NSDictionary* result = GitRepositoryCommand(root, @[@"diff", @"--no-ext-diff", @"--no-textconv", @"--no-color", comparison[@"range"], @"--", path]);
			NSString* error = GitWorkspaceError(result, @"Git could not read this file’s diff.");
			patch = error ? @{@"error": error} : @{@"text": GitWorkspaceText(result) ?: @""};
		} else if(stash) patch = GitRepositoryStashFileDiff(root, revision[@"id"], path);
		else patch = GitRepositoryCommitDiff(root, revision, path);
		CGFloat height = GitDiffInlineHeight(patch);
		dispatch_async(dispatch_get_main_queue(), ^{
			GitRevisionView* owner = weakSelf;
			if(!owner || owner->_generation != generation) return;
			item[@"patch"] = patch;
			item[@"height"] = @(height);
			NSInteger row = [owner->_outline rowForItem:item];
			if(row < 0) return;
			[owner updateHeightOfRow:row];
			[owner scheduleVisiblePatches];
		});
	});
}

- (NSView*)outlineView:(NSOutlineView*)view viewForTableColumn:(NSTableColumn*)column item:(NSDictionary*)item
{
	if(item == _overviewItem) return nil;
	NSString* path = item[@"path"];
	if([item[@"kind"] isEqual:@"commit"]) {
		NSDictionary* commit = item[@"commit"];
		NSTextField* author = GitLabel([NSString stringWithFormat:@"%@  ·  %@", commit[@"author"], commit[@"date"]], 11, NSFontWeightRegular);
		author.textColor = NSColor.secondaryLabelColor;
		NSTextField* subject = GitLabel([NSString stringWithFormat:@"%@  %@", ShortHash(commit[@"id"]), commit[@"subject"]], 12, NSFontWeightMedium);
		[subject setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
		NSStackView* row = [NSStackView stackViewWithViews:@[author, subject]];
		row.orientation = NSUserInterfaceLayoutOrientationVertical;
		row.alignment = NSLayoutAttributeLeading;
		row.spacing = 2;
		row.edgeInsets = NSEdgeInsetsMake(5, 2, 4, 5);
		return row;
	}
	if([item[@"kind"] isEqual:@"patch"]) {
		NSView* cell = [[NSView alloc] init];
		NSTextField* loading = GitLabel(@"Loading diff…", 11, NSFontWeightRegular);
		loading.textColor = NSColor.secondaryLabelColor;
		loading.translatesAutoresizingMaskIntoConstraints = NO;
		[cell addSubview:loading];
		[NSLayoutConstraint activateConstraints:@[
			[loading.topAnchor constraintEqualToAnchor:cell.topAnchor constant:3],
			[loading.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:16],
		]];
		// Outline updates may request cells before the visible rows have settled.
		[self scheduleVisiblePatches];
		return cell;
	}
	NSString* code = item[@"code"];
	NSTextField* name = GitLabel(item[@"name"] ?: path, 12, NSFontWeightRegular);
	[name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	if(code.length) {
		unichar kind = [code characterAtIndex:0];
		NSString* description = kind == 'A' ? @"added" : kind == 'D' ? @"deleted" : kind == 'U' ? @"conflict" : kind == 'R' ? @"renamed" : @"modified";
		NSTextField* status = GitLabel(description, 11, NSFontWeightMedium);
		status.textColor = FileColor(kind);
		status.alignment = NSTextAlignmentRight;
		[status.widthAnchor constraintEqualToConstant:58].active = YES;
		name.font = [NSFont systemFontOfSize:11];
		name.textColor = NSColor.secondaryLabelColor;
		NSTextField* letter = GitLabel(code, 11, NSFontWeightSemibold);
		letter.textColor = NSColor.whiteColor;
		NSBox* badge = [[NSBox alloc] init];
		badge.boxType = NSBoxCustom;
		badge.titlePosition = NSNoTitle;
		badge.borderWidth = 0;
		badge.cornerRadius = 3;
		badge.fillColor = [FileColor(kind) colorWithAlphaComponent:0.8];
		badge.contentViewMargins = NSZeroSize;
		letter.translatesAutoresizingMaskIntoConstraints = NO;
		[badge.contentView addSubview:letter];
		[NSLayoutConstraint activateConstraints:@[
			[badge.widthAnchor constraintEqualToConstant:16], [badge.heightAnchor constraintEqualToConstant:16],
			[letter.centerXAnchor constraintEqualToAnchor:badge.contentView.centerXAnchor], [letter.centerYAnchor constraintEqualToAnchor:badge.contentView.centerYAnchor],
		]];
		NSStackView* row = [NSStackView stackViewWithViews:@[status, badge, name]];
		row.spacing = 8;
		row.edgeInsets = NSEdgeInsetsMake(0, 26, 0, 22);
		row.toolTip = path;
		return row;
	}
	NSImage* image = [NSImage imageWithSystemSymbolName:[item[@"kind"] isEqual:@"tree"] ? @"folder" : @"doc" accessibilityDescription:nil];
	NSImageView* icon = [NSImageView imageViewWithImage:image];
	icon.contentTintColor = NSColor.secondaryLabelColor;
	[icon.widthAnchor constraintEqualToConstant:14].active = YES;
	[icon.heightAnchor constraintEqualToConstant:14].active = YES;
	NSStackView* row = [NSStackView stackViewWithViews:@[icon, name]];
	row.spacing = 8;
	row.toolTip = path;
	return row;
}

- (void)populateFileMenu:(NSMenu*)menu forItem:(NSDictionary*)file
{
	NSString* path = file[@"path"];
	if(_loadingDetails || _loadingTree || !_root || !path.length || (!file[@"code"] && ![file[@"kind"] isEqual:@"blob"])) return;
	NSDictionary* revision = file[@"commit"] ?: _revision;
	NSString* hash = revision[@"id"] ?: _comparison[@"tip"];
	NSString* parent = [revision[@"parents"] firstObject] ?: [_details[@"parents"] firstObject] ?: _comparison[@"base"];
	NSDictionary* context = @{@"file": file, @"root": _root, @"hash": hash ?: @"",
		@"base": parent ?: @"", @"range": revision ? @"" : _comparison[@"range"] ?: @"",
		@"stash": @(_stash), @"generation": @(_generation)};
	auto add = [&](NSString* title, NSInteger tag, BOOL enabled = YES){
		NSMenuItem* item = [menu addItemWithTitle:title action:@selector(runFileMenuAction:) keyEquivalent:@""];
		item.target = self;
		item.tag = tag;
		item.representedObject = context;
		item.enabled = enabled;
	};
	menu.autoenablesItems = NO;
	BOOL exists = ![file[@"code"] hasPrefix:@"D"];
	NSString* name = path.lastPathComponent;
	NSString* label = [NSString stringWithFormat:@"“%@” at Revision “%@”", name, ShortHash(hash)];
	add(@"Copy File Path", 0);
	add(@"Copy Relative File Path", 1);
	[menu addItem:NSMenuItem.separatorItem];
	if(hash.length) {
		add([@"Show " stringByAppendingString:label], 2, exists);
		add([@"Show Blame for " stringByAppendingString:label], 3, exists);
	}
	if(self.showFileHistory) add([NSString stringWithFormat:@"Show File History of “%@”", name], 4);
	if(hash.length) {
		[menu addItem:NSMenuItem.separatorItem];
		add([@"Open Diff Tool for " stringByAppendingString:label], 5);
		[menu addItem:NSMenuItem.separatorItem];
		if(self.restoreFile) add([NSString stringWithFormat:@"Restore %@ in Working Copy…", label], 6, exists);
		add([NSString stringWithFormat:@"Export %@…", label], 7, exists);
	}
	if(menu.itemArray.lastObject.isSeparatorItem) [menu removeItem:menu.itemArray.lastObject];
}

- (void)menuNeedsUpdate:(NSMenu*)menu
{
	[menu removeAllItems];
	NSInteger row = _outline.clickedRow;
	if(row >= 0 && row < _outline.numberOfRows) [self populateFileMenu:menu forItem:[_outline itemAtRow:row]];
}

- (void)showFileError:(NSString*)error
{
	if(!error || !self.window || self.window.attachedSheet || self.hiddenOrHasHiddenAncestor) return;
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = @"Git action could not finish";
	alert.informativeText = error;
	[alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (IBAction)runFileMenuAction:(NSMenuItem*)sender
{
	NSDictionary* context = sender.representedObject;
	if(_loadingDetails || _loadingTree || [context[@"generation"] unsignedIntegerValue] != _generation || ![_root isEqual:context[@"root"]]) return;
	NSString* root = _root, *hash = context[@"hash"], *path = context[@"file"][@"path"];
	NSString* name = path.lastPathComponent;
	NSInteger action = sender.tag;
	if(action <= 1) {
		[NSPasteboard.generalPasteboard clearContents];
		[NSPasteboard.generalPasteboard setString:action == 0 ? [root stringByAppendingPathComponent:path] : path forType:NSPasteboardTypeString];
		return;
	}
	if(action == 4) { if(self.showFileHistory) self.showFileHistory(path); return; }
	if(!self.window || self.window.attachedSheet || !hash.length) return;
	BOOL stash = [context[@"stash"] boolValue];
	NSString*(^resolve)(void) = ^NSString*{
		if(!stash) return hash;
		NSString* untracked = [hash stringByAppendingString:@"^3"];
		NSDictionary* probe = GitRepositoryCommand(root, @[@"cat-file", @"-e", [NSString stringWithFormat:@"%@:%@", untracked, path]]);
		return !probe[@"error"] && [probe[@"status"] intValue] == 0 ? untracked : hash;
	};
	if(action == 5) {
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			NSString* base = context[@"base"];
			NSString* range = context[@"range"];
			NSString* error = nil;
			if(!base.length && [range containsString:@"..."]) {
				NSArray* sides = [range componentsSeparatedByString:@"..."];
				NSDictionary* result = GitRepositoryCommand(root, @[@"merge-base", sides.firstObject, sides.lastObject]);
				error = GitWorkspaceError(result, @"Git could not find a common ancestor.");
				base = [GitWorkspaceText(result) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
			}
			if(!error) error = stash ? GitRepositoryOpenStashDiffTool(root, hash, path) : GitRepositoryOpenRevisionDiffTool(root, base, hash, path);
			dispatch_async(dispatch_get_main_queue(), ^{ if([self->_root isEqual:root]) [self showFileError:error]; });
		});
		return;
	}
	if(action == 6) {
		if(!self.restoreFile) return;
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			NSString* revision = resolve();
			dispatch_async(dispatch_get_main_queue(), ^{ if([self->_root isEqual:root] && self.restoreFile) self.restoreFile(root, revision, path); });
		});
		return;
	}
	if(action == 7) {
		NSSavePanel* save = [NSSavePanel savePanel];
		save.nameFieldStringValue = name;
		[save beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){
			if(response != NSModalResponseOK) return;
			NSURL* destination = save.URL;
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				NSDictionary* result = GitRepositoryCommand(root, @[@"cat-file", @"blob", [NSString stringWithFormat:@"%@:%@", resolve(), path]]);
				NSString* error = GitWorkspaceError(result, @"Git could not read this file.");
				NSError* writeError = nil;
				if(!error) [result[@"data"] writeToURL:destination options:NSDataWritingAtomic error:&writeError];
				dispatch_async(dispatch_get_main_queue(), ^{ [self showFileError:error ?: writeError.localizedDescription]; });
			});
		}];
		return;
	}
	[self showFile:name subtitle:ShortHash(hash) path:path load:^NSDictionary*{
		NSString* revision = resolve();
		if(action != 3) return GitRepositoryRevisionFile(root, [NSString stringWithFormat:@"%@:%@", revision, path]);
		NSDictionary* result = GitRepositoryCommand(root, @[@"blame", @"--date=short", revision, @"--", path], NO, 30);
		NSString* error = GitWorkspaceError(result, @"Git could not read blame for this file.");
		return error ? @{@"error": error} : @{@"text": GitWorkspaceText(result) ?: @"No blame information."};
	}];
}

- (void)outlineViewSelectionDidChange:(NSNotification*)notification
{
	if(_loadingDetails || _loadingTree || _tabs.selectedSegment != 1 || _outline.selectedRow < 0) return;
	NSDictionary* file = [_outline itemAtRow:_outline.selectedRow];
	if(![file[@"kind"] isEqual:@"blob"]) return;
	NSString* root = _root, *object = file[@"object"];
	[self showFile:file[@"name"] subtitle:ShortHash(object) path:file[@"path"] load:^NSDictionary*{ return GitRepositoryRevisionFile(root, object); }];
}

- (void)showFile:(NSString*)name subtitle:(NSString*)subtitle path:(NSString*)path load:(NSDictionary*(^)(void))load
{
	NSWindow* parent = self.window;
	if(!parent || parent.attachedSheet) return;
	NSWindow* sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 660, 435) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	sheet.title = name;
	NSButton* done = [NSButton buttonWithTitle:@"Done" target:self action:@selector(closeFile:)];
	done.keyEquivalent = @"\r";
	GitDiffView* preview = [[GitDiffView alloc] initWithFrame:NSMakeRect(0, 45, 660, 390)];
	preview.showsPatch = NO;
	preview.softWrap = self.softWrap;
	preview.syntaxPath = path;
	preview.syntaxThemeUUID = self.syntaxThemeUUID;
	preview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	[sheet.contentView addSubview:preview];
	done.frame = NSMakeRect(565, 9, 83, 27);
	[sheet.contentView addSubview:done];
	[preview showTitle:name subtitle:subtitle patch:@{@"text": @"Loading file…"}];
	[parent beginSheet:sheet completionHandler:nil];
	__weak GitDiffView* weakPreview = preview;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDictionary* result = load();
		dispatch_async(dispatch_get_main_queue(), ^{ [weakPreview showTitle:name subtitle:subtitle patch:result]; });
	});
}

- (IBAction)closeFile:(NSButton*)sender { [sender.window.sheetParent endSheet:sender.window]; }

- (void)setExpandTitle:(BOOL)allExpanded
{
	_expand.attributedTitle = [[NSAttributedString alloc] initWithString:allExpanded ? @"Collapse All" : @"Expand All" attributes:@{
		NSFontAttributeName: _expand.font, NSForegroundColorAttributeName: _expand.enabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
	}];
}

- (void)updateExpandTitle
{
	if(_changingExpansion || !_expand.enabled || _expand.hidden) return;
	for(id item in _entries) if(![_outline isItemExpanded:item]) { [self setExpandTitle:NO]; return; }
	[self setExpandTitle:YES];
}

- (void)outlineViewItemDidExpand:(NSNotification*)notification { [self updateExpandTitle]; }
- (void)outlineViewItemDidCollapse:(NSNotification*)notification { [self updateExpandTitle]; }

- (IBAction)expandAll:(NSButton*)sender
{
	if(_loadingDetails || _loadingTree || !_expand.enabled || _expand.hidden) return;
	BOOL expand = [sender.title isEqual:@"Expand All"];
	NSScrollView* scroll = _outline.enclosingScrollView;
	NSClipView* clip = scroll.contentView;
	NSPoint position = clip.bounds.origin;
	_changingExpansion = YES;
	[NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
		context.duration = 0;
		context.allowsImplicitAnimation = NO;
		// In Changeset this outline contains only file rows and their patch leaves.
		if(expand) [self->_outline expandItem:nil expandChildren:YES];
		else [self->_outline collapseItem:nil collapseChildren:YES];
		NSRect bounds = clip.bounds;
		bounds.origin = position;
		[clip scrollToPoint:[clip constrainBoundsRect:bounds].origin];
		[scroll reflectScrolledClipView:clip];
	} completionHandler:nil];
	_changingExpansion = NO;
	[self setExpandTitle:expand];
}
@end
