#import "SourceControlViewController.h"
#import "GitDiffView.h"
#import "GitOperationSheet.h"
#import "GitWorkingCopyActions.h"
#import "GitWorkspaceData.h"
#import <OakAppKit/OakOpenWithMenu.h>
#import <Quartz/Quartz.h>
#import <TMFileReference/TMFileReference.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#if HAVE_OAK_SWIFTUI
#import "OakSwiftUI-Swift.h"
#endif

namespace
{
NSString* TrimCommitText(NSString* string)
{
	return [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

GitPullOptions (^AddFetchOptions(GitOperationSheet* sheet))(void)
{
	NSButton* prune = [sheet addOption:@"Prune Obsolete Remote Branches" detail:@"Removes remote tracking branches that were deleted on the remote repository."];
	NSButton* submodules = [sheet addOption:@"Fetch Submodules" detail:@"Fetches submodules recursively. Each submodule must have working authentication."];
	NSButton* tags = [sheet addOption:@"Fetch All Tags" detail:@"Downloads all tags from the selected remote."];
	return ^GitPullOptions{
		return (GitPullOptions)((prune.state == NSControlStateValueOn ? GitPullPrune : 0) |
			(submodules.state == NSControlStateValueOn ? GitPullFetchSubmodules : 0) | (tags.state == NSControlStateValueOn ? GitPullFetchTags : 0));
	};
}

GitPushOptions (^AddPushOptions(GitOperationSheet* sheet))(void)
{
	NSButton* tags = [sheet addOption:@"Push All Tags" detail:@"Pushes all local tags to the selected remote."];
	NSButton* submodules = [sheet addOption:@"Recurse Submodules" detail:@"Checks that the submodule commits referenced by the project are available on the remote."];
	NSPopUpButton* mode = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	[mode addItemsWithTitles:@[@"Verify Submodules before Push", @"Push Submodule Commits on Demand"]];
	[sheet addField:mode label:@"Submodules:"];
	[sheet setControls:@[mode] enabledWhen:submodules checked:YES];
	return ^GitPushOptions{
		return (GitPushOptions)((tags.state == NSControlStateValueOn ? GitPushTags : 0) |
			(submodules.state == NSControlStateValueOn ? (mode.indexOfSelectedItem == 1 ? GitPushSubmodulesOnDemand : GitPushVerifySubmodules) : 0));
	};
}

NSBox* CommitBox(CGFloat radius, NSColor* color)
{
	NSBox* box = [[NSBox alloc] init];
	box.boxType = NSBoxCustom;
	box.titlePosition = NSNoTitle;
	box.contentViewMargins = NSZeroSize;
	box.cornerRadius = radius;
	box.fillColor = color;
	box.borderColor = NSColor.separatorColor;
	return box;
}

NSColor* StatusBadgeColor(NSString* code)
{
	if([code isEqual:@"M"]) return [NSColor colorWithSRGBRed:0.11 green:0.39 blue:0.72 alpha:1];
	if([code isEqual:@"A"]) return [NSColor colorWithSRGBRed:0.16 green:0.45 blue:0.28 alpha:1];
	if([code isEqual:@"D"]) return [NSColor colorWithSRGBRed:0.68 green:0.22 blue:0.25 alpha:1];
	if([code isEqual:@"U"]) return [NSColor colorWithSRGBRed:0.59 green:0.34 blue:0.09 alpha:1];
	return [NSColor colorWithSRGBRed:0.39 green:0.41 blue:0.44 alpha:1];
}

NSArray<NSDictionary*>* MatchingRows(NSArray<NSDictionary*>* selection, BOOL (^predicate)(NSDictionary*))
{
	return [selection filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary* row, NSDictionary*){ return predicate(row); }]];
}

NSString* FileMenuTitle(NSString* verb, NSArray* rows, NSString* suffix = @"")
{
	return rows.count == 1 ? [NSString stringWithFormat:@"%@ “%@”%@", verb, [rows.firstObject[@"path"] lastPathComponent], suffix]
		: [NSString stringWithFormat:@"%@ %lu Items%@", verb, (unsigned long)rows.count, suffix];
}

BOOL HasGitLFS()
{
	NSArray* locations = [(NSProcessInfo.processInfo.environment[@"PATH"] ?: @"") componentsSeparatedByString:@":"];
	for(NSString* folder in [locations arrayByAddingObjectsFromArray:@[@"/opt/homebrew/bin", @"/usr/local/bin", @"/usr/bin"]])
		if(folder.isAbsolutePath && [NSFileManager.defaultManager isExecutableFileAtPath:[folder stringByAppendingPathComponent:@"git-lfs"]]) return YES;
	return NO;
}
}

@interface SourceControlCanvas : NSView
@end
@implementation SourceControlCanvas
- (BOOL)isFlipped { return YES; }
@end

@interface GitRemoteBranchField : NSComboBox
@property (nonatomic, copy) NSArray<NSString*>* remoteBranches;
@property (nonatomic, copy) NSString* preferredRemote;
@property (nonatomic, copy) NSString* preferredBranch;
@property (nonatomic, copy) NSString* localBranch;
- (IBAction)remoteChanged:(NSPopUpButton*)sender;
@end

@implementation GitRemoteBranchField
- (IBAction)remoteChanged:(NSPopUpButton*)sender
{
	NSString* remote = sender.selectedItem.representedObject;
	NSString* prefix = [remote stringByAppendingString:@"/"];
	[self removeAllItems];
	for(NSString* ref in self.remoteBranches)
		if([ref hasPrefix:prefix]) [self addItemWithObjectValue:[ref substringFromIndex:prefix.length]];
	self.stringValue = ([remote isEqual:self.preferredRemote] ? self.preferredBranch : self.localBranch) ?: @"";
}
@end

@interface CommitSubjectField : NSTextField
@property (nonatomic, copy) void (^showDescription)(void);
@end
@implementation CommitSubjectField
- (BOOL)becomeFirstResponder
{
	BOOL focused = [super becomeFirstResponder];
	if(focused && self.enabled && self.showDescription) self.showDescription();
	return focused;
}
- (void)mouseDown:(NSEvent*)event
{
	if(self.enabled && self.showDescription) self.showDescription();
	[super mouseDown:event];
}
@end

@interface CommitDescriptionHint : NSView
@end
@implementation CommitDescriptionHint
- (BOOL)isFlipped { return YES; }
- (NSView*)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)dirtyRect
{
	NSArray* lines = @[@"Detailed description", @"• Type “/” for commands",
		NSWidth(self.bounds) >= 310 ? @"• Hold Option for Quick Amend outside text fields" : @"• Hold ⌥ for Quick Amend"];
	NSDictionary* attributes = @{
		NSFontAttributeName: [NSFont systemFontOfSize:12],
		NSForegroundColorAttributeName: NSColor.placeholderTextColor,
	};
	CGFloat top = 7, spacing = NSHeight(self.bounds) >= 65 ? 9 : 0;
	for(NSString* line in lines) {
		[line drawAtPoint:NSMakePoint(8, top) withAttributes:attributes];
		top += 14 + spacing;
		spacing = 0;
	}
}
@end

@interface CommitDescriptionScrollView : NSScrollView
@end
@implementation CommitDescriptionScrollView
- (void)layout
{
	[super layout];
	NSTextView* editor = self.documentView;
	NSSize size = self.contentSize;
	if(editor.minSize.height == size.height) return;
	editor.minSize = NSMakeSize(0, size.height);
	if(NSHeight(editor.frame) < size.height) [editor setFrameSize:size];
}
@end

@interface SourceControlHeaderView : NSTableHeaderView
@end
@implementation SourceControlHeaderView
- (void)drawRect:(NSRect)dirtyRect
{
	dirtyRect = NSIntersectionRect(dirtyRect, self.bounds);
	[(self.tableView.backgroundColor ?: NSColor.windowBackgroundColor) setFill];
	NSRectFill(dirtyRect);
	[[NSColor.labelColor colorWithAlphaComponent:0.025] setFill];
	NSRectFillUsingOperation(dirtyRect, NSCompositingOperationSourceOver);
	[NSColor.separatorColor setFill];
	NSRectFillUsingOperation(NSMakeRect(0, NSMaxY(self.bounds)-1, NSWidth(self.bounds), 1), NSCompositingOperationSourceOver);
	NSDictionary* style = @{ NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.labelColor };
	NSSortDescriptor* sort = self.tableView.sortDescriptors.firstObject;
	for(NSUInteger index = 0; index < self.tableView.tableColumns.count; ++index) {
		NSTableColumn* column = self.tableView.tableColumns[index];
		NSRect rect = [self headerRectOfColumn:index];
		if(!NSIntersectsRect(rect, dirtyRect)) continue;
		[column.title drawAtPoint:NSMakePoint(NSMinX(rect)+5, NSMidY(rect)-7) withAttributes:style];
		if(index == 0) NSRectFillUsingOperation(NSMakeRect(NSMaxX(rect)-1, NSMinY(rect)+5, 1, NSHeight(rect)-10), NSCompositingOperationSourceOver);
		if([sort.key isEqual:column.sortDescriptorPrototype.key]) {
			CGFloat x = NSMaxX(rect)-10, y = NSMidY(rect), direction = sort.ascending ? -1 : 1;
			NSBezierPath* arrow = [NSBezierPath bezierPath];
			[arrow moveToPoint:NSMakePoint(x-3, y-direction)];
			[arrow lineToPoint:NSMakePoint(x, y+2*direction)];
			[arrow lineToPoint:NSMakePoint(x+3, y-direction)];
			[NSColor.secondaryLabelColor setStroke];
			[arrow stroke];
		}
	}
}
@end

@interface SourceControlTableView : NSTableView
@property (nonatomic) NSInteger contextRow;
@end

@implementation SourceControlTableView
- (NSMenu*)menuForEvent:(NSEvent*)event
{
	self.contextRow = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
	if(self.contextRow < 0) return nil;
	if(![self.selectedRowIndexes containsIndex:self.contextRow])
		[self selectRowIndexes:[NSIndexSet indexSetWithIndex:self.contextRow] byExtendingSelection:NO];
	return self.menu;
}

- (void)drawGridInClipRect:(NSRect)clipRect
{
	if(!self.numberOfRows) return;
	NSRect rows = NSUnionRect([self rectOfRow:0], [self rectOfRow:self.numberOfRows-1]);
	NSRect clip = NSIntersectionRect(clipRect, rows);
	if(NSIsEmptyRect(clip)) return;
	[NSGraphicsContext saveGraphicsState];
	NSRectClip(clip);
	[super drawGridInClipRect:clip];
	[NSGraphicsContext restoreGraphicsState];
}
@end

@interface SourceControlViewController () <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSMenuItemValidation, NSTextFieldDelegate, NSTextViewDelegate, QLPreviewPanelDataSource>
@end

@implementation SourceControlViewController
{
	SourceControlTableView* _table;
	NSTextField* _branch;
	NSTextField* _message;
	NSTextView* _description;
	NSView* _descriptionEditor;
	NSView* _commitOptions;
	NSLayoutConstraint* _expandedButtonsTop;
	NSLayoutConstraint* _collapsedButtonsTop;
	CommitDescriptionHint* _descriptionHint;
	NSButton* _amend;
	NSButton* _signOff;
	NSButton* _pin;
	NSButton* _commands;
	NSButton* _lastMessage;
	NSButton* _generate;
	NSButton* _generateOptions;
	NSTextField* _identityName;
	NSTextField* _identityEmail;
	NSTextField* _avatar;
	id _modifierMonitor;
	NSString* _amendHead;
	NSTextField* _status;
	NSLayoutConstraint* _emptyStatusHeight;
	NSButton* _bulkStage;
	NSButton* _commit;
	NSButton* _diff;
	NSButton* _actions;
	NSTimer* _timer;
	NSDictionary* _snapshot;
	NSArray<NSDictionary*>* _rows;
	NSArray<NSDictionary*>* _changes;
	NSDictionary<NSString*, NSDictionary*>* _stagedByPath;
	NSArray<NSURL*>* _quickLookURLs;
	NSWindowController* _workingCopyPreview;
#if HAVE_OAK_SWIFTUI
	OakCommandPalette* _branchPalette;
#endif
	OakOpenWithMenuDelegate* _workingCopyOpenWith;
	BOOL _showAssumeUnchanged;
	NSUInteger _generation;
	BOOL _refreshing;
	BOOL _busy;
	BOOL _waitingForIndex;
	BOOL _reloadingRows;
}

