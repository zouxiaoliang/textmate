#import "GitWorkspacePanes.h"
#import "GitWorkspaceData.h"
#import "GitDiffView.h"
#import "GitRevisionView.h"

namespace {
NSString* Readable(NSDictionary* object, NSString* key)
{
	id value = object[key];
	return [value isKindOfClass:NSString.class] ? value : @"";
}

NSString* BranchName(NSDictionary* branch)
{
	NSString* name = branch[@"name"];
	return [branch[@"archived"] boolValue] ? [name substringFromIndex:GitWorkspaceArchivePrefix.length] : name;
}

NSButton* Button(NSString* title, id target, SEL action)
{
	NSButton* button = [NSButton buttonWithTitle:title target:target action:action];
	button.controlSize = NSControlSizeSmall;
	return button;
}

NSPopUpButton* ReviewPicker(id target, SEL action)
{
	NSPopUpButton* picker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	picker.controlSize = NSControlSizeSmall;
	picker.target = target;
	picker.action = action;
	return picker;
}

NSString* EventAuthor(NSDictionary* entry)
{
	id author = entry[@"author"];
	return [author isKindOfClass:NSDictionary.class] ? Readable(author, @"login") : @"";
}
}

@interface GitWorkspaceReviewPane () <NSTableViewDelegate, NSTableViewDataSource, NSSplitViewDelegate, NSMenuDelegate>
@end

@implementation GitWorkspaceReviewPane
{
	BOOL _pullRequests;
	BOOL _busy;
	BOOL _reloadingRows;
	NSUInteger _loadGeneration, _selectionGeneration, _patchGeneration;
	NSArray<NSDictionary*>* _sources;
	NSArray<NSDictionary*>* _records;
	NSArray<NSDictionary*>* _rows;
	NSArray<NSDictionary*>* _githubRemotes;
	NSString* _autoArchiveBase;
	NSDictionary* _details, *_recordSource;
	NSPopUpButton* _source;
	NSPopUpButton* _filterMenu;
	NSPopUpButton* _sort;
	NSButton* _create;
	NSTableView* _table;
	NSTextField* _status;
	NSTextField* _detailTitle;
	NSSegmentedControl* _tabs;
	NSButton* _actionsButton;
	NSStackView* _actionBar;
	GitDiffView* _preview;
	GitRevisionView* _comparison;
}

- (instancetype)initWithPullRequests:(BOOL)pullRequests
{
	if((self = [super init])) _pullRequests = pullRequests;
	return self;
}