- (void)loadView
{
	self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 250, 360)];
	BOOL workspace = self.workspaceLayout;
	_branch = GitLabel(@"No repository", workspace ? 13 : 12, workspace ? NSFontWeightRegular : NSFontWeightMedium);
	_actions = GitIconButton(workspace ? @"slider.horizontal.3" : @"ellipsis.circle", @"Git actions", self, @selector(openActions:));
	_diff = GitIconButton(@"doc.text.magnifyingglass", @"Show selected change details", self, @selector(openDiff:));
	NSStackView* heading = [NSStackView stackViewWithViews:workspace ? @[_branch, _actions] : @[_branch, _diff, _actions]];
	if(workspace) heading.distribution = NSStackViewDistributionFill;
	heading.spacing = 5;
	[_branch setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[_branch setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	for(NSButton* button in @[_diff, _actions])
		[button.widthAnchor constraintEqualToConstant:20].active = YES;

	CommitSubjectField* subject = [[CommitSubjectField alloc] init];
	__weak SourceControlViewController* weakSelf = self;
	subject.showDescription = ^{ [weakSelf setDescriptionExpanded:YES]; };
	_message = subject;
	_message.placeholderString = @"Commit Subject";
	_message.accessibilityLabel = @"Commit Subject";
	_message.font = [NSFont systemFontOfSize:workspace ? 13 : 12];
	_message.bezelStyle = NSTextFieldRoundedBezel;
	_message.delegate = self;
	_message.target = self;
	_message.action = @selector(commit:);
	_descriptionEditor = [self makeDescriptionEditor];
	_descriptionEditor.hidden = YES;
	_commitOptions = [self makeCommitOptions];
	_commitOptions.hidden = YES;
	_bulkStage = [NSButton buttonWithTitle:@"Stage All" target:self action:@selector(toggleBulkStage:)];
	_commit = [NSButton buttonWithTitle:@"Commit" target:self action:@selector(commit:)];
	_commit.toolTip = @"Commit staged changes";
	NSView* buttons = [[NSView alloc] init];
	for(NSButton* button in @[_bulkStage, _commit]) {
		button.controlSize = workspace ? NSControlSizeRegular : NSControlSizeSmall;
		button.bezelStyle = NSBezelStyleRounded;
		button.translatesAutoresizingMaskIntoConstraints = NO;
		[buttons addSubview:button];
	}
	[NSLayoutConstraint activateConstraints:@[
		[_bulkStage.leadingAnchor constraintEqualToAnchor:buttons.leadingAnchor],
		[_bulkStage.topAnchor constraintEqualToAnchor:buttons.topAnchor],
		[_bulkStage.bottomAnchor constraintEqualToAnchor:buttons.bottomAnchor],
		[_commit.trailingAnchor constraintEqualToAnchor:buttons.trailingAnchor],
		[_commit.centerYAnchor constraintEqualToAnchor:buttons.centerYAnchor],
	]];

	_table = [[SourceControlTableView alloc] initWithFrame:NSMakeRect(0, 0, 230, 240)];
	_table.style = NSTableViewStylePlain;
	_table.rowHeight = workspace ? 28 : 27;
	_table.intercellSpacing = NSMakeSize(0, 0);
	_table.gridStyleMask = NSTableViewSolidHorizontalGridLineMask;
	_table.gridColor = NSColor.separatorColor;
	_table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	NSTableColumn* status = [[NSTableColumn alloc] initWithIdentifier:@"status"];
	status.title = @"Status";
	status.minWidth = status.maxWidth = status.width = 68;
	status.resizingMask = NSTableColumnNoResizing;
	status.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"code" ascending:YES];
	NSTableColumn* filename = [[NSTableColumn alloc] initWithIdentifier:@"filename"];
	filename.title = @"Filename";
	filename.minWidth = 32;
	filename.resizingMask = NSTableColumnAutoresizingMask;
	filename.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"path" ascending:YES selector:@selector(localizedStandardCompare:)];
	[_table addTableColumn:status];
	[_table addTableColumn:filename];
	NSRect headerFrame = NSMakeRect(0, 0, NSWidth(_table.frame), workspace ? 25 : 23);
	_table.headerView = workspace ? [[SourceControlHeaderView alloc] initWithFrame:headerFrame] : [[NSTableHeaderView alloc] initWithFrame:headerFrame];
	_table.allowsColumnReordering = NO;
	_table.allowsColumnResizing = NO;
	_table.sortDescriptors = @[filename.sortDescriptorPrototype];
	_table.backgroundColor = _themeBackgroundColor ?: NSColor.clearColor;
	_table.allowsMultipleSelection = YES;
	_table.delegate = self;
	_table.dataSource = self;
	_table.target = self;
	_table.doubleAction = @selector(openDiff:);
	_table.accessibilityLabel = @"Source Control files";
	_table.menu = [[NSMenu alloc] initWithTitle:@"Changes"];
	_table.menu.autoenablesItems = NO;
	_table.menu.delegate = self;
	NSScrollView* scroll = GitScrollView(_table);
	[scroll.heightAnchor constraintGreaterThanOrEqualToConstant:72].active = YES;
	_status = GitLabel(self.directory.length ? @"Loading repository…" : @"Open a folder in a Git repository.", 11, NSFontWeightRegular);
	NSView* footer = workspace ? GitPaneFooter(_status) : nil;
	if(footer) {
		footer.translatesAutoresizingMaskIntoConstraints = NO;
		[self.view addSubview:footer];
		[NSLayoutConstraint activateConstraints:@[
			[footer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
			[footer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
			[footer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
		]];
	} else {
		_status.textColor = NSColor.secondaryLabelColor;
		_status.maximumNumberOfLines = 2;
		_status.lineBreakMode = NSLineBreakByTruncatingTail;
		_emptyStatusHeight = [_status.heightAnchor constraintEqualToConstant:0];
	}
	// A short source control pane can scroll the composer as well as the file list.
	NSScrollView* panelScroll = [[NSScrollView alloc] init];
	panelScroll.drawsBackground = NO;
	panelScroll.hasVerticalScroller = YES;
	panelScroll.scrollerStyle = NSScrollerStyleOverlay;
	panelScroll.autohidesScrollers = YES;
	panelScroll.translatesAutoresizingMaskIntoConstraints = NO;
	NSView* header = workspace ? GitPaneHeader(heading) : nil;
	if(header) {
		header.translatesAutoresizingMaskIntoConstraints = NO;
		[self.view addSubview:header];
		[NSLayoutConstraint activateConstraints:@[
			[header.topAnchor constraintEqualToAnchor:self.view.topAnchor],
			[header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
			[header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		]];
	}
	[self.view addSubview:panelScroll];
	NSView* canvas = [[SourceControlCanvas alloc] initWithFrame:self.view.bounds];
	panelScroll.documentView = canvas;
	canvas.translatesAutoresizingMaskIntoConstraints = NO;
	NSClipView* clip = panelScroll.contentView;
	NSLayoutConstraint* fit = [canvas.heightAnchor constraintEqualToAnchor:clip.heightAnchor];
	fit.priority = NSLayoutPriorityDefaultHigh;
	[NSLayoutConstraint activateConstraints:@[
		[panelScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[panelScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[panelScroll.topAnchor constraintEqualToAnchor:header ? header.bottomAnchor : self.view.topAnchor],
		[panelScroll.bottomAnchor constraintEqualToAnchor:footer ? footer.topAnchor : self.view.bottomAnchor],
		[canvas.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
		[canvas.topAnchor constraintEqualToAnchor:clip.topAnchor],
		[canvas.widthAnchor constraintEqualToAnchor:clip.widthAnchor],
		[canvas.heightAnchor constraintGreaterThanOrEqualToAnchor:clip.heightAnchor], fit,
	]];
	if(workspace) [_message.heightAnchor constraintEqualToConstant:29].active = YES;
	NSArray* items = workspace ? @[_message, _descriptionEditor, _commitOptions, buttons, scroll]
		: @[heading, _message, _descriptionEditor, _commitOptions, buttons, scroll, _status];
	NSView* previous = nil;
	for(NSView* item in items) {
		item.translatesAutoresizingMaskIntoConstraints = NO;
		[canvas addSubview:item];
		CGFloat inset = workspace ? (item == scroll ? 15 : 20) : (item == scroll ? 0 : 9);
		CGFloat gap = item == buttons ? (workspace ? 16 : 11) : item == _status ? 3 : 6;
		if(workspace) {
			if(item == _message) gap = 19;
			else if(item == scroll) gap = 16;
		}
		NSLayoutConstraint* top = [item.topAnchor constraintEqualToAnchor:previous ? previous.bottomAnchor : canvas.topAnchor constant:gap];
		[NSLayoutConstraint activateConstraints:@[
			[item.trailingAnchor constraintEqualToAnchor:canvas.trailingAnchor constant:-inset],
			[item.leadingAnchor constraintEqualToAnchor:canvas.leadingAnchor constant:inset],
		]];
		if(item == buttons) {
			_expandedButtonsTop = top;
			_collapsedButtonsTop = [buttons.topAnchor constraintEqualToAnchor:_message.bottomAnchor constant:gap];
			_collapsedButtonsTop.active = YES;
		} else top.active = YES;
		previous = item;
	}
	[previous.bottomAnchor constraintEqualToAnchor:canvas.bottomAnchor constant:workspace ? 0 : -6].active = YES;
	[self updateControls];
}

- (NSView*)makeDescriptionEditor
{
	NSBox* box = CommitBox(5, [NSColor.labelColor colorWithAlphaComponent:0.07]);
	NSView* content = box.contentView;
	NSScrollView* editorScroll = [[CommitDescriptionScrollView alloc] init];
	editorScroll.drawsBackground = NO;
	editorScroll.hasVerticalScroller = YES;
	editorScroll.autohidesScrollers = YES;
	_description = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 180, 76)];
	_description.autoresizingMask = NSViewWidthSizable;
	_description.verticallyResizable = YES;
	_description.textContainer.widthTracksTextView = YES;
	_description.drawsBackground = NO;
	_description.richText = NO;
	_description.automaticQuoteSubstitutionEnabled = NO;
	_description.automaticDashSubstitutionEnabled = NO;
	_description.automaticTextReplacementEnabled = NO;
	_description.font = [NSFont systemFontOfSize:12];
	_description.textColor = NSColor.textColor;
	_description.insertionPointColor = NSColor.textColor;
	_description.textContainerInset = NSMakeSize(3, 6);
	_description.accessibilityLabel = @"Detailed description";
	_description.accessibilityHelp = @"Type slash for commit message commands. Hold Option outside text fields for Quick Amend.";
	_description.delegate = self;
	editorScroll.documentView = _description;

	_pin = GitIconButton(@"pin", @"Keep draft after committing", self, @selector(togglePin:));
	[_pin setButtonType:NSButtonTypePushOnPushOff];
	_commands = GitIconButton(@"doc.text", @"Commit message commands", self, @selector(openCommands:));
	_lastMessage = GitIconButton(@"arrow.turn.down.left", @"Reuse last commit message", self, @selector(reuseLastMessage:));
	_generate = [NSButton buttonWithTitle:@"Generate" image:[NSImage imageWithSystemSymbolName:@"sparkles" accessibilityDescription:nil] target:self action:@selector(generateMessage:)];
	_generate.imagePosition = NSImageLeft;
	_generate.bezelStyle = NSBezelStyleAccessoryBarAction;
	_generate.bordered = NO;
	_generate.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
	_generate.toolTip = @"Suggest a subject from the staged files";
	_generateOptions = GitIconButton(@"chevron.down", @"Generate options", self, @selector(openGenerateOptions:));
	NSView* space = [[NSView alloc] init];
	NSStackView* tools = [NSStackView stackViewWithViews:@[_pin, _commands, _lastMessage, space, _generate, _generateOptions]];
	tools.spacing = 3;
	tools.edgeInsets = NSEdgeInsetsMake(2, 5, 2, 5);
	[_generate setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
	for(NSButton* icon in @[_pin, _commands, _lastMessage, _generateOptions])
		[icon.widthAnchor constraintEqualToConstant:17].active = YES;
	NSBox* divider = [[NSBox alloc] init];
	divider.boxType = NSBoxSeparator;
	for(NSView* item in @[editorScroll, divider, tools]) {
		item.translatesAutoresizingMaskIntoConstraints = NO;
		[content addSubview:item];
		[item.leadingAnchor constraintEqualToAnchor:content.leadingAnchor].active = YES;
		[item.trailingAnchor constraintEqualToAnchor:content.trailingAnchor].active = YES;
	}
	NSLayoutConstraint* preferred = [editorScroll.heightAnchor constraintEqualToConstant:77];
	preferred.priority = NSLayoutPriorityDefaultLow;
	[NSLayoutConstraint activateConstraints:@[
		[editorScroll.topAnchor constraintEqualToAnchor:content.topAnchor],
		[editorScroll.heightAnchor constraintGreaterThanOrEqualToConstant:47], preferred,
		[divider.topAnchor constraintEqualToAnchor:editorScroll.bottomAnchor],
		[tools.topAnchor constraintEqualToAnchor:divider.bottomAnchor],
		[tools.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
		[tools.heightAnchor constraintGreaterThanOrEqualToConstant:23],
	]];
	_descriptionHint = [[CommitDescriptionHint alloc] init];
	_descriptionHint.translatesAutoresizingMaskIntoConstraints = NO;
	[content addSubview:_descriptionHint positioned:NSWindowAbove relativeTo:editorScroll];
	[NSLayoutConstraint activateConstraints:@[
		[_descriptionHint.leadingAnchor constraintEqualToAnchor:editorScroll.leadingAnchor],
		[_descriptionHint.trailingAnchor constraintEqualToAnchor:editorScroll.trailingAnchor],
		[_descriptionHint.topAnchor constraintEqualToAnchor:editorScroll.topAnchor],
		[_descriptionHint.bottomAnchor constraintEqualToAnchor:editorScroll.bottomAnchor],
	]];
	return box;
}

- (NSView*)makeCommitOptions
{
	_amend = [NSButton checkboxWithTitle:@"Amend" target:self action:@selector(amendChanged:)];
	_signOff = [NSButton checkboxWithTitle:@"Sign Off" target:self action:@selector(signOffChanged:)];
	_amend.toolTip = @"Replace the last commit with the staged changes and message";
	_signOff.toolTip = @"Add a Signed-off-by trailer using your Git identity";
	for(NSButton* button in @[_amend, _signOff]) button.controlSize = NSControlSizeSmall;
	NSStackView* checks = [NSStackView stackViewWithViews:@[_amend, _signOff]];
	checks.orientation = NSUserInterfaceLayoutOrientationVertical;
	checks.alignment = NSLayoutAttributeLeading;
	checks.spacing = 4;
	_identityName = GitLabel(@"", 11, NSFontWeightMedium);
	_identityEmail = GitLabel(@"", 11, NSFontWeightRegular);
	for(NSTextField* label in @[_identityName, _identityEmail]) {
		label.alignment = NSTextAlignmentRight;
		label.textColor = NSColor.secondaryLabelColor;
		[label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	}
	NSStackView* identity = [NSStackView stackViewWithViews:@[_identityName, _identityEmail]];
	identity.orientation = NSUserInterfaceLayoutOrientationVertical;
	identity.alignment = NSLayoutAttributeTrailing;
	identity.spacing = 2;
	NSBox* avatar = CommitBox(15, NSColor.quaternaryLabelColor);
	[avatar.widthAnchor constraintEqualToConstant:30].active = YES;
	[avatar.heightAnchor constraintEqualToConstant:30].active = YES;
	_avatar = GitLabel(@"–", 13, NSFontWeightMedium);
	_avatar.textColor = NSColor.secondaryLabelColor;
	_avatar.alignment = NSTextAlignmentCenter;
	_avatar.translatesAutoresizingMaskIntoConstraints = NO;
	[avatar.contentView addSubview:_avatar];
	[NSLayoutConstraint activateConstraints:@[
		[_avatar.leadingAnchor constraintEqualToAnchor:avatar.contentView.leadingAnchor],
		[_avatar.trailingAnchor constraintEqualToAnchor:avatar.contentView.trailingAnchor],
		[_avatar.centerYAnchor constraintEqualToAnchor:avatar.contentView.centerYAnchor],
	]];
	NSView* space = [[NSView alloc] init];
	NSStackView* line = [NSStackView stackViewWithViews:@[checks, space, identity, avatar]];
	line.spacing = 6;
	return line;
}

- (void)setThemeBackgroundColor:(NSColor*)color
{
	_themeBackgroundColor = color;
	_table.backgroundColor = color ?: NSColor.clearColor;
}

- (void)setDirectory:(NSString*)directory
{
	if(_directory == directory || [_directory isEqual:directory]) return;
#if HAVE_OAK_SWIFTUI
	[_branchPalette dismiss];
#endif
	_directory = [directory copy];
	++_generation;
	_refreshing = NO;
	_waitingForIndex = NO;
	_snapshot = nil;
	_changes = _rows = @[];
	_stagedByPath = @{};
	[_table reloadData];
	if(self.previewChange) self.previewChange(nil, nil, nil);
	_branch.stringValue = @"Source Control";
	_branch.toolTip = directory;
	_message.stringValue = @"";
	[self setDescriptionText:@""];
	[self setDescriptionExpanded:NO];
	_amend.state = _signOff.state = _pin.state = NSControlStateValueOff;
	[self togglePin:nil];
	_amendHead = nil;
	[self updateIdentity];
	_status.stringValue = directory.length ? @"Loading repository…" : @"Open a folder in a Git repository.";
	[self updateControls];
	[self refresh:nil];
}

- (void)setPanelVisible:(BOOL)visible
{
	if(_panelVisible == visible) return;
	_panelVisible = visible;
	if(visible) {
		[self refresh:nil];
		__weak SourceControlViewController* weakSelf = self;
		_timer = [NSTimer scheduledTimerWithTimeInterval:4 repeats:YES block:^(NSTimer*){
			if(NSApp.isActive && weakSelf.view.window.isVisible) [weakSelf refresh:nil];
		}];
		_modifierMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged | NSEventMaskLeftMouseUp | NSEventMaskKeyUp handler:^NSEvent*(NSEvent* event){
			SourceControlViewController* controller = weakSelf;
			if(event.window == controller.viewIfLoaded.window) [controller updateControls];
			return event;
		}];
	} else {
#if HAVE_OAK_SWIFTUI
		[_branchPalette dismiss];
#endif
		[_timer invalidate];
		_timer = nil;
		if(_modifierMonitor) [NSEvent removeMonitor:_modifierMonitor];
		_modifierMonitor = nil;
		[self updateControls];
	}
}

- (void)dealloc
{
	[_timer invalidate];
	if(_modifierMonitor) [NSEvent removeMonitor:_modifierMonitor];
}
- (void)focusChanges { [self.view.window makeFirstResponder:_table]; }

- (IBAction)refresh:(id)sender
{
	if(!self.panelVisible || _refreshing || _busy || !self.directory.length) return;
	_refreshing = YES;
	NSUInteger generation = ++_generation;
	NSString* directory = self.directory;
	BOOL showAssumeUnchanged = _showAssumeUnchanged;
	NSDictionary* buffers = self.bufferProvider ? self.bufferProvider() : @{};
	__weak SourceControlViewController* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDictionary* snapshot = ProjectChangesSnapshot(directory, buffers, YES);
		if(NSString* root = snapshot[@"root"]) {
			NSMutableDictionary* withContext = [snapshot mutableCopy];
			withContext[@"commitContext"] = GitRepositoryCommitContext(root, snapshot[@"head"]);
			withContext[@"toolbarContext"] = GitRepositoryToolbarContext(root, snapshot[@"branch"]);
			withContext[@"hasGitLFS"] = @(HasGitLFS());
			withContext[@"diffTool"] = GitWorkspaceConfig(root, @"diff.tool") ?: @"";
			if(showAssumeUnchanged) withContext[@"assumedPaths"] = GitWorkingCopyAssumedPaths(root);
			if([withContext[@"toolbarContext"] objectForKey:@"integration"]) {
				withContext[@"mergeTool"] = GitWorkspaceConfig(root, @"merge.tool") ?: @"";
				NSMutableSet* versions = [NSMutableSet set];
				NSString* entries = GitWorkspaceText(GitRepositoryCommand(root, @[@"ls-files", @"--resolve-undo", @"-z"]));
				for(NSString* line in [entries componentsSeparatedByString:[NSString stringWithFormat:@"%C", (unichar)0]]) {
					NSRange tab = [line rangeOfString:@"\t"];
					if(tab.location != NSNotFound) [versions addObject:[line substringFromIndex:NSMaxRange(tab)]];
				}
				withContext[@"conflictVersions"] = versions;
			}
			snapshot = withContext;
		}
		NSArray* changes = GitRepositoryChanges(snapshot);
		dispatch_async(dispatch_get_main_queue(), ^{
			SourceControlViewController* controller = weakSelf;
			if(!controller || controller->_generation != generation) return;
			controller->_refreshing = NO;
			[controller renderSnapshot:snapshot changes:changes];
		});
	});
}

- (void)renderSnapshot:(NSDictionary*)snapshot changes:(NSArray*)changes
{
	_waitingForIndex = NO;
	if(_amendHead && (![_amendHead isEqual:snapshot[@"head"]] || ![_snapshot[@"branch"] isEqual:snapshot[@"branch"]])) {
		_amendHead = nil;
		_amend.state = NSControlStateValueOff;
	}
	BOOL extraPathsChanged = ![(_snapshot[@"assumedPaths"] ?: @[]) isEqual:(snapshot[@"assumedPaths"] ?: @[])]
		|| ![(_snapshot[@"conflictVersions"] ?: NSSet.set) isEqual:(snapshot[@"conflictVersions"] ?: NSSet.set)];
	_snapshot = snapshot;
	[self updateIdentity];
	NSString* tracking = snapshot[@"tracking"];
	NSString* root = snapshot[@"root"];
	NSString* branch = snapshot[@"branch"] ?: @"No repository";
	NSString* upstream = [tracking componentsSeparatedByString:@" ["].firstObject;
	if(self.workspaceLayout && upstream.length) {
		NSMutableAttributedString* path = [[NSMutableAttributedString alloc] initWithString:branch attributes:@{ NSFontAttributeName: _branch.font, NSForegroundColorAttributeName: NSColor.secondaryLabelColor }];
		[path appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@" › %@", upstream]
			attributes:@{ NSFontAttributeName: _branch.font, NSForegroundColorAttributeName: NSColor.tertiaryLabelColor }]];
		_branch.attributedStringValue = path;
	} else _branch.stringValue = branch;
	_branch.toolTip = tracking.length ? [NSString stringWithFormat:@"%@\n%@ → %@", root, branch, tracking] : root;
	_status.stringValue = snapshot[@"error"] ?: (changes.count ? (tracking.length ? tracking : @"") : @"Working tree is clean.");
	_status.toolTip = _status.stringValue;
	if(extraPathsChanged || ![_changes isEqual:changes]) {
		_changes = changes;
		[self reloadRows];
	}
	[self updateControls];
	if(self.didRefresh) {
		NSMutableSet* paths = [NSMutableSet set];
		for(NSDictionary* change in changes) [paths addObject:change[@"path"]];
		self.didRefresh(snapshot, paths.count);
	}
	[self previewSelection];
}

- (void)updateIdentity
{
	NSDictionary* identity = _snapshot[@"commitContext"];
	NSString* name = identity[@"name"] ?: @"";
	NSString* email = identity[@"email"] ?: @"";
	_identityName.stringValue = name.length ? name : _snapshot[@"root"] ? @"Git identity not set" : @"";
	_identityEmail.stringValue = email;
	_identityName.toolTip = name;
	_identityEmail.toolTip = email;
	_avatar.stringValue = name.length ? [[name substringWithRange:[name rangeOfComposedCharacterSequenceAtIndex:0]] uppercaseString] : @"–";
	_avatar.superview.superview.hidden = !_snapshot[@"root"];
	_avatar.superview.superview.toolTip = name.length ? [NSString stringWithFormat:@"Git committer: %@ <%@>", name, email] : @"Set user.name and user.email in Git.";
	if(!email.length) _signOff.state = NSControlStateValueOff;
}

- (void)reloadRows
{
	NSArray* selected = [[self selectedChanges] valueForKey:@"path"];
	NSMutableDictionary* staged = [NSMutableDictionary dictionary];
	NSMutableDictionary* byPath = [NSMutableDictionary dictionary];
	for(NSDictionary* change in _changes) {
		NSString* path = change[@"path"];
		if([change[@"group"] unsignedIntegerValue] == GitChangeStaged) {
			staged[path] = change;
			if(!byPath[path]) byPath[path] = change;
		} else byPath[path] = change;
	}
	for(NSString* path in _snapshot[@"assumedPaths"]) {
		NSString* absolute = [_snapshot[@"root"] stringByAppendingPathComponent:path];
		NSMutableDictionary* row = [byPath[path] mutableCopy] ?: [@{ @"path": path, @"absolutePath": absolute, @"group": @(GitChangeWorking), @"code": @"H", @"status": @"Assume Unchanged" } mutableCopy];
		row[@"assumed"] = @YES;
		row[@"writable"] = @NO;
		byPath[path] = row;
	}
	for(NSString* path in _snapshot[@"conflictVersions"]) if(!byPath[path]) {
		NSString* absolute = [_snapshot[@"root"] stringByAppendingPathComponent:path];
		byPath[path] = @{ @"path": path, @"absolutePath": absolute, @"group": @(GitChangeWorking), @"code": @"✓", @"status": @"Resolved conflict", @"resolved": @YES, @"writable": @NO };
	}
	_stagedByPath = staged;
	NSArray* descriptors = [_table.sortDescriptors arrayByAddingObject:[NSSortDescriptor sortDescriptorWithKey:@"path" ascending:YES selector:@selector(localizedStandardCompare:)]];
	NSArray* rows = byPath.allValues;
	if(_searchString.length) rows = [rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary* row, NSDictionary*){
		return [row[@"path"] localizedStandardContainsString:_searchString];
	}]];
	_rows = [rows sortedArrayUsingDescriptors:descriptors];
	NSMutableIndexSet* selection = [NSMutableIndexSet indexSet];
	[_rows enumerateObjectsUsingBlock:^(NSDictionary* row, NSUInteger index, BOOL*){
		if([selected containsObject:row[@"path"]]) [selection addIndex:index];
	}];
	_reloadingRows = YES;
	[_table reloadData];
	[_table selectRowIndexes:selection byExtendingSelection:NO];
	_reloadingRows = NO;
}

- (void)setSearchString:(NSString*)searchString
{
	if(_searchString == searchString || [_searchString isEqual:searchString]) return;
	_searchString = [searchString copy];
	[self reloadRows];
	[self updateControls];
	[self previewSelection];
}

- (NSArray<NSDictionary*>*)selectedChanges
{
	NSMutableArray* result = [NSMutableArray array];
	[_table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL*){
		if(row < _rows.count) [result addObject:_rows[row]];
	}];
	return result;
}