- (void)loadView
{
	self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 850, 570)];
	NSSplitView* split = [[NSSplitView alloc] initWithFrame:self.view.bounds];
	split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	split.vertical = YES;
	split.dividerStyle = NSSplitViewDividerStyleThin;
	split.delegate = self;
	[self.view addSubview:split];
	NSView* listPane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 314, 570)];
	NSView* detailPane = [[NSView alloc] initWithFrame:NSMakeRect(315, 0, 535, 570)];
	[split addSubview:listPane];
	[split addSubview:detailPane];
	[split setHoldingPriority:NSLayoutPriorityDefaultHigh forSubviewAtIndex:0];
	[split setHoldingPriority:NSLayoutPriorityDefaultLow forSubviewAtIndex:1];

	_create = Button(@"Create…", self, @selector(createPullRequest:));
	_source = ReviewPicker(self, @selector(changeSource:));
	_source.accessibilityLabel = _pullRequests ? @"Remote repository" : @"Compare branches against";
	[_source addItemWithTitle:_pullRequests ? @"Select Remote" : @"Select Base Branch"];
	[_source setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	_filterMenu = ReviewPicker(self, @selector(changeFilter:));
	[_filterMenu addItemsWithTitles:_pullRequests ? @[@"Open", @"All", @"Closed", @"Merged"] : @[@"All Branches", @"Active", @"Stale", @"Merged", @"Mergeable", @"Conflicts", @"Tracking Errors", @"Archived"]];
	_filterMenu.accessibilityLabel = _pullRequests ? @"Pull request state" : @"Branch status";
	_sort = ReviewPicker(self, @selector(changeFilter:));
	[_sort addItemsWithTitles:@[@"Name", @"Last Updated"]];
	_sort.accessibilityLabel = @"Sort branches";
	NSButton* filters = GitIconButton(@"line.3.horizontal.decrease.circle", @"Filter and sort branches", self, @selector(showBranchFilters:));
	NSButton* reload = GitIconButton(@"arrow.clockwise", @"Refresh branches", self, @selector(reload:));
	NSView* spacer = [[NSView alloc] init];
	NSTextField* compare = GitLabel(@"Compare local branches to:", 12, NSFontWeightRegular);
	compare.textColor = NSColor.secondaryLabelColor;
	[compare setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSStackView* titleRow = [NSStackView stackViewWithViews:_pullRequests ? @[_source, _filterMenu, spacer, _create] : @[compare, _source, spacer, filters, reload]];
	titleRow.spacing = 5;
	NSView* header = GitPaneHeader(titleRow);
	_table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 480)];
	_table.accessibilityLabel = _pullRequests ? @"Pull requests" : @"Branches to review";
	_table.backgroundColor = NSColor.clearColor;
	_table.headerView = nil;
	_table.rowHeight = _pullRequests ? 45 : 49;
	_table.style = NSTableViewStylePlain;
	_table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"review"];
	column.resizingMask = NSTableColumnAutoresizingMask;
	[_table addTableColumn:column];
	_table.delegate = self;
	_table.dataSource = self;
	_table.target = self;
	_table.doubleAction = _pullRequests ? @selector(openWeb:) : @selector(openBranch:);
	_table.menu = [[NSMenu alloc] init];
	_table.menu.delegate = self;
	_status = GitLabel(@"", 11, NSFontWeightRegular);
	NSButton* refresh = Button(@"Reload", self, @selector(reload:));
	NSView* footer = GitPaneFooter(_status, refresh);
	NSScrollView* scroll = GitScrollView(_table);
	NSView* previous = nil;
	for(NSView* child in @[header, scroll, footer]) {
		child.translatesAutoresizingMaskIntoConstraints = NO;
		[listPane addSubview:child];
		[NSLayoutConstraint activateConstraints:@[
			[child.leadingAnchor constraintEqualToAnchor:listPane.leadingAnchor], [child.trailingAnchor constraintEqualToAnchor:listPane.trailingAnchor],
			[child.topAnchor constraintEqualToAnchor:previous ? previous.bottomAnchor : listPane.topAnchor],
		]];
		previous = child;
	}
	[footer.bottomAnchor constraintEqualToAnchor:listPane.bottomAnchor].active = YES;

	_detailTitle = GitLabel(_pullRequests ? @"Pull Request" : @"Branch Comparison", 13, NSFontWeightSemibold);
	[_detailTitle setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[_detailTitle setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	if(_pullRequests) _actionsButton = Button(@"Actions", self, @selector(showActions:));
	_tabs = [NSSegmentedControl segmentedControlWithLabels:_pullRequests ? @[@"Conversation", @"Commits", @"Changeset"] : @[@"Commits", @"Changeset"]
		trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeDetailTab:)];
	_tabs.controlSize = NSControlSizeSmall;
	_tabs.selectedSegment = 0;
	_actionBar = [NSStackView stackViewWithViews:_pullRequests ? @[_detailTitle, _tabs, _actionsButton] : @[_detailTitle, _tabs]];
	_actionBar.spacing = 5;
	NSView* detailHeader = GitPaneHeader(_actionBar);
	_preview = [[GitDiffView alloc] initWithFrame:NSZeroRect];
	_comparison = [[GitRevisionView alloc] initWithFrame:NSZeroRect];
	_preview.softWrap = _comparison.softWrap = self.softWrap;
	for(NSView* child in @[detailHeader, _preview, _comparison]) {
		child.translatesAutoresizingMaskIntoConstraints = NO;
		[detailPane addSubview:child];
	}
	[NSLayoutConstraint activateConstraints:@[
		[detailHeader.leadingAnchor constraintEqualToAnchor:detailPane.leadingAnchor], [detailHeader.trailingAnchor constraintEqualToAnchor:detailPane.trailingAnchor], [detailHeader.topAnchor constraintEqualToAnchor:detailPane.topAnchor],
		[_preview.topAnchor constraintEqualToAnchor:detailHeader.bottomAnchor], [_preview.bottomAnchor constraintEqualToAnchor:detailPane.bottomAnchor],
		[_preview.leadingAnchor constraintEqualToAnchor:detailPane.leadingAnchor], [_preview.trailingAnchor constraintEqualToAnchor:detailPane.trailingAnchor],
		[_comparison.topAnchor constraintEqualToAnchor:detailHeader.bottomAnchor], [_comparison.bottomAnchor constraintEqualToAnchor:detailPane.bottomAnchor],
		[_comparison.leadingAnchor constraintEqualToAnchor:detailPane.leadingAnchor], [_comparison.trailingAnchor constraintEqualToAnchor:detailPane.trailingAnchor],
	]];
	[self clearDetails];
}

- (void)setSoftWrap:(BOOL)enabled
{
	_softWrap = enabled;
	_preview.softWrap = _comparison.softWrap = enabled;
}

- (CGFloat)splitView:(NSSplitView*)split constrainMinCoordinate:(CGFloat)value ofSubviewAt:(NSInteger)index { return MIN(245, NSWidth(split.bounds)/2); }
- (CGFloat)splitView:(NSSplitView*)split constrainMaxCoordinate:(CGFloat)value ofSubviewAt:(NSInteger)index { return MAX(NSWidth(split.bounds)-235, NSWidth(split.bounds)/2); }

- (void)setRepository:(NSString*)repository
{
	if(_repository == repository || [_repository isEqual:repository]) return;
	_repository = [repository copy];
	++_loadGeneration;
	_sources = nil;
	_githubRemotes = nil;
	_autoArchiveBase = nil;
	_records = nil;
	_recordSource = nil;
	[_source removeAllItems];
	[self reloadRowsKeepingSelection:NO];
}

- (void)setFilter:(NSString*)filter
{
	if(_filter == filter || [_filter isEqual:filter]) return;
	_filter = [filter copy];
	[self reloadRowsKeepingSelection:YES];
}

- (void)focusList { [self.view.window makeFirstResponder:_table]; }
- (IBAction)reload:(id)sender { [self refresh]; }

- (void)setStatus:(NSString*)message
{
	_status.stringValue = message;
	_status.toolTip = message;
}