- (NSUInteger)workingCopySelectionCount { return _table.numberOfSelectedRows; }

- (void)updateControls
{
	_emptyStatusHeight.active = _status.stringValue.length == 0;
	BOOL staged = NO;
	BOOL conflicts = NO;
	BOOL canStage = NO;
	for(NSDictionary* change in _changes) {
		NSUInteger group = [change[@"group"] unsignedIntegerValue];
		staged |= group == GitChangeStaged;
		conflicts |= group == GitChangeConflict;
		canStage |= group == GitChangeWorking && [change[@"writable"] boolValue];
	}
	_message.enabled = _snapshot[@"root"] != nil && !_busy;
	_description.editable = _message.enabled;
	_amend.enabled = _message.enabled && !conflicts && [_snapshot[@"head"] length];
	_signOff.enabled = _message.enabled && [_snapshot[@"commitContext"][@"email"] length];
	_pin.enabled = _message.enabled;
	_commands.enabled = _message.enabled;
	BOOL hasSubject = TrimCommitText(_message.stringValue).length != 0;
	BOOL hasDescription = TrimCommitText(_description.string).length != 0;
	_lastMessage.enabled = _message.enabled && [_snapshot[@"commitContext"][@"lastMessage"] length] && !hasSubject && !hasDescription;
	_generate.enabled = _message.enabled && staged && !hasSubject;
	_generateOptions.enabled = _message.enabled && staged && (!hasSubject || !hasDescription);
	BOOL canUnstage = !canStage && staged;
	_bulkStage.title = canUnstage ? @"Unstage All" : @"Stage All";
	_bulkStage.toolTip = canUnstage ? @"Unstage all changes and keep them in the working tree" : @"Stage all saved changes";
	_bulkStage.tag = canUnstage ? GitRepositoryUnstage : GitRepositoryStage;
	_bulkStage.enabled = _message.enabled && !_waitingForIndex && (canStage || canUnstage);
	BOOL amending = _amend.enabled && (_amendHead != nil || [self quickAmend]);
	_commit.title = amending ? @"Amend" : @"Commit";
	_commit.toolTip = amending ? @"Amend the last commit using the staged changes" : @"Commit staged changes";
	_commit.enabled = _message.enabled && !conflicts && (amending ? (hasSubject || (!hasDescription && (staged || [self shouldSignOff]))) : staged && hasSubject);
	_diff.enabled = !_busy && [self selectedChanges].count == 1;
	if(self.controlsDidChange) self.controlsDidChange();
}

- (BOOL)quickAmend
{
	NSWindow* window = self.viewIfLoaded.window;
	return self.panelVisible && window.isKeyWindow && (NSEvent.modifierFlags & NSEventModifierFlagOption) && ![window.firstResponder isKindOfClass:NSTextView.class];
}

- (BOOL)shouldSignOff { return _signOff.enabled && _signOff.state == NSControlStateValueOn; }

- (IBAction)amendChanged:(id)sender
{
	_amendHead = _amend.state == NSControlStateValueOn ? _snapshot[@"head"] : nil;
	[self updateControls];
}

- (IBAction)signOffChanged:(id)sender { [self updateControls]; }

- (IBAction)togglePin:(id)sender
{
	BOOL pinned = _pin.state == NSControlStateValueOn;
	_pin.image = [NSImage imageWithSystemSymbolName:pinned ? @"pin.fill" : @"pin" accessibilityDescription:nil];
	_pin.toolTip = pinned ? @"Clear draft after committing" : @"Keep draft after committing";
	_pin.accessibilityLabel = _pin.toolTip;
}

- (void)setDescriptionText:(NSString*)text
{
	_description.string = text;
	_descriptionHint.hidden = text.length != 0;
}

- (void)setDescriptionExpanded:(BOOL)expanded
{
	if(!_descriptionEditor || _descriptionEditor.hidden == !expanded) return;
	NSLayoutConstraint* deactivate = expanded ? _collapsedButtonsTop : _expandedButtonsTop;
	NSLayoutConstraint* activate = expanded ? _expandedButtonsTop : _collapsedButtonsTop;
	deactivate.active = NO;
	activate.active = YES;
	_descriptionEditor.hidden = !expanded;
	_commitOptions.hidden = !expanded;
}

- (void)textDidChange:(NSNotification*)notification
{
	_descriptionHint.hidden = _description.string.length != 0;
	[self updateControls];
	if([_description.string isEqual:@"/"] && !_description.hasMarkedText)
		[self openCommands:_commands];
}

- (NSMenuItem*)addCommand:(NSString*)title action:(SEL)action enabled:(BOOL)enabled toMenu:(NSMenu*)menu
{
	NSMenuItem* item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
	item.target = self;
	item.enabled = enabled;
	return item;
}

- (BOOL)canReuseLastMessage
{
	NSString* text = TrimCommitText(_description.string);
	return [_snapshot[@"commitContext"][@"lastMessage"] length] && !TrimCommitText(_message.stringValue).length && (!text.length || [text isEqual:@"/"]);
}

- (IBAction)openCommands:(NSView*)sender
{
	if(!_commands.enabled || !sender.window) return;
	NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Commit Message"];
	menu.autoenablesItems = NO;
	[self addCommand:@"Insert Description Template" action:@selector(insertDescriptionTemplate:) enabled:YES toMenu:menu];
	if([_snapshot[@"commitContext"][@"template"] length]) [self addCommand:@"Insert Repository Commit Template" action:@selector(insertRepositoryTemplate:) enabled:YES toMenu:menu];
	if([_snapshot[@"commitContext"][@"prompt"] length]) [self addCommand:@"Show Commit Message Prompt" action:@selector(showCommitPrompt:) enabled:YES toMenu:menu];
	[self addCommand:@"Reuse Last Commit Message" action:@selector(reuseLastMessage:) enabled:[self canReuseLastMessage] toMenu:menu];
	[self addCommand:@"Generate Subject" action:@selector(generateMessage:) enabled:_generate.enabled toMenu:menu];
	[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds)+3) inView:sender];
}

- (IBAction)insertRepositoryTemplate:(id)sender
{
	NSString* text = _snapshot[@"commitContext"][@"template"];
	if(!text.length) return;
	if(!TrimCommitText(_message.stringValue).length) {
		NSRange newline = [text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet];
		_message.stringValue = newline.location == NSNotFound ? text : [text substringToIndex:newline.location];
		text = newline.location == NSNotFound ? @"" : [text substringFromIndex:NSMaxRange(newline)];
	}
	NSString* previous = TrimCommitText(_description.string);
	if(previous.length && ![previous isEqual:@"/"]) text = [previous stringByAppendingFormat:@"\n\n%@", text];
	[self setDescriptionText:text];
	[self updateControls];
}

- (IBAction)showCommitPrompt:(id)sender
{
	NSString* prompt = _snapshot[@"commitContext"][@"prompt"];
	if(!prompt.length || self.view.window.attachedSheet) return;
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = @"Commit Message Prompt";
	alert.informativeText = prompt;
	[alert beginSheetModalForWindow:self.view.window completionHandler:nil];
}

- (IBAction)insertDescriptionTemplate:(id)sender
{
	NSString* templateText = @"Why\n\nTesting\n";
	NSString* existing = TrimCommitText(_description.string);
	if(existing.length && ![existing isEqual:@"/"]) templateText = [NSString stringWithFormat:@"%@\n\n%@", existing, templateText];
	[self setDescriptionText:templateText];
	[self.view.window makeFirstResponder:_description];
	_description.selectedRange = NSMakeRange(templateText.length, 0);
	[self updateControls];
}

- (IBAction)reuseLastMessage:(id)sender
{
	if(_busy || ![self canReuseLastMessage]) return;
	NSString* lastMessage = _snapshot[@"commitContext"][@"lastMessage"];
	NSRange newline = [lastMessage rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet];
	_message.stringValue = newline.location == NSNotFound ? lastMessage : [lastMessage substringToIndex:newline.location];
	[self setDescriptionText:newline.location == NSNotFound ? @"" : TrimCommitText([lastMessage substringFromIndex:NSMaxRange(newline)])];
	[self updateControls];
}

- (IBAction)openGenerateOptions:(NSView*)sender
{
	NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Generate from Staged Files"];
	menu.autoenablesItems = NO;
	[self addCommand:@"Generate Subject" action:@selector(generateMessage:) enabled:_generate.enabled toMenu:menu];
	[self addCommand:@"Generate Description" action:@selector(generateMessage:) enabled:!TrimCommitText(_description.string).length toMenu:menu].tag = 1;
	[self addCommand:@"Generate Subject and Description" action:@selector(generateMessage:) enabled:_generate.enabled && !TrimCommitText(_description.string).length toMenu:menu].tag = 2;
	[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds)+3) inView:sender];
}