- (void)refresh
{
	[self loadViewIfNeeded];
	if(_busy) return;
	NSUInteger generation = ++_loadGeneration;
	NSString* root = _repository;
	NSString* selected = [_source.selectedItem.representedObject objectForKey:_pullRequests ? @"name" : @"ref"];
	_source.enabled = _create.enabled = NO;
	if(!root.length) { [self setStatus:@"Open a folder in a Git repository."]; return; }
	[self setStatus:_pullRequests ? @"Finding GitHub remotes…" : @"Reading branches…"];
	BOOL pullRequests = _pullRequests;
	__weak GitWorkspaceReviewPane* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSArray* github = GitWorkspacePullRequestRemotes(root);
		NSArray* refs = pullRequests ? github : GitWorkspaceReviewRefs(root);
		NSString* autoArchiveBase = pullRequests ? nil : GitWorkspaceConfig(root, @"textmate.autoArchiveMergedInto");
		NSString* archiveError = nil;
		BOOL movedBranches = NO;
		if(autoArchiveBase.length && [refs indexOfObjectPassingTest:^BOOL(NSDictionary* ref, NSUInteger index, BOOL* stop){ return [ref[@"ref"] isEqual:autoArchiveBase] && ![ref[@"archived"] boolValue]; }] != NSNotFound) {
			archiveError = GitWorkspaceAutoArchiveBranches(root, refs, autoArchiveBase);
			NSArray* latest = GitWorkspaceReviewRefs(root);
			movedBranches = ![latest isEqual:refs];
			refs = latest;
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			GitWorkspaceReviewPane* self = weakSelf;
			if(!self || generation != self->_loadGeneration) return;
			self->_sources = refs;
			self->_githubRemotes = github;
			self->_autoArchiveBase = autoArchiveBase;
			if(movedBranches && self.repositoryDidChange) self.repositoryDidChange();
			[self->_source removeAllItems];
			NSInteger preferred = -1, fallback = -1, current = -1;
			for(NSDictionary* item in refs) {
				if([item[@"archived"] boolValue]) continue;
				NSString* label = item[@"name"];
				[self->_source.menu addItemWithTitle:label action:NULL keyEquivalent:@""].representedObject = item;
				NSInteger index = self->_source.numberOfItems-1;
				if([item[pullRequests ? @"name" : @"ref"] isEqual:selected]) preferred = index;
				if([label isEqual:(pullRequests ? @"origin" : @"main")] || (!pullRequests && fallback < 0 && [label isEqual:@"master"])) fallback = index;
				if([item[@"head"] boolValue]) current = index;
			}
			self->_source.enabled = self->_source.numberOfItems > 0;
			if(!self->_source.enabled) {
				[self->_source addItemWithTitle:pullRequests ? @"No GitHub Remote" : @"No Base Branch"];
				self->_records = nil;
				[self reloadRowsKeepingSelection:NO];
				[self setStatus:pullRequests ? @"Add a GitHub remote to view pull requests." : @"Create a commit to start comparing branches."];
				return;
			}
			[self->_source selectItemAtIndex:preferred >= 0 ? preferred : fallback >= 0 ? fallback : MAX(current, 0)];
			[self loadRecords];
			if(archiveError) [self showActionError:archiveError];
		});
	});
}

- (IBAction)changeSource:(id)sender { [self loadRecords]; }
- (IBAction)changeFilter:(id)sender { if(_pullRequests) [self loadRecords]; else [self reloadRowsKeepingSelection:YES]; }

- (IBAction)showBranchFilters:(NSButton*)sender
{
	NSMenu* menu = [[NSMenu alloc] init];
	for(NSMenuItem* choice in _filterMenu.itemArray) {
		NSMenuItem* item = [menu addItemWithTitle:choice.title action:@selector(takeBranchFilter:) keyEquivalent:@""];
		item.target = self;
		item.tag = [_filterMenu indexOfItem:choice];
		item.state = choice == _filterMenu.selectedItem ? NSControlStateValueOn : NSControlStateValueOff;
	}
	[menu addItem:NSMenuItem.separatorItem];
	for(NSMenuItem* choice in _sort.itemArray) {
		NSMenuItem* item = [menu addItemWithTitle:[@"Sort by " stringByAppendingString:choice.title] action:@selector(takeBranchFilter:) keyEquivalent:@""];
		item.target = self;
		item.tag = 100+[_sort indexOfItem:choice];
		item.state = choice == _sort.selectedItem ? NSControlStateValueOn : NSControlStateValueOff;
	}
	[menu addItem:NSMenuItem.separatorItem];
	BOOL enabled = _autoArchiveBase.length > 0;
	NSString* autoArchive = enabled ? @"Turn Off Auto-Archiving" : @"Auto-Archive Fully Merged Branches…";
	NSMenuItem* archive = [menu addItemWithTitle:autoArchive action:@selector(toggleAutoArchive:) keyEquivalent:@""];
	archive.target = self;
	[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds)+3) inView:sender];
}

- (IBAction)toggleAutoArchive:(id)sender
{
	NSString* root = _repository;
	NSDictionary* base = _source.selectedItem.representedObject;
	BOOL enable = !_autoArchiveBase.length;
	if(_busy || !root.length || self.view.window.attachedSheet || (enable && ![base[@"local"] boolValue])) return;
	if(!enable) {
		[self runAction:^NSString*{ return GitWorkspaceSetConfig(root, @"textmate.autoArchiveMergedInto", nil); } local:NO];
		return;
	}
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = [NSString stringWithFormat:@"Automatically Archive Branches Merged into “%@”?", BranchName(base)];
	alert.informativeText = @"When Branches Review refreshes, fully merged branches move to Archived Branches. Pinned branches, checked-out branches, and branches marked Skips Auto-Archiving stay in place.";
	[alert addButtonWithTitle:@"Enable Auto-Archiving"];
	[alert addButtonWithTitle:@"Cancel"];
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		if(response == NSAlertFirstButtonReturn && [self.repository isEqual:root]) [self runAction:^NSString*{ return GitWorkspaceSetConfig(root, @"textmate.autoArchiveMergedInto", base[@"ref"]); } local:NO];
	}];
}

- (IBAction)takeBranchFilter:(NSMenuItem*)sender
{
	if(sender.tag >= 100) [_sort selectItemAtIndex:sender.tag-100];
	else [_filterMenu selectItemAtIndex:sender.tag];
	[self reloadRowsKeepingSelection:YES];
}