- (IBAction)generateMessage:(id)sender
{
	if(_busy || !_stagedByPath.count) return;
	NSInteger mode = [sender isKindOfClass:NSMenuItem.class] ? [sender tag] : 0;
	NSArray<NSString*>* paths = [_stagedByPath.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
	if(mode != 1 && !TrimCommitText(_message.stringValue).length) {
		NSString* firstCode = _stagedByPath[paths.firstObject][@"code"];
		BOOL sameStatus = YES;
		for(NSString* path in paths) sameStatus &= [firstCode isEqual:_stagedByPath[path][@"code"]];
		NSString* verb = sameStatus && [firstCode isEqual:@"A"] ? @"Add" : sameStatus && [firstCode isEqual:@"D"] ? @"Remove" : @"Update";
		NSString* scope = paths.count == 1 ? [[paths.firstObject.lastPathComponent componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "]
			: [NSString stringWithFormat:@"%lu files", (unsigned long)paths.count];
		_message.stringValue = [NSString stringWithFormat:@"%@ %@", verb, scope];
	}
	if([_description.string isEqual:@"/"]) [self setDescriptionText:@""];
	if(mode != 0 && !TrimCommitText(_description.string).length) {
		NSMutableArray* lines = [NSMutableArray arrayWithObject:@"Staged changes:"];
		for(NSUInteger index = 0; index < MIN(paths.count, 8); ++index)
			[lines addObject:[NSString stringWithFormat:@"- %@", [[paths[index] componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "]]];
		if(paths.count > 8) [lines addObject:[NSString stringWithFormat:@"- %lu more files", (unsigned long)paths.count-8]];
		[self setDescriptionText:[lines componentsJoinedByString:@"\n"]];
	}
	[self updateControls];
}

- (void)controlTextDidChange:(NSNotification*)notification { [self updateControls]; }
- (void)previewSelection
{
	if(!self.previewChange || _busy) return;
	NSArray* selection = [self selectedChanges];
	NSDictionary* item = selection.count == 1 ? selection.firstObject : nil;
	self.previewChange(item, _snapshot, item && self.bufferProvider ? self.bufferProvider() : nil);
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification
{
	if(_reloadingRows) return;
	[self updateControls];
	[self previewSelection];
}
- (void)tableView:(NSTableView*)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor*>*)oldDescriptors
{
	[self reloadRows];
	_table.headerView.needsDisplay = YES;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView { return _rows.count; }

static NSImageView* WorkingCopyFileIcon(NSString* path, BOOL isDirectory)
{
	NSString* extension = path.pathExtension.lowercaseString;
	UTType* type = extension.length ? [UTType typeWithFilenameExtension:extension] : nil;
	NSString* symbol = @"doc.fill";
	NSColor* color = NSColor.secondaryLabelColor;
	if(isDirectory) { symbol = @"folder.fill"; color = NSColor.systemBlueColor; }
	else if([type conformsToType:UTTypePDF]) { symbol = @"doc.richtext.fill"; color = NSColor.systemRedColor; }
	else if([type conformsToType:UTTypeImage]) { symbol = @"photo.fill"; color = NSColor.systemPurpleColor; }
	else if([type conformsToType:UTTypeSourceCode]) { symbol = @"doc.text.fill"; color = NSColor.systemBlueColor; }
	else if([type conformsToType:UTTypeArchive]) { symbol = @"doc.zipper"; color = NSColor.systemOrangeColor; }
	else if([type conformsToType:UTTypeText] || [extension isEqual:@"md"]) { symbol = @"doc.text.fill"; color = NSColor.labelColor; }
	NSImage* image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] ?: [NSImage imageWithSystemSymbolName:@"doc" accessibilityDescription:nil];
	NSImageView* icon = image ? [NSImageView imageViewWithImage:image] : [[NSImageView alloc] init];
	icon.contentTintColor = color;
	return icon;
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column row:(NSInteger)index
{
	NSDictionary* row = _rows[index];
	NSString* path = row[@"path"];
	BOOL isDirectory = [row[@"directory"] boolValue];
	BOOL staged = [row[@"group"] unsignedIntegerValue] == GitChangeStaged;
	BOOL partiallyStaged = !staged && _stagedByPath[path] != nil;
	BOOL unsaved = [row[@"unsaved"] boolValue] && !staged;
	if([column.identifier isEqual:@"status"]) {
		NSView* cell = [[NSView alloc] init];
		NSString* code = row[@"code"];
		NSString* actionLabel = staged ? @"Unstage" : unsaved ? @"Save editor changes before staging"
			: partiallyStaged ? @"Stage remaining changes" : isDirectory ? @"Stage folder" : @"Stage file";
		NSButton* action = [NSButton checkboxWithTitle:@"" target:self action:@selector(stageOrUnstage:)];
		action.controlSize = NSControlSizeSmall;
		action.allowsMixedState = partiallyStaged;
		action.state = staged ? NSControlStateValueOn : partiallyStaged ? NSControlStateValueMixed : NSControlStateValueOff;
		action.enabled = !_busy && [row[@"writable"] boolValue];
		action.toolTip = actionLabel;
		action.accessibilityLabel = [NSString stringWithFormat:@"%@: %@", actionLabel, path];
		NSBox* badge = [[NSBox alloc] init];
		badge.boxType = NSBoxCustom;
		badge.borderWidth = 0;
		badge.titlePosition = NSNoTitle;
		badge.cornerRadius = 3;
		badge.fillColor = StatusBadgeColor(code);
		badge.contentViewMargins = NSZeroSize;
		if(unsaved) badge.toolTip = @"Unsaved editor changes";
		NSTextField* label = GitLabel(unsaved ? [code stringByAppendingString:@"•"] : code, 11, NSFontWeightSemibold);
		label.textColor = NSColor.whiteColor;
		label.alignment = NSTextAlignmentCenter;
		for(NSView* view in @[action, badge, label]) view.translatesAutoresizingMaskIntoConstraints = NO;
		[cell addSubview:action];
		[cell addSubview:badge];
		[badge.contentView addSubview:label];
		[NSLayoutConstraint activateConstraints:@[
			[action.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:9],
			[action.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
			[badge.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6],
			[badge.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
			[badge.widthAnchor constraintEqualToConstant:unsaved ? 21 : 17],
			[badge.heightAnchor constraintEqualToConstant:17],
			[label.leadingAnchor constraintEqualToAnchor:badge.contentView.leadingAnchor],
			[label.trailingAnchor constraintEqualToAnchor:badge.contentView.trailingAnchor],
			[label.centerYAnchor constraintEqualToAnchor:badge.contentView.centerYAnchor],
		]];
		return cell;
	}
	NSTextField* filename = GitLabel(path, 12, NSFontWeightRegular);
	if(self.workspaceLayout) filename.lineBreakMode = NSLineBreakByTruncatingHead;
	NSString* absolutePath = row[@"absolutePath"];
	NSImageView* icon;
	if(self.workspaceLayout) icon = WorkingCopyFileIcon(path, isDirectory);
	else {
		NSImage* image = nil;
		if([NSFileManager.defaultManager fileExistsAtPath:absolutePath])
			image = [TMFileReference imageForURL:[NSURL fileURLWithPath:absolutePath isDirectory:isDirectory] size:NSMakeSize(16, 16)];
		if(!image) {
			NSString* extension = path.pathExtension;
			UTType* type = isDirectory ? UTTypeFolder : extension.length ? [UTType typeWithFilenameExtension:extension] : nil;
			image = [NSWorkspace.sharedWorkspace iconForContentType:type ?: UTTypeData];
		}
		icon = [NSImageView imageViewWithImage:image];
	}
	icon.imageScaling = NSImageScaleProportionallyDown;
	NSStackView* line = [NSStackView stackViewWithViews:@[icon, filename]];
	line.spacing = 6;
	line.edgeInsets = NSEdgeInsetsMake(1, 7, 1, 6);
	[filename setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[filename setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[NSLayoutConstraint activateConstraints:@[
		[icon.widthAnchor constraintEqualToConstant:16], [icon.heightAnchor constraintEqualToConstant:16],
	]];
	line.toolTip = unsaved ? [path stringByAppendingString:@" (unsaved editor changes)"] : isDirectory ? [path stringByAppendingString:@" (untracked folder)"] : path;
	return line;
}

- (IBAction)openDiff:(id)sender
{
	NSInteger row = sender == _table ? _table.clickedRow : _table.selectedRow;
	NSDictionary* change = row >= 0 && row < _rows.count ? _rows[row] : nil;
	[self showChangeDiff:change];
}

- (void)showChangeDiff:(NSDictionary*)change
{
	if(!_busy && change && self.showDiff) self.showDiff(change, _snapshot, self.bufferProvider ? self.bufferProvider() : @{});
}

- (void)menuNeedsUpdate:(NSMenu*)menu
{
	[menu removeAllItems];
	NSInteger index = _table.contextRow;
	if(menu != _table.menu || index < 0 || index >= _rows.count) return;
	[self populateWorkingCopyMenu:menu forChanges:[_table.selectedRowIndexes containsIndex:index] ? [self selectedChanges] : @[_rows[index]]];
}

- (void)addWorkingCopyCommand:(NSString*)title enabled:(BOOL)enabled menu:(NSMenu*)menu action:(void(^)(void))action
{
	NSMenuItem* item = [menu addItemWithTitle:title action:@selector(runWorkingCopyCommand:) keyEquivalent:@""];
	item.target = self;
	item.enabled = enabled;
	item.representedObject = [action copy];
}

- (NSMenu*)workingCopySubmenu:(NSString*)title enabled:(BOOL)enabled parent:(NSMenu*)menu
{
	NSMenuItem* item = [menu addItemWithTitle:title action:NULL keyEquivalent:@""];
	item.submenu = [[NSMenu alloc] initWithTitle:title];
	item.submenu.autoenablesItems = NO;
	item.enabled = enabled;
	return item.submenu;
}

- (IBAction)runWorkingCopyCommand:(NSMenuItem*)sender
{
	void (^action)(void) = sender.representedObject;
	if(sender.enabled && action && self.panelVisible) action();
}

- (void)populateWorkingCopyMenu:(NSMenu*)menu forChanges:(NSArray<NSDictionary*>*)selection
{
	NSString* root = _snapshot[@"root"];
	if(!selection.count || !root.length) return;
	menu.autoenablesItems = NO;
	BOOL single = selection.count == 1;
	BOOL writable = !_busy && !_waitingForIndex;
	BOOL history = [_snapshot[@"head"] length] != 0;
	NSDictionary* first = selection.firstObject;
	NSString* path = first[@"path"];
	NSArray* openRows = MatchingRows(selection, ^BOOL(NSDictionary* row){ return GitWorkingCopyPathExists(row[@"absolutePath"]); });
	NSArray* saved = MatchingRows(selection, ^BOOL(NSDictionary* row){ return ![row[@"unsaved"] boolValue]; });
	NSArray* tracked = MatchingRows(saved, ^BOOL(NSDictionary* row){ return GitWorkingCopyIsTracked(row); });
	NSArray* conflict = MatchingRows(tracked, ^BOOL(NSDictionary* row){ return [row[@"group"] unsignedIntegerValue] == GitChangeConflict; });
	NSArray* stage = MatchingRows(saved, ^BOOL(NSDictionary* row){ return [row[@"group"] unsignedIntegerValue] == GitChangeWorking && [row[@"writable"] boolValue]; });
	NSArray* discard = MatchingRows(tracked, ^BOOL(NSDictionary* row){
		NSUInteger group = [row[@"group"] unsignedIntegerValue];
		return history && group != GitChangeConflict && ![row[@"untracked"] boolValue] && ![row[@"assumed"] boolValue] && ![row[@"resolved"] boolValue];
	});
	NSArray* ignore = MatchingRows(saved, ^BOOL(NSDictionary* row){ return !GitWorkingCopyIsTracked(row); });
	NSArray* canUntrack = MatchingRows(tracked, ^BOOL(NSDictionary* row){ return [row[@"group"] unsignedIntegerValue] != GitChangeConflict && ![row[@"diskFlags"] hasPrefix:@"D"]; });
	NSArray* restorable = MatchingRows(tracked, ^BOOL(NSDictionary* row){ return [conflict containsObject:row] || [_snapshot[@"conflictVersions"] containsObject:row[@"path"]]; });
	NSArray* stageableIndex = MatchingRows(canUntrack, ^BOOL(NSDictionary* row){ return ![row[@"directory"] boolValue]; });
	NSArray* toMark = MatchingRows(stageableIndex, ^BOOL(NSDictionary* row){ return ![row[@"assumed"] boolValue]; });
	NSArray* toUnmark = MatchingRows(stageableIndex, ^BOOL(NSDictionary* row){ return [row[@"assumed"] boolValue]; });
	NSMutableArray* unstage = [NSMutableArray array];
	NSMutableArray<NSURL*>* urls = [NSMutableArray array];
	for(NSDictionary* row in selection) if(NSDictionary* staged = _stagedByPath[row[@"path"]]) [unstage addObject:staged];
	for(NSDictionary* row in openRows) [urls addObject:[NSURL fileURLWithPath:row[@"absolutePath"] isDirectory:[row[@"directory"] boolValue]]];
	NSArray* trash = MatchingRows(openRows, ^BOOL(NSDictionary* row){ return ![row[@"unsaved"] boolValue]; });
	BOOL file = single && history && GitWorkingCopyIsTracked(first) && ![first[@"directory"] boolValue] && ![first[@"diskFlags"] hasPrefix:@"A"];
	BOOL canStash = history && ![_snapshot[@"toolbarContext"] objectForKey:@"integration"] && !conflict.count && saved.count == selection.count && !toUnmark.count;
	for(NSDictionary* row in saved) if([row[@"untracked"] boolValue] && GitWorkingCopyIsTracked(row)) canStash = NO;
	__weak SourceControlViewController* weakSelf = self;
	void (^entry)(NSString*, BOOL, void(^)(void)) = ^(NSString* title, BOOL enabled, void(^action)(void)) {
		[weakSelf addWorkingCopyCommand:title enabled:enabled menu:menu action:action];
	};
	void (^edit)(GitWorkingCopyEdit, NSArray*, NSString*) = ^(GitWorkingCopyEdit action, NSArray* rows, NSString* argument){
		[weakSelf runWorkingCopyEdit:action rows:rows root:root argument:argument];
	};
	entry(@"Open", urls.count > 0, ^{ for(NSURL* url in urls) [NSWorkspace.sharedWorkspace openURL:url]; });
	NSMenu* apps = [self workingCopySubmenu:@"Open With" enabled:urls.count > 0 parent:menu];
	_workingCopyOpenWith = [[OakOpenWithMenuDelegate alloc] initWithDocumentURLs:urls];
	apps.autoenablesItems = YES;
	apps.delegate = _workingCopyOpenWith;
	[menu addItem:NSMenuItem.separatorItem];
	entry(@"Copy File Path", YES, ^{ [weakSelf copyWorkingCopyPaths:[selection valueForKey:@"absolutePath"]]; });
	entry(@"Copy Relative File Path", YES, ^{ [weakSelf copyWorkingCopyPaths:[selection valueForKey:@"path"]]; });
	[menu addItem:NSMenuItem.separatorItem];
	entry(single ? @"Quick Look" : FileMenuTitle(@"Quick Look", selection), urls.count > 0, ^{ [weakSelf quickLookWorkingCopyURLs:urls]; });
	entry(@"Reveal in Finder", urls.count > 0, ^{ [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:urls]; });
	entry(@"Open in Terminal", single && urls.count, ^{
		NSURL* folder = [first[@"directory"] boolValue] ? urls.firstObject : urls.firstObject.URLByDeletingLastPathComponent;
		if(NSURL* terminal = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.Terminal"])
			[NSWorkspace.sharedWorkspace openURLs:@[folder] withApplicationAtURL:terminal configuration:NSWorkspaceOpenConfiguration.configuration completionHandler:nil];
	});
	[menu addItem:NSMenuItem.separatorItem];
	entry(single ? @"Stage" : FileMenuTitle(@"Stage", selection), writable && stage.count, ^{ [weakSelf performWorkingCopyStage:GitRepositoryStage rows:stage root:root]; });
	entry(single ? @"Unstage" : FileMenuTitle(@"Unstage", selection), writable && unstage.count, ^{ [weakSelf performWorkingCopyStage:GitRepositoryUnstage rows:unstage root:root]; });
	entry(single ? @"Untrack" : FileMenuTitle(@"Untrack", selection), writable && canUntrack.count, ^{ edit(GitWorkingCopyUntrack, canUntrack, nil); });
	entry(@"Move to Trash", writable && trash.count, ^{ edit(GitWorkingCopyTrash, trash, nil); });
	entry(@"Move…", writable && single && trash.count && !conflict.count, ^{ [weakSelf chooseWorkingCopyMove:root rows:trash]; });
	[menu addItem:NSMenuItem.separatorItem];
	NSMenu* resolve = [self workingCopySubmenu:@"Resolve Merge Conflicts" enabled:writable && conflict.count parent:menu];
	[self addWorkingCopyCommand:@"Resolve Using Our Version" enabled:YES menu:resolve action:^{ edit(GitWorkingCopyUseOurs, conflict, nil); }];
	[self addWorkingCopyCommand:@"Resolve Using Their Version" enabled:YES menu:resolve action:^{ edit(GitWorkingCopyUseTheirs, conflict, nil); }];
	[self addWorkingCopyCommand:single ? @"Mark as Resolved" : [NSString stringWithFormat:@"Mark %lu Items as Resolved", (unsigned long)selection.count] enabled:YES menu:resolve action:^{ edit(GitWorkingCopyMarkResolved, conflict, nil); }];
	NSMenu* versions = [self workingCopySubmenu:@"Restore Merge Conflict Versions" enabled:writable && restorable.count parent:menu];
	[self addWorkingCopyCommand:single ? @"Restore Unmerged Version" : [NSString stringWithFormat:@"Restore Unmerged Version of %lu Items", (unsigned long)selection.count] enabled:YES menu:versions action:^{ edit(GitWorkingCopyRestoreConflict, restorable, nil); }];
	[self addWorkingCopyCommand:@"Restore Our Version" enabled:YES menu:versions action:^{ edit(GitWorkingCopyRestoreOurs, restorable, nil); }];
	[self addWorkingCopyCommand:@"Restore Their Version" enabled:YES menu:versions action:^{ edit(GitWorkingCopyRestoreTheirs, restorable, nil); }];
	[self addWorkingCopyCommand:@"Restore Ancestor Version" enabled:YES menu:versions action:^{ edit(GitWorkingCopyRestoreAncestor, restorable, nil); }];
	entry(@"Open Merge Tool", writable && single && conflict.count && [_snapshot[@"mergeTool"] length], ^{ edit(GitWorkingCopyMergeTool, conflict, nil); });
	[menu addItem:NSMenuItem.separatorItem];
	entry(@"Discard Local Changes…", writable && discard.count, ^{ [weakSelf confirmWorkingCopyEdit:GitWorkingCopyDiscard rows:discard root:root]; });
	entry(FileMenuTitle(@"Stash", selection, @"…"), writable && canStash, ^{ [weakSelf promptWorkingCopyStash:root rows:saved snapshot:NO]; });
	entry(single ? @"Quick Stash" : FileMenuTitle(@"Quick Stash", selection), writable && canStash, ^{ edit(GitWorkingCopyStash, saved, nil); });
	menu.itemArray.lastObject.alternate = YES;
	menu.itemArray.lastObject.keyEquivalentModifierMask = NSEventModifierFlagOption;
	entry(FileMenuTitle(@"Snapshot", selection, @"…"), writable && canStash, ^{ [weakSelf promptWorkingCopyStash:root rows:saved snapshot:YES]; });
	entry(single ? @"Quick Snapshot" : FileMenuTitle(@"Quick Snapshot", selection), writable && canStash, ^{ edit(GitWorkingCopySnapshot, saved, nil); });
	menu.itemArray.lastObject.alternate = YES;
	menu.itemArray.lastObject.keyEquivalentModifierMask = NSEventModifierFlagOption;
	entry(@"Revert to Revision…", writable && history && discard.count, ^{ [weakSelf promptWorkingCopyRevision:root rows:discard restore:YES]; });
	[menu addItem:NSMenuItem.separatorItem];
	entry(FileMenuTitle(@"Show", @[first]), file, ^{ [weakSelf readWorkingCopy:GitWorkingCopyReadHead root:root path:path revision:nil]; });
	entry(FileMenuTitle(@"Show Blame for", @[first]), file, ^{ [weakSelf readWorkingCopy:GitWorkingCopyBlame root:root path:path revision:nil]; });
	entry(FileMenuTitle(@"Show File History of", @[first]), file && self.showFileHistory != nil, ^{
		if(SourceControlViewController* controller = weakSelf) if(controller.showFileHistory) controller.showFileHistory(path);
	});
	[menu addItem:NSMenuItem.separatorItem];
	for(NSNumber* value in @[@(GitWorkingCopyIgnore), @(GitWorkingCopyExclude)]) {
		GitWorkingCopyEdit action = (GitWorkingCopyEdit)value.integerValue;
		BOOL local = action == GitWorkingCopyExclude;
		NSString* verb = local ? @"Exclude" : @"Ignore";
		NSMenu* rules = [self workingCopySubmenu:verb enabled:writable && ignore.count parent:menu];
		[self addWorkingCopyCommand:single ? [verb stringByAppendingString:@" This Item"] : FileMenuTitle(verb, selection) enabled:YES menu:rules action:^{ edit(action, ignore, nil); }];
		for(NSArray* kind in @[@[@(GitWorkingCopyFileName), @" All Items with Name"], @[@(GitWorkingCopyFileType), @" All Items with Type"]]) {
			NSMutableOrderedSet* patterns = [NSMutableOrderedSet orderedSet];
			for(NSDictionary* row in ignore) if(NSString* pattern = GitWorkingCopyIgnorePattern(row, (GitWorkingCopyPattern)[kind[0] integerValue])) [patterns addObject:pattern];
			[self addWorkingCopyCommand:[verb stringByAppendingString:kind[1]] enabled:patterns.count > 0 menu:rules action:^{ edit(action, ignore, [patterns.array componentsJoinedByString:@"\n"]); }];
		}
		[self addWorkingCopyCommand:@"Custom Pattern…" enabled:YES menu:rules action:^{ [weakSelf promptWorkingCopyIgnore:action root:root rows:ignore]; }];
	}
	NSMenu* mark = [self workingCopySubmenu:@"Mark" enabled:writable && stageableIndex.count parent:menu];
	[self addWorkingCopyCommand:@"Set Assume-Unchanged" enabled:toMark.count > 0 menu:mark action:^{ edit(GitWorkingCopyAssumeUnchanged, toMark, nil); }];
	[self addWorkingCopyCommand:@"Unset Assume-Unchanged" enabled:toUnmark.count > 0 menu:mark action:^{ edit(GitWorkingCopyClearAssumeUnchanged, toUnmark, nil); }];
	[menu addItem:NSMenuItem.separatorItem];
	NSArray* lfsRows = MatchingRows(trash, ^BOOL(NSDictionary* row){ return ![row[@"directory"] boolValue]; });
	BOOL lfsAvailable = [_snapshot[@"hasGitLFS"] boolValue];
	NSMenu* lfs = [self workingCopySubmenu:@"LFS" enabled:lfsRows.count > 0 parent:menu];
	[self addWorkingCopyCommand:@"Track with Git LFS" enabled:writable && lfsAvailable menu:lfs action:^{ edit(GitWorkingCopyTrackLFS, lfsRows, nil); }];
	[self addWorkingCopyCommand:@"Untrack from Git LFS" enabled:writable && lfsAvailable menu:lfs action:^{ edit(GitWorkingCopyUntrackLFS, lfsRows, nil); }];
	if(!lfsAvailable) [self addWorkingCopyCommand:@"Git LFS is not installed" enabled:NO menu:lfs action:nil];
	[menu addItem:NSMenuItem.separatorItem];
	NSArray* comparable = MatchingRows(selection, ^BOOL(NSDictionary* row){ return GitWorkingCopyIsTracked(row) && ![row[@"unsaved"] boolValue]; });
	NSMenu* compare = [self workingCopySubmenu:@"Compare" enabled:single || (history && comparable.count) parent:menu];
	NSDictionary* staged = _stagedByPath[path];
	[self addWorkingCopyCommand:@"Show Working Copy Diff" enabled:single && [first[@"group"] unsignedIntegerValue] != GitChangeStaged menu:compare action:^{ [weakSelf showChangeDiff:first]; }];
	[self addWorkingCopyCommand:@"Show Staged Diff" enabled:single && staged != nil menu:compare action:^{ [weakSelf showChangeDiff:staged]; }];
	[self addWorkingCopyCommand:@"Compare with HEAD" enabled:history && comparable.count menu:compare action:^{ [weakSelf readWorkingCopy:GitWorkingCopyCompareRevision root:root paths:[comparable valueForKey:@"path"] revision:@"HEAD"]; }];
	[self addWorkingCopyCommand:@"Compare with Revision…" enabled:history && comparable.count menu:compare action:^{ [weakSelf promptWorkingCopyRevision:root rows:comparable restore:NO]; }];
	if([_snapshot[@"diffTool"] length]) [self addWorkingCopyCommand:@"Open Diff Tool" enabled:history && comparable.count menu:compare action:^{
		[weakSelf openWorkingCopyDiffTool:root paths:[comparable valueForKey:@"path"]];
	}];
}

- (void)openWorkingCopyDiffTool:(NSString*)root paths:(NSArray<NSString*>*)paths
{
	if(!paths.count || ![root isEqual:_snapshot[@"root"]]) return;
	__weak SourceControlViewController* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDictionary* result = GitRepositoryCommand(root, [@[@"difftool", @"--no-prompt", @"--trust-exit-code", @"HEAD", @"--"] arrayByAddingObjectsFromArray:paths], YES, 600);
		if(NSString* error = GitWorkspaceError(result, @"The configured diff tool could not finish."))
			dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf showError:error]; });
	});
}

- (void)copyWorkingCopyPaths:(NSArray<NSString*>*)paths
{
	[NSPasteboard.generalPasteboard clearContents];
	[NSPasteboard.generalPasteboard setString:[paths componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
}

- (void)quickLookWorkingCopyURLs:(NSArray<NSURL*>*)urls
{
	[self focusChanges];
	_quickLookURLs = urls;
	QLPreviewPanel* preview = QLPreviewPanel.sharedPreviewPanel;
	[preview makeKeyAndOrderFront:nil];
	[preview reloadData];
}

- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel*)panel { return _quickLookURLs.count != 0; }
- (void)beginPreviewPanelControl:(QLPreviewPanel*)panel { panel.dataSource = self; }
- (void)endPreviewPanelControl:(QLPreviewPanel*)panel { panel.dataSource = nil; _quickLookURLs = nil; }
- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel*)panel { return _quickLookURLs.count; }
- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel*)panel previewItemAtIndex:(NSInteger)index { return _quickLookURLs[index]; }

- (void)performWorkingCopyStage:(GitRepositoryAction)action rows:(NSArray*)rows root:(NSString*)root
{
	if(!_waitingForIndex && [root isEqual:_snapshot[@"root"]]) [self perform:action changes:rows];
}

- (void)runWorkingCopyEdit:(GitWorkingCopyEdit)action rows:(NSArray*)rows root:(NSString*)root argument:(NSString*)argument
{
	if(_waitingForIndex || ![root isEqual:_snapshot[@"root"]] || !rows.count) return;
	NSArray* guarded = rows;
	NSString* special = action == GitWorkingCopyIgnore ? [root stringByAppendingPathComponent:@".gitignore"]
		: action == GitWorkingCopyTrackLFS || action == GitWorkingCopyUntrackLFS ? [root stringByAppendingPathComponent:@".gitattributes"] : nil;
	if(special) guarded = [rows arrayByAddingObject:@{@"absolutePath": special}];
	if(action == GitWorkingCopyMove && argument.length) {
		NSString* target = [argument.stringByResolvingSymlinksInPath stringByAppendingPathComponent:[rows.firstObject[@"path"] lastPathComponent]];
		guarded = [guarded arrayByAddingObject:@{@"absolutePath": target, @"directory": rows.firstObject[@"directory"] ?: @NO}];
	}
	NSString* head = _snapshot[@"head"];
	[self runMutation:GitRepositoryEditSelection changes:guarded execute:^NSString*{
		if(action == GitWorkingCopyDiscard || action == GitWorkingCopyRestoreRevision || action == GitWorkingCopyStash || action == GitWorkingCopySnapshot) {
			NSDictionary* current = ProjectChangesSnapshot(root, @{}, YES);
			if(![current[@"root"] isEqual:root] || ![current[@"head"] isEqual:head]) return @"HEAD changed. Refresh Working Copy and select the files again.";
			NSMutableDictionary* byPath = [NSMutableDictionary dictionary];
			for(NSDictionary* row in current[@"files"]) byPath[row[@"path"]] = row;
			for(NSDictionary* row in rows) {
				NSDictionary* status = byPath[row[@"path"]];
				if(![status[@"diskFlags"] isEqual:row[@"diskFlags"]] || ![status[@"untracked"] isEqual:row[@"untracked"]]) return @"The selected files changed. Refresh Working Copy and select them again.";
			}
		}
		return GitWorkingCopyModify(root, rows, action, argument);
	}];
}

- (void)promptWorkingCopyTitle:(NSString*)title info:(NSString*)info button:(NSString*)button field:(NSString*)initial destructive:(BOOL)destructive completion:(void(^)(NSString*))completion
{
	if(!self.view.window || self.view.window.attachedSheet) return;
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = title;
	alert.informativeText = info;
	alert.alertStyle = destructive ? NSAlertStyleWarning : NSAlertStyleInformational;
	NSTextField* field = nil;
	if(initial) {
		field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 295, 24)];
		field.stringValue = initial;
		field.accessibilityLabel = title;
		alert.accessoryView = field;
		alert.window.initialFirstResponder = field;
	}
	[alert addButtonWithTitle:button].hasDestructiveAction = destructive;
	[alert addButtonWithTitle:@"Cancel"];
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		if(response == NSAlertFirstButtonReturn) completion(field.stringValue);
	}];
}

- (void)confirmWorkingCopyEdit:(GitWorkingCopyEdit)action rows:(NSArray*)rows root:(NSString*)root
{
	__weak SourceControlViewController* weakSelf = self;
	[self promptWorkingCopyTitle:@"Discard Local Changes?" info:@"Remove staged and unstaged changes in the selected files and restore them to the last commit."
		button:@"Discard Changes" field:nil destructive:YES completion:^(NSString*){ [weakSelf runWorkingCopyEdit:action rows:rows root:root argument:nil]; }];
}

- (void)promptWorkingCopyStash:(NSString*)root rows:(NSArray*)rows snapshot:(BOOL)snapshot
{
	__weak SourceControlViewController* weakSelf = self;
	[self promptWorkingCopyTitle:snapshot ? @"Snapshot Selected Items" : @"Stash Selected Items"
		info:snapshot ? @"Save the selected changes to Stashes and keep them in the working copy." : @"Set aside the selected staged, unstaged, and untracked changes."
		button:snapshot ? @"Snapshot" : @"Stash" field:@"" destructive:NO completion:^(NSString* message){
			[weakSelf runWorkingCopyEdit:snapshot ? GitWorkingCopySnapshot : GitWorkingCopyStash rows:rows root:root argument:TrimCommitText(message)];
		}];
}

- (void)promptWorkingCopyRevision:(NSString*)root rows:(NSArray*)rows restore:(BOOL)restore
{
	__weak SourceControlViewController* weakSelf = self;
	[self promptWorkingCopyTitle:restore ? @"Revert to Revision" : @"Compare with Revision"
		info:restore ? @"Enter a branch, tag, or commit hash. This replaces staged and unstaged changes in the selected files." : @"Enter a branch, tag, or commit hash."
		button:restore ? @"Revert" : @"Compare" field:@"HEAD" destructive:restore completion:^(NSString* revision){
			revision = TrimCommitText(revision);
			if(restore) [weakSelf runWorkingCopyEdit:GitWorkingCopyRestoreRevision rows:rows root:root argument:revision];
		else [weakSelf readWorkingCopy:GitWorkingCopyCompareRevision root:root paths:[rows valueForKey:@"path"] revision:revision];
		}];
}

- (void)promptWorkingCopyIgnore:(GitWorkingCopyEdit)action root:(NSString*)root rows:(NSArray*)rows
{
	__weak SourceControlViewController* weakSelf = self;
	NSString* first = GitWorkingCopyIgnorePattern(rows.firstObject, GitWorkingCopyExactPath);
	[self promptWorkingCopyTitle:@"Add Git Ignore Pattern" info:action == GitWorkingCopyExclude ? @"The rule is stored only in this checkout’s Git exclude file." : @"The rule is added to this repository’s .gitignore."
		button:@"Add Pattern" field:first ?: @"" destructive:NO completion:^(NSString* pattern){
			[weakSelf runWorkingCopyEdit:action rows:rows root:root argument:pattern];
		}];
}

- (void)chooseWorkingCopyMove:(NSString*)root rows:(NSArray*)rows
{
	if(!self.view.window || self.view.window.attachedSheet || rows.count != 1) return;
	NSOpenPanel* panel = NSOpenPanel.openPanel;
	panel.canChooseDirectories = YES;
	panel.canChooseFiles = NO;
	panel.canCreateDirectories = YES;
	panel.prompt = @"Move";
	panel.directoryURL = [NSURL fileURLWithPath:root isDirectory:YES];
	__weak SourceControlViewController* weakSelf = self;
	[panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		if(response == NSModalResponseOK) [weakSelf runWorkingCopyEdit:GitWorkingCopyMove rows:rows root:root argument:panel.URL.path];
	}];
}

- (void)readWorkingCopy:(GitWorkingCopyRead)operation root:(NSString*)root path:(NSString*)path revision:(NSString*)revision
{
	[self readWorkingCopy:operation root:root paths:@[path] revision:revision];
}

- (void)readWorkingCopy:(GitWorkingCopyRead)operation root:(NSString*)root paths:(NSArray*)paths revision:(NSString*)revision
{
	if(!paths.count || ![root isEqual:_snapshot[@"root"]]) return;
	NSString* name = paths.count == 1 ? [paths.firstObject lastPathComponent] : [NSString stringWithFormat:@"%lu Items", (unsigned long)paths.count];
	NSString* caption = operation == GitWorkingCopyBlame ? @"Blame at HEAD" : operation == GitWorkingCopyReadHead ? @"Version at HEAD" : [NSString stringWithFormat:@"Compared with %@", revision];
	if(!_workingCopyPreview) {
		NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 830, 540) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
		window.releasedWhenClosed = NO;
		[window center];
		_workingCopyPreview = [[NSWindowController alloc] initWithWindow:window];
	}
	NSWindow* window = _workingCopyPreview.window;
	GitDiffView* view = [[GitDiffView alloc] initWithFrame:window.contentView.bounds];
	window.contentView = view;
	window.title = [NSString stringWithFormat:@"%@ — %@", name, caption];
	[view showTitle:name subtitle:caption patch:@{@"text": @"Loading…"}];
	[_workingCopyPreview showWindow:nil];
	__weak GitDiffView* weakView = view;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDictionary* patch = operation == GitWorkingCopyCompareRevision ? GitWorkingCopyComparePaths(root, paths, revision) : GitWorkingCopyPreview(root, paths.firstObject, operation, revision);
		dispatch_async(dispatch_get_main_queue(), ^{ [weakView showTitle:name subtitle:caption patch:patch]; });
	});
}

- (IBAction)stageOrUnstage:(NSButton*)sender
{
	NSInteger index = [_table rowForView:sender];
	if(index < 0 || index >= _rows.count) return;
	NSDictionary* row = _rows[index];
	BOOL staged = [row[@"group"] unsignedIntegerValue] == GitChangeStaged;
	sender.state = staged ? NSControlStateValueOn : _stagedByPath[row[@"path"]] ? NSControlStateValueMixed : NSControlStateValueOff;
	if(![row[@"writable"] boolValue]) return;
	[self perform:staged ? GitRepositoryUnstage : GitRepositoryStage changes:@[row]];
}

- (IBAction)toggleBulkStage:(NSButton*)sender
{
	if(!sender.enabled) return;
	GitRepositoryAction action = (GitRepositoryAction)sender.tag;
	[self perform:action changes:[self changesForAction:action]];
}

- (NSArray*)changesForAction:(GitRepositoryAction)action
{
	NSArray* candidates = action == GitRepositoryDiscard ? [self selectedChanges] : _changes;
	NSMutableArray* result = [NSMutableArray array];
	for(NSDictionary* row in candidates) {
		NSUInteger group = [row[@"group"] unsignedIntegerValue];
		if(![row[@"writable"] boolValue]) continue;
		if(action == GitRepositoryUnstage ? group == GitChangeStaged : action == GitRepositoryStage ? group == GitChangeWorking : group == GitChangeWorking && ![row[@"code"] isEqual:@"?"])
			[result addObject:row];
	}
	return action == GitRepositoryDiscard && result.count != candidates.count ? @[] : result;
}

- (BOOL)canPerformAction:(GitRepositoryAction)action
{
	if(_busy || !_snapshot[@"root"]) return NO;
	NSDictionary* context = _snapshot[@"toolbarContext"];
	BOOL integrating = context[@"integration"] != nil;
	BOOL onBranch = [_snapshot[@"head"] length] && ![_snapshot[@"branch"] isEqual:@"Detached HEAD"];
	if(action == GitRepositoryContinueIntegration || action == GitRepositoryAbortIntegration) return integrating;
	if(action == GitRepositoryFetch) return [context[@"remotes"] count] > 0;
	if(action == GitRepositoryPull || action == GitRepositoryPush || action == GitRepositorySync) return onBranch && !integrating && [context[@"remotes"] count] > 0;
	if(action == GitRepositoryMerge || action == GitRepositoryRebase) return onBranch && !integrating;
	if(action == GitRepositoryCreateBranch) return [_snapshot[@"head"] length] != 0;
	if(action == GitRepositorySaveStash) return [_snapshot[@"head"] length] && _changes.count > 0;
	if(action <= GitRepositoryDiscard) return !_waitingForIndex && [self changesForAction:action].count != 0;
	return YES;
}

- (void)performToolbarAction:(GitRepositoryAction)action
{
	if(![self canPerformAction:action]) return;
	if(action == GitRepositorySwitchBranch) [self switchBranch:nil];
	else if(action == GitRepositoryCreateBranch) [self createBranch:nil];
	else if(action == GitRepositorySaveStash) [self saveStash:nil];
	else if(action == GitRepositoryStage || action == GitRepositoryUnstage) [self perform:action changes:[self changesForAction:action]];
}