- (void)loadRecords
{
	NSDictionary* source = _source.selectedItem.representedObject;
	NSString* root = _repository;
	if(!source || !root.length || _busy) return;
	NSUInteger generation = ++_loadGeneration;
	BOOL preserve = [_recordSource[_pullRequests ? @"repo" : @"id"] isEqual:source[_pullRequests ? @"repo" : @"id"]];
	if(!preserve) { _records = nil; [self reloadRowsKeepingSelection:NO]; }
	_recordSource = source;
	_create.enabled = NO;
	[self setStatus:_pullRequests ? @"Loading pull requests…" : @"Comparing local branches…"];
	NSArray* refs = _sources;
	BOOL pullRequests = _pullRequests;
	NSString* state = _filterMenu.titleOfSelectedItem.lowercaseString;
	__weak GitWorkspaceReviewPane* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDictionary* result;
		if(pullRequests) result = GitWorkspacePullRequestList(root, source, state);
		else {
			NSMutableArray* rows = [NSMutableArray array];
			for(NSDictionary* branch in refs) {
				if(![branch[@"local"] boolValue] || [branch[@"ref"] isEqual:source[@"ref"]]) continue;
				[rows addObject:GitWorkspaceReviewBranch(root, source, branch)];
			}
			result = @{@"value": rows};
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			GitWorkspaceReviewPane* self = weakSelf;
			if(!self || generation != self->_loadGeneration) return;
			self->_records = result[@"value"];
			self->_create.enabled = pullRequests && !result[@"error"];
			[self reloadRowsKeepingSelection:preserve];
			if(result[@"error"]) [self setStatus:result[@"error"]];
		});
	});
}