- (void)showToolbarAction:(GitRepositoryAction)action reference:(NSString*)reference quick:(BOOL)quick
{
	if(![self canPerformAction:action] || !self.view.window || self.view.window.attachedSheet) return;
	if(action == GitRepositorySaveStash) { [self saveStash:nil]; return; }
	NSString* root = _snapshot[@"root"], *head = _snapshot[@"head"], *current = _snapshot[@"branch"];
	NSDictionary* context = _snapshot[@"toolbarContext"];
	BOOL integration = action == GitRepositoryMerge || action == GitRepositoryRebase;
	BOOL finish = action == GitRepositoryContinueIntegration || action == GitRepositoryAbortIntegration;
	NSString* preferredRemote = context[@"remote"], *preferredBranch = context[@"branch"];
	if(quick && action == GitRepositoryFetch) { [self perform:action changes:@[]]; return; }
	if(quick && (action == GitRepositoryPull || action == GitRepositoryPush || action == GitRepositorySync) && preferredRemote.length && preferredBranch.length) {
		[self runMutation:action changes:@[] execute:^NSString*{ return GitRepositoryRemoteAction(root, action, preferredRemote, preferredBranch, @"merge", current); }];
		return;
	}
	__weak SourceControlViewController* weakSelf = self;
	if(integration) {
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			NSDictionary* result = GitRepositoryReferences(root);
			dispatch_async(dispatch_get_main_queue(), ^{
				SourceControlViewController* controller = weakSelf;
				if(!controller.panelVisible || ![controller->_snapshot[@"root"] isEqual:root] || ![controller->_snapshot[@"head"] isEqual:head] || ![controller->_snapshot[@"branch"] isEqual:current]) return;
				if(result[@"error"]) { [controller showError:result[@"error"]]; return; }
				[controller chooseIntegration:action refs:result[@"refs"] reference:reference quick:quick];
			});
		});
		return;
	}
	if(finish) {
		NSString* operation = context[@"integration"];
		BOOL abort = action == GitRepositoryAbortIntegration;
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText = [NSString stringWithFormat:@"%@ %@", abort ? @"Abort" : @"Continue", operation.capitalizedString];
		alert.informativeText = abort ? @"Return the branch to its state before the operation began." : @"Resolve and stage all conflicted files before continuing.";
		[alert addButtonWithTitle:alert.messageText].hasDestructiveAction = abort;
		[alert addButtonWithTitle:@"Cancel"];
		[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
			SourceControlViewController* controller = weakSelf;
			if(response != NSAlertFirstButtonReturn || !controller || ![controller->_snapshot[@"root"] isEqual:root] || ![controller canPerformAction:action]
				|| ![controller->_snapshot[@"toolbarContext"][@"integration"] isEqual:operation]) return;
			[controller runMutation:action changes:@[] execute:^NSString*{ return GitRepositoryFinishIntegration(root, operation, abort); }];
		}];
		return;
	}

	BOOL fetch = action == GitRepositoryFetch, pulling = action == GitRepositoryPull, pushing = action == GitRepositoryPush;
	NSString* title = fetch ? @"Fetch" : pulling ? @"Pull" : pushing ? @"Push" : @"Sync";
	NSString* detail = fetch ? @"Fetches new revisions from the selected remote. Downloaded data is not integrated into your working copy."
		: [NSString stringWithFormat:pulling ? @"Fetches new revisions from the selected remote branch and integrates them into “%@”."
			: pushing ? @"Pushes new revisions from “%@” to the selected remote branch."
			: @"Pulls and integrates new revisions into “%@”, then pushes to the same remote branch.", current];
	GitOperationSheet* sheet = [[GitOperationSheet alloc] initWithTitle:title detail:detail helpTopic:action == GitRepositorySync ? @"pull" : title.lowercaseString];
	NSPopUpButton* remotes = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	for(NSString* remote in context[@"remotes"]) {
		[remotes addItemWithTitle:remote];
		remotes.lastItem.representedObject = remote;
	}
	if(preferredRemote) [remotes selectItemWithTitle:preferredRemote];
	[sheet addField:remotes label:@"Remote:"];
	NSButton* allRemotes = nil;
	GitRemoteBranchField* branch = nil;
	if(fetch) {
		allRemotes = [sheet addOption:@"Fetch All Remotes" detail:nil];
		allRemotes.state = NSControlStateValueOn;
		[sheet setControls:@[remotes] enabledWhen:allRemotes checked:NO];
	} else {
		branch = [[GitRemoteBranchField alloc] initWithFrame:NSZeroRect];
		branch.placeholderString = @"Remote branch";
		branch.completes = YES;
		branch.remoteBranches = context[@"remoteBranches"];
		branch.localBranch = current;
		branch.preferredRemote = preferredRemote;
		branch.preferredBranch = preferredBranch;
		// A remote branch selected in the sidebar is also the initial choice here.
		if([reference hasPrefix:@"refs/remotes/"]) {
			NSString* name = [reference substringFromIndex:13];
			NSString* matchedRemote = nil;
			for(NSString* remote in context[@"remotes"])
				if(remote.length > matchedRemote.length && [name hasPrefix:[remote stringByAppendingString:@"/"]]) matchedRemote = remote;
			if(matchedRemote) {
				[remotes selectItemWithTitle:matchedRemote];
				branch.preferredRemote = matchedRemote;
				branch.preferredBranch = [name substringFromIndex:matchedRemote.length+1];
			}
		}
		remotes.target = branch;
		remotes.action = @selector(remoteChanged:);
		[branch remoteChanged:remotes];
		[sheet addField:branch label:@"Remote Branch:"];
		[sheet requireBranch:branch remote:remotes];
	}

	[sheet beginOptions];
	NSPopUpButton* strategy = nil;
	if(!fetch && !pushing) {
		strategy = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
		[strategy addItemsWithTitles:@[@"Merge", @"Rebase", @"Fast Forward Only"]];
		[sheet addField:strategy label:@"Integrate:"];
	}
	GitPullOptions (^fetchOptions)(void) = nil;
	GitPushOptions (^pushOptions)(void) = nil;
	if(fetch || pulling) fetchOptions = AddFetchOptions(sheet);
	else pushOptions = AddPushOptions(sheet);
	[sheet presentInWindow:self.view.window firstResponder:fetch ? (NSView*)allRemotes : remotes accept:^{
		SourceControlViewController* controller = weakSelf;
		if(!controller || ![controller->_snapshot[@"root"] isEqual:root] || ![controller canPerformAction:action]) return;
		if(!fetch && (![controller->_snapshot[@"head"] isEqual:head] || ![controller->_snapshot[@"branch"] isEqual:current])) return;
		NSString* remote = allRemotes.state == NSControlStateValueOn ? nil : remotes.selectedItem.representedObject;
		NSString* name = TrimCommitText(branch.stringValue);
		NSString* mode = strategy ? @[@"merge", @"rebase", @"ff"][MAX(0, strategy.indexOfSelectedItem)] : nil;
		GitPullOptions pullFlags = fetchOptions ? fetchOptions() : (GitPullOptions)0;
		GitPushOptions pushFlags = pushOptions ? pushOptions() : (GitPushOptions)0;
		[controller runMutation:action changes:@[] execute:^NSString*{
			return GitRepositoryRemoteAction(root, action, remote, name, mode, current, pullFlags, pushFlags);
		}];
	}];
}

- (void)chooseIntegration:(GitRepositoryAction)action refs:(NSArray<NSString*>*)refs reference:(NSString*)reference quick:(BOOL)quick
{
	if(![self canPerformAction:action] || self.view.window.attachedSheet) return;
	NSString* root = _snapshot[@"root"], *head = _snapshot[@"head"], *current = _snapshot[@"branch"];
	NSString* currentRef = [@"refs/heads/" stringByAppendingString:current];
	NSString* upstream = [_snapshot[@"tracking"] componentsSeparatedByString:@" ["].firstObject;
	NSString* preferred = [refs containsObject:reference ?: @""] && ![reference isEqual:currentRef] ? reference : [@"refs/remotes/" stringByAppendingString:upstream ?: @""];
	if(quick && [refs containsObject:preferred]) {
		[self runMutation:action changes:@[] execute:^NSString*{ return GitRepositoryIntegrate(root, action, preferred); }];
		return;
	}
	NSPopUpButton* choices = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 294, 26) pullsDown:NO];
	for(NSString* ref in refs) {
		if([ref isEqual:currentRef]) continue;
		NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:[ref substringFromIndex:5] action:NULL keyEquivalent:@""];
		item.representedObject = ref;
		[choices.menu addItem:item];
		if([ref isEqual:preferred]) [choices selectItem:item];
	}
	if(!choices.numberOfItems) { [self showError:@"There is no other branch or tag to select."]; return; }
	if(!choices.selectedItem) [choices selectItemAtIndex:0];
	BOOL merge = action == GitRepositoryMerge;
	GitOperationSheet* sheet = [[GitOperationSheet alloc] initWithTitle:merge ? @"Merge" : @"Rebase"
		detail:merge ? [NSString stringWithFormat:@"Merges the selected branch or tag into “%@”.", current]
			: [NSString stringWithFormat:@"Replays the commits on “%@” on top of the selected branch. This changes their commit IDs.", current]
		helpTopic:merge ? @"merge" : @"rebase"];
	[sheet addField:choices label:@"Branch:"];
	NSButton* commit = nil, *noFF = nil, *squash = nil, *verify = nil;
	if(merge) {
		[sheet beginOptions];
		commit = [sheet addOption:@"Directly Commit Merged Changes" detail:@"Turn off to review the merged changes before committing."];
		commit.state = NSControlStateValueOn;
		noFF = [sheet addOption:@"Always Generate Merge Commit" detail:@"Creates a merge commit even if the branch can be fast forwarded."];
		squash = [sheet addOption:@"Squash Commits" detail:@"Combines the changes in the staging area without creating a merge commit."];
		verify = [sheet addOption:@"Verify Signatures" detail:@"Stops the merge if the selected branch tip is not signed with a valid key."];
		[sheet setControls:@[commit, noFF] enabledWhen:squash checked:NO];
	}
	__weak SourceControlViewController* weakSelf = self;
	[sheet presentInWindow:self.view.window firstResponder:choices accept:^{
		SourceControlViewController* controller = weakSelf;
		if(!controller || ![controller canPerformAction:action] || ![controller->_snapshot[@"root"] isEqual:root] || ![controller->_snapshot[@"head"] isEqual:head] || ![controller->_snapshot[@"branch"] isEqual:current]) return;
		NSString* ref = choices.selectedItem.representedObject;
		GitMergeOptions options = (GitMergeOptions)((commit && commit.state == NSControlStateValueOff ? GitMergeNoCommit : 0) |
			(noFF.state == NSControlStateValueOn ? GitMergeNoFastForward : 0) | (squash.state == NSControlStateValueOn ? GitMergeSquash : 0) |
			(verify.state == NSControlStateValueOn ? GitMergeVerifySignatures : 0));
		[controller runMutation:action changes:@[] execute:^NSString*{ return GitRepositoryIntegrate(root, action, ref, options); }];
	}];
}

- (IBAction)openActions:(NSButton*)sender
{
	NSMenu* menu = [[NSMenu alloc] init];
	NSMenuItem* assumed = [menu addItemWithTitle:@"Show Assume-Unchanged Items" action:@selector(toggleAssumeUnchangedItems:) keyEquivalent:@""];
	assumed.target = self;
	assumed.state = _showAssumeUnchanged ? NSControlStateValueOn : NSControlStateValueOff;
	[menu addItem:NSMenuItem.separatorItem];
	for(NSArray* command in @[@[@"Refresh", @(-1)], @[@"Stage All Saved Changes", @(GitRepositoryStage)], @[@"Unstage All", @(GitRepositoryUnstage)],
		@[@"Discard Selected Changes…", @(GitRepositoryDiscard)], @[], @[@"Fetch All Remotes", @(GitRepositoryFetch)],
		@[@"Pull (Fast Forward Only)", @(GitRepositoryPull)], @[@"Push", @(GitRepositoryPush)]]) {
		if(!command.count) { [menu addItem:NSMenuItem.separatorItem]; continue; }
		NSMenuItem* item = [menu addItemWithTitle:command[0] action:@selector(takeAction:) keyEquivalent:@""];
		item.target = self;
		item.tag = [command[1] integerValue];
	}
	[menu addItem:NSMenuItem.separatorItem];
	[menu addItemWithTitle:@"Switch Branch…" action:@selector(switchBranch:) keyEquivalent:@""].target = self;
	[menu addItemWithTitle:@"Create and Switch to Branch…" action:@selector(createBranch:) keyEquivalent:@""].target = self;
	[menu addItemWithTitle:@"Save Stash…" action:@selector(saveStash:) keyEquivalent:@""].target = self;
	if(NSString* operation = _snapshot[@"toolbarContext"][@"integration"]) {
		[menu addItem:NSMenuItem.separatorItem];
		for(NSNumber* tag in @[@(GitRepositoryContinueIntegration), @(GitRepositoryAbortIntegration)]) {
			NSString* title = [NSString stringWithFormat:@"%@ %@…", tag.integerValue == GitRepositoryAbortIntegration ? @"Abort" : @"Continue", operation.capitalizedString];
			NSMenuItem* item = [menu addItemWithTitle:title action:@selector(takeAction:) keyEquivalent:@""];
			item.target = self;
			item.tag = tag.integerValue;
		}
	}
	[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds)+4) inView:sender];
}

- (IBAction)toggleAssumeUnchangedItems:(id)sender
{
	_showAssumeUnchanged = !_showAssumeUnchanged;
	++_generation;
	_refreshing = NO;
	[self refresh:nil];
}

- (BOOL)validateMenuItem:(NSMenuItem*)item
{
	if(item.action == @selector(toggleAssumeUnchangedItems:)) return _snapshot[@"root"] != nil && !_busy;
	if(item.action == @selector(switchBranch:)) return _snapshot[@"root"] != nil && !_busy;
	if(item.action == @selector(createBranch:)) return [_snapshot[@"head"] length] && !_busy;
	if(item.action == @selector(saveStash:)) return [self canPerformAction:GitRepositorySaveStash];
	if(item.tag < 0) return !_busy && !_refreshing;
	if(_busy || !_snapshot[@"root"]) return NO;
	return [self canPerformAction:(GitRepositoryAction)item.tag];
}

- (IBAction)takeAction:(NSMenuItem*)sender
{
	if(sender.tag < 0) { [self refresh:sender]; return; }
	GitRepositoryAction action = (GitRepositoryAction)sender.tag;
	if(action == GitRepositoryContinueIntegration || action == GitRepositoryAbortIntegration) {
		[self showToolbarAction:action reference:nil quick:NO];
		return;
	}
	NSArray* rows = [self changesForAction:action];
	if(action != GitRepositoryDiscard) { [self perform:action changes:rows]; return; }
	if(!rows.count || !self.view.window) return;
	NSAlert* alert = [[NSAlert alloc] init];
	alert.alertStyle = NSAlertStyleWarning;
	alert.messageText = rows.count == 1 ? @"Discard changes to this file?" : @"Discard changes to these files?";
	alert.informativeText = @"This restores the saved working files from the index. Staged changes are kept.";
	[alert addButtonWithTitle:@"Cancel"];
	[alert addButtonWithTitle:@"Discard Changes"];
	NSString* directory = self.directory;
	__weak SourceControlViewController* weakSelf = self;
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		if(response == NSAlertSecondButtonReturn && [directory isEqual:weakSelf.directory]) [weakSelf perform:action changes:rows];
	}];
}

- (IBAction)switchBranch:(id)sender
{
	NSString* root = _snapshot[@"root"];
	if(!root || _busy) return;
	__weak SourceControlViewController* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDictionary* result = GitRepositoryBranches(root);
		dispatch_async(dispatch_get_main_queue(), ^{
			SourceControlViewController* controller = weakSelf;
			if(!controller || controller->_busy || !controller.panelVisible || ![controller->_snapshot[@"root"] isEqual:root]) return;
			if(result[@"error"]) { [controller showError:result[@"error"]]; return; }
			NSMutableArray* branches = [result[@"branches"] mutableCopy];
			[branches removeObject:controller->_snapshot[@"branch"]];
			if(!branches.count) { [controller showError:@"There are no other local branches."]; return; }
#if HAVE_OAK_SWIFTUI
			[controller showBranchPalette:branches root:root];
#else
			NSPopUpButton* choices = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 260, 26) pullsDown:NO];
			[choices addItemsWithTitles:branches];
			[controller promptForBranchWithView:choices create:NO root:root];
#endif
		});
	});
}

#if HAVE_OAK_SWIFTUI
- (void)showBranchPalette:(NSArray<NSString*>*)branches root:(NSString*)root
{
	NSWindow* parent = self.view.window;
	if(!parent || parent.attachedSheet) return;
	if(!_branchPalette) _branchPalette = [[OakCommandPalette alloc] initWithTheme:[[OakThemeEnvironment alloc] init]];
	NSMutableArray* items = [NSMutableArray arrayWithCapacity:branches.count];
	for(NSString* branch in branches) {
		OakCommandPaletteItem* item = [[OakCommandPaletteItem alloc] initWithTitle:branch subtitle:@"" keyEquivalent:@""
			category:OakCommandPaletteCategoryMenuAction actionIdentifier:branch];
		item.icon = [NSImage imageWithSystemSymbolName:@"arrow.triangle.branch" accessibilityDescription:nil];
		[items addObject:item];
	}
	__weak SourceControlViewController* weakSelf = self;
	[_branchPalette showIn:parent items:items label:@"Switch Branch" placeholder:@"Search local branches…"
		suggestions:^NSArray*(NSString* query){ return @[]; } onSelect:^(OakCommandPaletteItem* item){
		SourceControlViewController* controller = weakSelf;
		if(!controller || !controller.panelVisible || ![controller->_snapshot[@"root"] isEqual:root] || ![controller canPerformAction:GitRepositorySwitchBranch]) return;
		if(![controller->_snapshot[@"branch"] isEqual:item.title]) [controller perform:GitRepositorySwitchBranch changes:@[] message:item.title];
	}];
}
#endif