- (void)reloadRowsKeepingSelection:(BOOL)preserve
{
	id selected = preserve ? self.selectedRecord[_pullRequests ? @"number" : @"ref"] : nil;
	NSMutableArray* rows = [NSMutableArray array];
	NSString* status = _filterMenu.titleOfSelectedItem;
	NSTimeInterval staleBefore = NSDate.date.timeIntervalSince1970 - 90*24*60*60;
	for(NSDictionary* row in _records) {
		NSString* text;
		if(_pullRequests) text = [NSString stringWithFormat:@"#%@ %@ %@ %@ %@", row[@"number"], row[@"title"], row[@"headRefName"], row[@"baseRefName"], EventAuthor(row)];
		else {
			BOOL archived = [row[@"archived"] boolValue];
			if(archived != [status isEqual:@"Archived"]) continue;
			BOOL stale = [row[@"date"] doubleValue] < staleBefore;
			if([status isEqual:@"Stale"] && !stale) continue;
			if([status isEqual:@"Active"] && stale) continue;
			if([status isEqual:@"Tracking Errors"] && ![row[@"trackingError"] boolValue]) continue;
			if([@[@"Merged", @"Mergeable", @"Conflicts"] containsObject:status] && ![row[@"state"] isEqual:status]) continue;
			text = BranchName(row);
		}
		if(!_filter.length || [text localizedStandardContainsString:_filter]) [rows addObject:row];
	}
	if(!_pullRequests) [rows sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b){
		BOOL pinnedA = [a[@"prefs"][@"pinned"] boolValue], pinnedB = [b[@"prefs"][@"pinned"] boolValue];
		if(pinnedA != pinnedB) return pinnedA ? NSOrderedAscending : NSOrderedDescending;
		NSComparisonResult dates = self->_sort.indexOfSelectedItem == 1 ? [b[@"date"] compare:a[@"date"]] : NSOrderedSame;
		return dates == NSOrderedSame ? [BranchName(a) localizedStandardCompare:BranchName(b)] : dates;
	}];
	_reloadingRows = YES;
	_rows = rows;
	[_table reloadData];
	NSUInteger row = [_rows indexOfObjectPassingTest:^BOOL(NSDictionary* record, NSUInteger index, BOOL* stop){ return [record[self->_pullRequests ? @"number" : @"ref"] isEqual:selected]; }];
	if(row == NSNotFound && !_pullRequests && _rows.count) row = 0;
	[_table selectRowIndexes:row == NSNotFound ? NSIndexSet.indexSet : [NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	_reloadingRows = NO;
	if(_records) [self setStatus:[NSString stringWithFormat:@"%lu %@", (unsigned long)_rows.count, _pullRequests ? (_rows.count == 1 ? @"pull request" : @"pull requests") : (_rows.count == 1 ? @"branch" : @"branches")]];
	[self loadDetails];
}

- (NSDictionary*)selectedRecord
{
	NSInteger row = _table ? _table.selectedRow : -1;
	return row >= 0 && row < _rows.count ? _rows[row] : nil;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView { return _rows.count; }
- (NSTableRowView*)tableView:(NSTableView*)tableView rowViewForRow:(NSInteger)row { return GitListRow(); }

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column row:(NSInteger)index
{
	NSDictionary* row = _rows[index];
	NSString* title = _pullRequests ? [NSString stringWithFormat:@"#%@  %@", row[@"number"], row[@"title"]] : BranchName(row);
	if(!_pullRequests) {
		NSString* state = row[@"state"];
		BOOL pinned = [row[@"prefs"][@"pinned"] boolValue], merged = [state isEqual:@"Merged"] && ![row[@"prefs"][@"hidemergedhint"] boolValue];
		NSString* symbol = pinned ? @"pin.fill" : [state isEqual:@"Conflicts"] ? @"exclamationmark.triangle.fill" : [state isEqual:@"Mergeable"] ? @"checkmark.circle.fill" : merged ? @"checkmark.circle" : @"arrow.turn.up.right";
		NSImageView* icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:state]];
		icon.contentTintColor = [state isEqual:@"Conflicts"] ? NSColor.systemOrangeColor : [state isEqual:@"Mergeable"] ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
		[icon.widthAnchor constraintEqualToConstant:14].active = YES;
		NSTextField* name = GitLabel(title, 12, NSFontWeightMedium);
		NSTextField* tracking = GitLabel([row[@"trackingError"] boolValue] ? @"Tracking branch is gone" : [row[@"upstream"] length] ? row[@"upstream"] : @"No tracking branch", 11, NSFontWeightRegular);
		for(NSTextField* label in @[name, tracking]) {
			[label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
			[label setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
		}
		tracking.textColor = NSColor.secondaryLabelColor;
		NSTextField* counts = GitLabel([NSString stringWithFormat:@"↑%@  ↓%@", row[@"ahead"] ?: @"–", row[@"behind"] ?: @"–"], 10, NSFontWeightRegular);
		NSDate* date = [NSDate dateWithTimeIntervalSince1970:[row[@"date"] doubleValue]];
		NSRelativeDateTimeFormatter* formatter = [[NSRelativeDateTimeFormatter alloc] init];
		formatter.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleShort;
		NSTextField* relative = GitLabel([formatter localizedStringForDate:date relativeToDate:NSDate.date], 10, NSFontWeightRegular);
		for(NSTextField* label in @[counts, relative]) label.textColor = NSColor.tertiaryLabelColor;
		NSStackView* primary = [NSStackView stackViewWithViews:@[icon, name, counts]];
		NSView* indent = [[NSView alloc] init];
		[indent.widthAnchor constraintEqualToConstant:14].active = YES;
		NSStackView* secondary = [NSStackView stackViewWithViews:@[indent, tracking, relative]];
		primary.spacing = secondary.spacing = 6;
		primary.distribution = secondary.distribution = NSStackViewDistributionFill;
		NSStackView* cell = [NSStackView stackViewWithViews:@[primary, secondary]];
		cell.orientation = NSUserInterfaceLayoutOrientationVertical;
		cell.alignment = NSLayoutAttributeLeading;
		cell.spacing = 3;
		cell.edgeInsets = NSEdgeInsetsMake(5, 10, 4, 10);
		[primary.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-10].active = YES;
		[secondary.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-10].active = YES;
		cell.toolTip = [NSString stringWithFormat:@"%@ — %@", title, state];
		return cell;
	}
	NSString* detail = [NSString stringWithFormat:@"%@  ·  %@ → %@", [row[@"isDraft"] boolValue] && [row[@"state"] isEqual:@"OPEN"] ? @"Draft" : [row[@"state"] capitalizedString], row[@"headRefName"], row[@"baseRefName"]];
	NSTextField* name = GitLabel(title, 12, NSFontWeightMedium);
	NSTextField* subtitle = GitLabel(detail, 11, NSFontWeightRegular);
	subtitle.textColor = NSColor.secondaryLabelColor;
	NSStackView* view = [NSStackView stackViewWithViews:@[name, subtitle]];
	view.orientation = NSUserInterfaceLayoutOrientationVertical;
	view.alignment = NSLayoutAttributeLeading;
	view.edgeInsets = NSEdgeInsetsMake(5, 10, 3, 8);
	view.spacing = 2;
	view.toolTip = title;
	for(NSTextField* label in @[name, subtitle]) [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	return view;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification { if(!_reloadingRows) [self loadDetails]; }

- (void)clearDetails
{
	++_selectionGeneration;
	++_patchGeneration;
	_details = nil;
	[_comparison showRevision:nil repository:nil stash:NO];
	_comparison.hidden = YES;
	_preview.hidden = NO;
	_tabs.enabled = NO;
	_actionsButton.enabled = NO;
	_detailTitle.stringValue = _pullRequests ? @"Pull Request" : @"Branch Comparison";
	[_preview showTitle:_pullRequests ? @"No pull request selected" : @"No branch selected" subtitle:@"" patch:@{@"text": @""}];
}

- (void)loadDetails
{
	NSDictionary* record = self.selectedRecord;
	if(!record) { [self clearDetails]; return; }
	if(!_pullRequests) { [self changeDetailTab:nil]; return; }
	NSUInteger generation = ++_selectionGeneration;
	++_patchGeneration;
	_details = nil;
	_tabs.enabled = NO;
	_actionsButton.enabled = NO;
	NSString* root = _repository;
	NSDictionary* remote = _recordSource;
	__weak GitWorkspaceReviewPane* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDictionary* result = GitWorkspacePullRequestDetails(root, remote, record[@"number"]);
		dispatch_async(dispatch_get_main_queue(), ^{
			GitWorkspaceReviewPane* self = weakSelf;
			if(!self || generation != self->_selectionGeneration) return;
			self->_details = result[@"value"];
			self->_tabs.enabled = self->_details != nil;
			if(result[@"error"]) [self showPullRequest:record[@"title"] subtitle:@"" patch:result];
			else [self changeDetailTab:nil];
		});
	});
}

- (IBAction)changeDetailTab:(id)sender
{
	NSDictionary* row = self.selectedRecord;
	if(!row) return;
	NSUInteger generation = ++_patchGeneration;
	NSInteger tab = _tabs.selectedSegment;
	NSString* root = _repository;
	NSDictionary* source = _recordSource;
	NSString* title, *subtitle, *text = nil;
	NSDictionary* (^load)(void) = nil;
	if(_pullRequests) {
		if(!_details) return;
		title = [NSString stringWithFormat:@"#%@  %@", row[@"number"], row[@"title"]];
		subtitle = [NSString stringWithFormat:@"%@ → %@  ·  %@%@", row[@"headRefName"], row[@"baseRefName"], [row[@"state"] capitalizedString], Readable(_details, @"reviewDecision").length ? [@" · " stringByAppendingString:Readable(_details, @"reviewDecision")] : @""];
		if(tab == 0) {
			NSMutableString* conversation = [NSMutableString stringWithFormat:@"%@  %@\n\n%@", EventAuthor(_details), Readable(_details, @"createdAt"), Readable(_details, @"body")];
			NSMutableArray* events = [NSMutableArray array];
			for(NSDictionary* event in _details[@"comments"]) [events addObject:@{ @"date": Readable(event, @"createdAt"), @"title": EventAuthor(event), @"body": Readable(event, @"body") }];
			for(NSDictionary* event in _details[@"reviews"]) [events addObject:@{ @"date": Readable(event, @"submittedAt"), @"title": [NSString stringWithFormat:@"%@  %@", EventAuthor(event), Readable(event, @"state")], @"body": Readable(event, @"body") }];
			for(NSDictionary* event in _details[@"commits"]) [events addObject:@{ @"date": Readable(event, @"committedDate"), @"title": @"Commit", @"body": Readable(event, @"messageHeadline") }];
			[events sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"date" ascending:YES]]];
			for(NSDictionary* event in events) [conversation appendFormat:@"\n\n%@  %@\n%@", event[@"title"], event[@"date"], event[@"body"]];
			text = conversation;
		} else if(tab == 1) {
			NSMutableString* commits = [NSMutableString string];
			for(NSDictionary* commit in _details[@"commits"]) {
				NSString* hash = Readable(commit, @"oid");
				[commits appendFormat:@"%@  %@\n%@\n\n", [hash substringToIndex:MIN(hash.length, 8)], Readable(commit, @"messageHeadline"), Readable(commit, @"messageBody")];
			}
			text = commits.length ? commits : @"No commits.";
		} else load = ^{ return GitWorkspacePullRequestCommand(root, source, @[@"diff", [row[@"number"] stringValue], @"--color", @"never"]); };
	} else {
		NSString* base = source[@"name"];
		title = [NSString stringWithFormat:@"%@ ⇆ %@", BranchName(row), base];
		NSDate* date = [NSDate dateWithTimeIntervalSince1970:[row[@"date"] doubleValue]];
		NSString* tracking = [row[@"upstream"] length] ? row[@"upstream"] : @"No tracking branch";
		NSString* status = [row[@"state"] isEqual:@"Merged"] ? @"Fully merged" : [row[@"state"] isEqual:@"Mergeable"] ? [@"Can be merged into " stringByAppendingString:base] : [row[@"state"] isEqual:@"Conflicts"] ? @"Would cause merge conflicts" : @"Conflict check unavailable";
		NSMutableArray* metadata = [NSMutableArray arrayWithArray:@[@[@"Last Updated", [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterLongStyle timeStyle:NSDateFormatterShortStyle]],
			@[@"Tracking", [row[@"trackingError"] boolValue] ? [tracking stringByAppendingString:@" (missing)"] : tracking],
			@[@"Merge Status", [NSString stringWithFormat:@"%@ commits ahead, %@ behind %@", row[@"ahead"] ?: @"–", row[@"behind"] ?: @"–", base]]]];
		if(![row[@"state"] isEqual:@"Merged"] || ![row[@"prefs"][@"hidemergedhint"] boolValue]) [metadata addObject:@[@"", status]];
		if(NSString* parent = row[@"prefs"][@"parent"]) {
			NSString* name = [parent hasPrefix:@"refs/heads/"] ? [parent substringFromIndex:11] : [parent hasPrefix:@"refs/remotes/"] ? [parent substringFromIndex:13] : parent;
			[metadata insertObject:@[@"Parent Branch", name] atIndex:2];
		}
		if([row[@"conflicts"] count]) [metadata addObject:@[@"Conflicting Files", [row[@"conflicts"] componentsJoinedByString:@", "]]];
		if([row[@"author"] length]) [metadata insertObject:@[@"Contributor", row[@"author"]] atIndex:0];
		NSString* range = [NSString stringWithFormat:tab == 0 ? @"%@..%@" : @"%@...%@", source[@"id"], row[@"id"]];
		__weak GitWorkspaceReviewPane* weakSelf = self;
		[_comparison showComparison:tab == 0 ? @{@"title": title, @"metadata": metadata, @"commits": range, @"tip": row[@"id"], @"author": row[@"author"] ?: @""}
			: @{@"title": title, @"metadata": metadata, @"range": range, @"tip": row[@"id"], @"author": row[@"author"] ?: @""} repository:root completion:^{
			GitWorkspaceReviewPane* self = weakSelf;
			if(!self || generation != self->_patchGeneration) return;
			self->_detailTitle.stringValue = title;
			self->_tabs.enabled = YES;
			self->_preview.hidden = YES;
			self->_comparison.hidden = NO;
		}];
		return;
	}
	if(!load) { [self showPullRequest:title subtitle:subtitle patch:@{@"text": text}]; return; }
	__weak GitWorkspaceReviewPane* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDictionary* result = load();
		NSString* error = GitWorkspaceError(result, @"Could not compare these revisions.");
		NSString* output = GitWorkspaceText(result);
		dispatch_async(dispatch_get_main_queue(), ^{
			GitWorkspaceReviewPane* self = weakSelf;
			if(!self || generation != self->_patchGeneration) return;
			[self showPullRequest:title subtitle:subtitle patch:error ? @{@"error": error} : @{@"text": output.length ? output : @"No differences to display."}];
		});
	});
}

- (void)showPullRequest:(NSString*)title subtitle:(NSString*)subtitle patch:(NSDictionary*)patch
{
	_detailTitle.stringValue = title;
	[_preview showTitle:title subtitle:subtitle patch:patch];
	_actionsButton.enabled = YES;
}

- (void)populateActions:(NSMenu*)menu forRecord:(NSDictionary*)row
{
	if(!row || _busy) return;
	if(!_pullRequests) {
		if(self.populateBranchMenu) self.populateBranchMenu(menu, row, _sources, _githubRemotes);
		return;
	}
	auto add = [&](NSString* title, SEL selector, NSInteger tag = 0){
		NSMenuItem* item = [menu addItemWithTitle:title action:selector keyEquivalent:@""];
		item.target = self;
		item.tag = tag;
		item.representedObject = row;
	};
	{
		add(@"Open in Browser", @selector(openWeb:));
		add(@"Copy Link", @selector(copyLink:));
		[menu addItem:NSMenuItem.separatorItem];
		if(self.canCheckOut && self.canCheckOut()) add(@"Check Out", @selector(pullRequestAction:));
		if([row[@"state"] isEqual:@"OPEN"]) {
			add(@"Add Comment…", @selector(pullRequestAction:), 1);
			add(@"Approve…", @selector(pullRequestAction:), 2);
			add(@"Request Changes…", @selector(pullRequestAction:), 3);
			if(![row[@"isDraft"] boolValue] && [row[@"headRefOid"] length]) add(@"Merge…", @selector(pullRequestAction:), 4);
			add(@"Close…", @selector(pullRequestAction:), 5);
		} else if([row[@"state"] isEqual:@"CLOSED"]) add(@"Reopen…", @selector(pullRequestAction:), 6);
	}
	if(menu.itemArray.lastObject.isSeparatorItem) [menu removeItem:menu.itemArray.lastObject];
}