- (IBAction)createBranch:(id)sender
{
	NSString* root = _snapshot[@"root"];
	if(!root || _busy) return;
	NSTextField* name = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
	name.placeholderString = @"Branch name";
	[self promptForBranchWithView:name create:YES root:root];
}

- (void)promptForBranchWithView:(NSView*)view create:(BOOL)create root:(NSString*)root
{
	if(!self.view.window || self.view.window.attachedSheet) return;
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = create ? @"Create and Switch to Branch" : @"Switch Branch";
	alert.accessoryView = view;
	[alert addButtonWithTitle:create ? @"Create Branch" : @"Switch Branch"];
	[alert addButtonWithTitle:@"Cancel"];
	alert.window.initialFirstResponder = view;
	__weak SourceControlViewController* weakSelf = self;
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		SourceControlViewController* controller = weakSelf;
		if(!controller || response != NSAlertFirstButtonReturn || ![controller->_snapshot[@"root"] isEqual:root]) return;
		NSString* branch = create ? [((NSTextField*)view).stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : ((NSPopUpButton*)view).titleOfSelectedItem;
		[controller perform:create ? GitRepositoryCreateBranch : GitRepositorySwitchBranch changes:@[] message:branch];
	}];
}

- (void)checkOutReference:(NSString*)reference
{
	NSString* root = _snapshot[@"root"];
	if(!root || _busy || !self.panelVisible || self.view.window.attachedSheet) return;
	NSString* localPrefix = @"refs/heads/", *remotePrefix = @"refs/remotes/";
	if([reference hasPrefix:localPrefix]) {
		NSString* branch = [reference substringFromIndex:localPrefix.length];
		if(![branch isEqual:_snapshot[@"branch"]]) [self perform:GitRepositorySwitchBranch changes:@[] message:branch];
		return;
	}
	if(![reference hasPrefix:remotePrefix] || !self.view.window) return;
	NSString* name = [reference substringFromIndex:remotePrefix.length];
	NSRange separator = [name rangeOfString:@"/"];
	if(separator.location == NSNotFound) return;
	NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
	field.stringValue = [name substringFromIndex:NSMaxRange(separator)];
	field.accessibilityLabel = @"Local branch name";
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = @"Check Out Remote Branch";
	alert.informativeText = [NSString stringWithFormat:@"Create a local branch that tracks %@.", name];
	alert.accessoryView = field;
	alert.window.initialFirstResponder = field;
	[alert addButtonWithTitle:@"Check Out"];
	[alert addButtonWithTitle:@"Cancel"];
	__weak SourceControlViewController* weakSelf = self;
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		SourceControlViewController* controller = weakSelf;
		if(!controller || response != NSAlertFirstButtonReturn || ![controller->_snapshot[@"root"] isEqual:root]) return;
		NSString* branch = TrimCommitText(field.stringValue);
		[controller runMutation:GitRepositoryTrackBranch changes:@[] execute:^NSString*{ return GitRepositoryCreateTrackingBranch(root, branch, reference); }];
	}];
}

- (IBAction)saveStash:(id)sender
{
	NSString* root = _snapshot[@"root"];
	if(![self canPerformAction:GitRepositorySaveStash] || !self.view.window || self.view.window.attachedSheet) return;
	NSTextField* message = [[NSTextField alloc] initWithFrame:NSZeroRect];
	message.placeholderString = @"Short stash summary (optional)";
	message.accessibilityLabel = @"Stash message";
	GitOperationSheet* sheet = [[GitOperationSheet alloc] initWithTitle:@"Save Stash"
		detail:@"Saves the changes in the working copy and staging area so you can restore them later." helpTopic:@"stash"];
	[sheet addField:message label:@"Message:"];
	NSButton* untracked = [sheet addOption:@"Include Untracked Files" detail:nil];
	__weak SourceControlViewController* weakSelf = self;
	[sheet presentInWindow:self.view.window firstResponder:message accept:^{
		SourceControlViewController* controller = weakSelf;
		if(!controller || ![controller->_snapshot[@"root"] isEqual:root] || ![controller canPerformAction:GitRepositorySaveStash]) return;
		NSString* text = TrimCommitText(message.stringValue);
		BOOL includeUntracked = untracked.state == NSControlStateValueOn;
		[controller runMutation:GitRepositorySaveStash changes:@[] execute:^NSString*{ return GitRepositoryStashChanges(root, text, includeUntracked); }];
	}];
}

- (void)applyStash:(NSDictionary*)stash pop:(BOOL)pop
{
	[self promptToApplyStash:stash alternatives:nil pop:pop];
}

- (void)chooseStashToApply:(NSArray<NSDictionary*>*)stashes preferred:(NSDictionary*)preferred
{
	if(stashes.count) [self promptToApplyStash:preferred ?: stashes.firstObject alternatives:stashes pop:NO];
}

- (void)promptToApplyStash:(NSDictionary*)stash alternatives:(NSArray<NSDictionary*>*)stashes pop:(BOOL)pop
{
	NSString* root = _snapshot[@"root"];
	if(![self canPerformAction:GitRepositoryApplyStash] || !self.view.window || self.view.window.attachedSheet) return;
	GitOperationSheet* sheet = [[GitOperationSheet alloc] initWithTitle:pop ? @"Pop Stash" : @"Apply Stash"
		detail:pop ? @"Restores the changes to the working copy and deletes the stash after they apply successfully."
			: @"Restores the selected stash to the working copy." helpTopic:@"stash"];
	NSPopUpButton* choices = nil;
	if(stashes.count) {
		choices = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
		for(NSDictionary* candidate in stashes) {
			NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@  %@", candidate[@"refs"], candidate[@"subject"]] action:NULL keyEquivalent:@""];
			item.representedObject = candidate;
			[choices.menu addItem:item];
			if([candidate[@"id"] isEqual:stash[@"id"]] && [candidate[@"refs"] isEqual:stash[@"refs"]]) [choices selectItem:item];
		}
		if(!choices.selectedItem) [choices selectItemAtIndex:0];
		[sheet addField:choices label:@"Stash:"];
	} else {
		NSTextField* name = GitLabel(stash[@"subject"] ?: @"", 13, NSFontWeightRegular);
		name.toolTip = name.stringValue;
		[sheet addField:name label:@"Stash:"];
	}
	NSButton* restoreIndex = [sheet addOption:@"Restore Staging Area Status" detail:nil];
	NSButton* removeAfter = pop ? nil : [sheet addOption:@"Delete Stash After Applying Changes" detail:nil];
	__weak SourceControlViewController* weakSelf = self;
	[sheet presentInWindow:self.view.window firstResponder:choices accept:^{
		SourceControlViewController* controller = weakSelf;
		if(!controller || ![controller->_snapshot[@"root"] isEqual:root] || ![controller canPerformAction:GitRepositoryApplyStash]) return;
		BOOL restore = restoreIndex.state == NSControlStateValueOn;
		BOOL drop = pop || removeAfter.state == NSControlStateValueOn;
		NSDictionary* chosen = choices.selectedItem.representedObject ?: stash;
		[controller runMutation:GitRepositoryApplyStash changes:@[] execute:^NSString*{ return GitRepositoryApplySavedStash(root, chosen, restore, drop); }];
	}];
}

- (void)deleteStash:(NSDictionary*)stash
{
	NSString* root = _snapshot[@"root"];
	if(![self canPerformAction:GitRepositoryDropStash] || !self.view.window || self.view.window.attachedSheet) return;
	NSAlert* alert = [[NSAlert alloc] init];
	alert.alertStyle = NSAlertStyleWarning;
	alert.messageText = @"Delete Stash?";
	alert.informativeText = [NSString stringWithFormat:@"“%@” will be removed without applying its changes.", stash[@"subject"]];
	[alert addButtonWithTitle:@"Cancel"];
	[alert addButtonWithTitle:@"Delete Stash"].hasDestructiveAction = YES;
	__weak SourceControlViewController* weakSelf = self;
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		SourceControlViewController* controller = weakSelf;
		if(!controller || response != NSAlertSecondButtonReturn || ![controller->_snapshot[@"root"] isEqual:root]) return;
		[controller runMutation:GitRepositoryDropStash changes:@[] execute:^NSString*{ return GitRepositoryDropSavedStash(root, stash); }];
	}];
}

- (IBAction)commit:(id)sender
{
	[self updateControls];
	if(!_commit.enabled) return;
	NSString* subject = TrimCommitText(_message.stringValue);
	NSString* body = TrimCommitText(_description.string);
	NSString* message = body.length ? [NSString stringWithFormat:@"%@\n\n%@", subject, body] : subject;
	NSString* amendHead = _amend.enabled ? (_amendHead ?: ([self quickAmend] ? _snapshot[@"head"] : nil)) : nil;
	[self perform:GitRepositoryCommit changes:@[] message:message amendHead:amendHead signOff:[self shouldSignOff]];
}

- (void)perform:(GitRepositoryAction)action changes:(NSArray<NSDictionary*>*)rows
{
	[self perform:action changes:rows message:nil];
}

- (void)performHunk:(NSString*)hunk change:(NSDictionary*)change action:(GitRepositoryAction)action contextLines:(NSUInteger)contextLines
{
	if(!hunk.length || _busy || _waitingForIndex || ![_changes containsObject:change]) return;
	NSDictionary* snapshot = _snapshot;
	if(action == GitRepositoryDiscard) {
		if(self.view.window.attachedSheet) return;
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText = @"Discard This Chunk?";
		alert.informativeText = [NSString stringWithFormat:@"Only the selected changes in %@ will be discarded.", change[@"path"]];
		[alert addButtonWithTitle:@"Cancel"];
		[alert addButtonWithTitle:@"Discard Chunk"].hasDestructiveAction = YES;
		[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
			if(response != NSAlertSecondButtonReturn || ![self->_snapshot[@"root"] isEqual:snapshot[@"root"]]) return;
			[self runMutation:action changes:@[change] execute:^NSString*{ return GitRepositoryApplyHunk(snapshot, change, hunk, action, contextLines); }];
		}];
	} else [self runMutation:action changes:@[change] execute:^NSString*{ return GitRepositoryApplyHunk(snapshot, change, hunk, action, contextLines); }];
}

- (void)perform:(GitRepositoryAction)action changes:(NSArray<NSDictionary*>*)rows message:(NSString*)message
{
	[self perform:action changes:rows message:message amendHead:nil signOff:NO];
}

- (void)perform:(GitRepositoryAction)action changes:(NSArray<NSDictionary*>*)rows message:(NSString*)message amendHead:(NSString*)amendHead signOff:(BOOL)signOff
{
	NSString* root = _snapshot[@"root"];
	NSArray* paths = [rows valueForKey:@"path"];
	[self runMutation:action changes:rows execute:^NSString*{
		return action == GitRepositoryCommit ? GitRepositoryCommitChanges(root, message, amendHead, signOff) : GitRepositoryPerform(root, action, paths, message);
	}];
}

- (void)runWorkspaceMutationAtRoot:(NSString*)root changesWorktree:(BOOL)changesWorktree path:(NSString*)path execute:(NSString*(^)(void))execute
{
	if(![root isEqual:_snapshot[@"root"]] || ![self canPerformAction:GitRepositorySwitchBranch] || self.view.window.attachedSheet) return;
	NSArray* rows = path ? @[@{@"absolutePath": ProjectChangesBufferAbsolutePath([root stringByAppendingPathComponent:path])}] : @[];
	[self runMutation:changesWorktree && !path ? GitRepositorySwitchBranch : GitRepositoryEditSelection changes:rows execute:execute];
}

- (void)runMutation:(GitRepositoryAction)action changes:(NSArray<NSDictionary*>*)rows execute:(NSString*(^)(void))execute
{
	NSString* root = _snapshot[@"root"];
	if(_busy || !root || (action <= GitRepositoryDiscard && !rows.count)) return;
	BOOL changesWorktree = action == GitRepositoryPull || action == GitRepositorySwitchBranch || action == GitRepositoryCreateBranch
		|| action == GitRepositoryTrackBranch || action == GitRepositorySaveStash || action == GitRepositoryApplyStash || action == GitRepositorySync
		|| action == GitRepositoryMerge || action == GitRepositoryRebase || action == GitRepositoryContinueIntegration || action == GitRepositoryAbortIntegration;
	if(self.bufferProvider && (action == GitRepositoryStage || action == GitRepositoryDiscard || action == GitRepositoryEditSelection || changesWorktree)) {
		NSDictionary* buffers = self.bufferProvider();
		for(NSString* path in buffers) {
			NSString* resolved = ProjectChangesBufferAbsolutePath(path);
			BOOL inRepository = [resolved hasPrefix:[root isEqual:@"/"] ? @"/" : [root stringByAppendingString:@"/"]];
			BOOL affected = changesWorktree && inRepository;
			for(NSDictionary* row in rows) {
				NSString* target = row[@"absolutePath"];
				affected |= [path isEqual:row[@"bufferPath"]] || [resolved isEqual:target];
				if([row[@"directory"] boolValue]) affected |= [resolved hasPrefix:[target hasSuffix:@"/"] ? target : [target stringByAppendingString:@"/"]];
			}
			if(affected) { [self showError:@"Save your editor changes before running this Git action."]; return; }
		}
	}
	NSString* directory = self.directory;
	_busy = YES;
	++_generation;
	_refreshing = NO;
	_status.stringValue = @"Running Git…";
	[_table reloadData];
	[self updateControls];
	__weak SourceControlViewController* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString* error = execute();
		dispatch_async(dispatch_get_main_queue(), ^{
			SourceControlViewController* controller = weakSelf;
			if(!controller) return;
			controller->_busy = NO;
			if([controller.directory isEqual:directory]) {
				if(error) [controller showError:error];
				else if(action == GitRepositoryStage || action == GitRepositoryUnstage) controller->_waitingForIndex = YES;
				else if(action == GitRepositoryCommit) {
					if(controller->_pin.state != NSControlStateValueOn) {
						controller->_message.stringValue = @"";
						[controller setDescriptionText:@""];
						[controller setDescriptionExpanded:NO];
					}
					controller->_amendHead = nil;
					controller->_amend.state = NSControlStateValueOff;
					// Wait for the new index and HEAD before enabling another commit.
					controller->_snapshot = nil;
				}
			}
			[controller->_table reloadData];
			[controller updateControls];
			[controller refresh:nil];
			if(controller.repositoryDidChange && (action >= GitRepositorySync || ((!error && action >= GitRepositoryCommit) || action == GitRepositoryApplyStash || action == GitRepositoryDropStash)))
				controller.repositoryDidChange();
		});
	});
}

- (void)showError:(NSString*)error
{
	_status.stringValue = error;
	_status.toolTip = error;
	_emptyStatusHeight.active = NO;
	if(!self.view.window || !self.panelVisible) return;
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = @"Git action could not finish";
	alert.informativeText = error;
	[alert beginSheetModalForWindow:self.view.window completionHandler:nil];
}
@end