- (void)menuNeedsUpdate:(NSMenu*)menu
{
	[menu removeAllItems];
	NSInteger index = _table.clickedRow;
	if(index >= 0 && index < _rows.count) [self populateActions:menu forRecord:_rows[index]];
}

- (IBAction)showActions:(NSButton*)sender
{
	NSMenu* menu = [[NSMenu alloc] init];
	[self populateActions:menu forRecord:self.selectedRecord];
	if(menu.numberOfItems) [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds)+3) inView:sender];
}

- (NSDictionary*)recordForAction:(id)sender
{
	if(![sender isKindOfClass:NSMenuItem.class]) return self.selectedRecord;
	NSDictionary* row = [sender representedObject];
	return [_rows indexOfObjectIdenticalTo:row] != NSNotFound ? row : nil;
}

- (IBAction)openBranch:(id)sender { if(NSString* ref = [self recordForAction:sender][@"ref"]) if(self.showHistory) self.showHistory(ref); }

- (IBAction)openWeb:(id)sender
{
	NSString* link = [self recordForAction:sender][@"url"];
	if(!link.length) return;
	NSURL* url = [NSURL URLWithString:link];
	if([url.scheme isEqual:@"https"] && [url.host.lowercaseString isEqual:_recordSource[@"host"]]) [NSWorkspace.sharedWorkspace openURL:url];
}

- (IBAction)copyLink:(id)sender
{
	if(NSString* url = [self recordForAction:sender][@"url"]) {
		[NSPasteboard.generalPasteboard clearContents];
		[NSPasteboard.generalPasteboard setString:url forType:NSPasteboardTypeString];
	}
}

- (void)runAction:(NSString*(^)(void))work local:(BOOL)local
{
	_busy = YES;
	++_loadGeneration;
	_create.enabled = _source.enabled = _filterMenu.enabled = NO;
	[self setStatus:@"Working…"];
	NSString* root = _repository;
	__weak GitWorkspaceReviewPane* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString* error = work();
		dispatch_async(dispatch_get_main_queue(), ^{
			GitWorkspaceReviewPane* self = weakSelf;
			if(!self) return;
			self->_busy = NO;
			self->_filterMenu.enabled = YES;
			if(![self.repository isEqual:root]) { [self refresh]; return; }
			if(!error) {
				if(local && self.repositoryDidChange) self.repositoryDidChange();
				[self refresh];
			} else {
				self->_source.enabled = self->_source.numberOfItems > 0;
				self->_create.enabled = self->_pullRequests && self->_records != nil;
				[self setStatus:error];
				[self showActionError:error];
			}
		});
	});
}

- (void)showActionError:(NSString*)error
{
	if(!self.view.window || self.view.isHiddenOrHasHiddenAncestor || self.view.window.attachedSheet) return;
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = @"The operation could not be completed";
	alert.informativeText = error;
	[alert beginSheetModalForWindow:self.view.window completionHandler:nil];
}

- (void)runPullRequest:(NSArray*)args local:(BOOL)local
{
	NSString* root = _repository;
	NSDictionary* remote = _recordSource;
	if(!root || !remote || _busy) return;
	[self runAction:^NSString*{
		return GitWorkspaceError(GitWorkspacePullRequestCommand(root, remote, args), @"GitHub could not complete the operation.");
	} local:local];
}

- (IBAction)pullRequestAction:(NSMenuItem*)sender
{
	NSDictionary* row = [self recordForAction:sender];
	NSString* root = _repository;
	NSDictionary* remote = _recordSource;
	NSString* number = [row[@"number"] stringValue];
	if(!number || _busy || self.view.window.attachedSheet) return;
	NSInteger mode = sender.tag;
	if(mode == 0) {
		if(self.canCheckOut && self.canCheckOut()) [self runPullRequest:@[@"checkout", number] local:YES];
		return;
	}
	NSArray* verbs = @[@"Check Out", @"Add Comment", @"Approve", @"Request Changes", @"Merge", @"Close", @"Reopen"];
	NSString* verb = verbs[mode];
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = [NSString stringWithFormat:@"%@ pull request #%@", verb, number];
	alert.informativeText = [NSString stringWithFormat:@"%@ · %@", remote[@"repo"], row[@"title"]];
	NSTextField* body = [NSTextField textFieldWithString:@""];
	body.placeholderString = mode == 2 ? @"Comment (optional)" : @"Comment";
	body.frame = NSMakeRect(0, 0, 360, 24);
	NSPopUpButton* strategy = ReviewPicker(nil, NULL);
	[strategy addItemsWithTitles:@[@"Create a merge commit", @"Squash and merge", @"Rebase and merge"]];
	strategy.frame = NSMakeRect(0, 0, 295, 24);
	if(mode <= 3) alert.accessoryView = body;
	else if(mode == 4) alert.accessoryView = strategy;
	NSString* head = row[@"headRefOid"];
	[alert addButtonWithTitle:verb];
	[alert addButtonWithTitle:@"Cancel"];
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		if(response != NSAlertFirstButtonReturn || ![self.repository isEqual:root] || self->_recordSource != remote) return;
		NSString* message = [body.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		NSArray* args;
		if((mode == 1 || mode == 3) && !message.length) { [self setStatus:@"Enter a comment before submitting."]; return; }
		if(mode == 1) args = @[@"comment", number, @"--body", message];
		else if(mode == 2 || mode == 3) {
			args = @[@"review", number, mode == 2 ? @"--approve" : @"--request-changes"];
			if(message.length) args = [args arrayByAddingObjectsFromArray:@[@"--body", message]];
		} else if(mode == 4) {
			if(!head.length) return;
			args = @[@"merge", number, @[@"--merge", @"--squash", @"--rebase"][strategy.indexOfSelectedItem], @"--match-head-commit", head];
		} else args = @[mode == 5 ? @"close" : @"reopen", number];
		[self runPullRequest:args local:NO];
	}];
}

- (IBAction)createPullRequest:(id)sender
{
	NSString* root = _repository;
	NSDictionary* remote = _recordSource;
	if(!root || !remote || !_create.enabled || self.view.window.attachedSheet) return;
	NSString* head = GitWorkspaceText(GitRepositoryCommand(root, @[@"branch", @"--show-current"]));
	head = [head stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
	[self showCreatePullRequestFromBranch:head remote:remote base:nil];
}

- (void)showCreatePullRequestFromBranch:(NSString*)branch remote:(NSDictionary*)remote base:(NSString*)base
{
	NSString* root = _repository;
	if(_busy || !root || ![remote[@"repo"] length] || !self.view.window || self.view.window.attachedSheet) return;
	NSString* remoteName = remote[@"name"];
	if(!base.length) {
		NSString* tip = GitWorkspaceText(GitRepositoryCommand(root, @[@"symbolic-ref", @"--short", [NSString stringWithFormat:@"refs/remotes/%@/HEAD", remoteName]]));
		tip = [tip stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
		base = [tip hasPrefix:[remoteName stringByAppendingString:@"/"]] ? [tip substringFromIndex:remoteName.length+1] : @"";
	}
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = @"Create Pull Request";
	alert.informativeText = [NSString stringWithFormat:@"%@\nPush the source branch before creating a pull request.", remote[@"repo"]];
	NSMutableArray* fields = [NSMutableArray array];
	NSView* form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 365, 153)];
	NSArray* names = @[@"Base Branch", @"Source Branch", @"Title", @"Description"];
	NSArray* values = @[base, branch ?: @"", @"", @""];
	for(NSUInteger i = 0; i < names.count; ++i) {
		CGFloat y = 123-31*i;
		NSTextField* label = GitLabel(names[i], 12, NSFontWeightRegular);
		label.frame = NSMakeRect(0, y+4, 98, 18);
		NSTextField* field = [NSTextField textFieldWithString:values[i]];
		field.accessibilityLabel = names[i];
		field.frame = NSMakeRect(100, y, 265, 24);
		[form addSubview:label]; [form addSubview:field]; [fields addObject:field];
	}
	NSButton* draft = [NSButton checkboxWithTitle:@"Create as draft" target:nil action:NULL];
	draft.frame = NSMakeRect(97, 0, 268, 22);
	[form addSubview:draft];
	alert.accessoryView = form;
	[alert addButtonWithTitle:@"Create Pull Request"];
	[alert addButtonWithTitle:@"Cancel"];
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		if(response != NSAlertFirstButtonReturn || ![self.repository isEqual:root] || (self->_pullRequests && self->_recordSource != remote)) return;
		NSString* base = [fields[0] stringValue], *head = [fields[1] stringValue], *title = [fields[2] stringValue];
		if(!head.length || !title.length || (base.length && [base isEqual:head])) { [self setStatus:@"Enter a title and a source branch different from the base."]; return; }
		NSMutableArray* args = [NSMutableArray arrayWithArray:@[@"create", @"--head", head, @"--title", title, @"--body", [fields[3] stringValue]]];
		if(base.length) [args addObjectsFromArray:@[@"--base", base]];
		if(draft.state == NSControlStateValueOn) [args addObject:@"--draft"];
		[self runAction:^NSString*{ return GitWorkspaceError(GitWorkspacePullRequestCommand(root, remote, args), @"GitHub could not create the pull request."); } local:NO];
	}];
}
@end
