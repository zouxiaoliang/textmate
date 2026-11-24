#import "GitWorkspaceViewController.h"
#import "GitDiffView.h"
#import "GitGraphTracksView.h"
#import "GitRevisionView.h"
#import "GitWorkspaceData.h"
#import "GitWorkspacePanes.h"
#import "SourceControlViewController.h"
#if HAVE_OAK_SWIFTUI
#import "OakSwiftUI-Swift.h"
#else
#import <OakFilterList/OakChooser.h>
#endif
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <cmath>

namespace
{
constexpr NSUInteger historyPage = 100;
constexpr CGFloat historyCommitHeight = 25, historyMonthHeight = 34;
constexpr CGFloat navigationMinimum = 175, changesMinimum = 225, previewMinimum = 265;
constexpr CGFloat navigationShare = 0.206, changesShare = 0.272;
NSString* const branchIcon = @"git-branch";

enum RevisionMenuAction {
	CopyRevision, CopyRevisionInfo, RevealRevision, CheckOutRevision, ResetRevision, RevertRevision, CherryPickRevision,
	CreateBranchAtRevision, CreateTagAtRevision, SaveRevisionPatch, ExportRevision, CompareRevision,
	CheckOutBranch, CheckOutWorktree, RenameBranch, DeleteReference, ArchiveBranch, TrackBranch,
	PinBranch, SkipAutoArchive, HideMergedHint, SetBranchUpstream, SetBranchParent, CreateStackedBranch,
	PublishBranch, PushBranchTo, ForcePushBranchWithLease, CreatePullRequestFromBranch,
};

NSImage* BranchImage()
{
	static NSImage* image;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		image = [NSImage imageWithSize:NSMakeSize(15, 15) flipped:NO drawingHandler:^BOOL(NSRect rect){
			NSBezierPath* path = [NSBezierPath bezierPath];
			path.lineWidth = 1.15;
			[path moveToPoint:NSMakePoint(4.5, 4.65)];
			[path lineToPoint:NSMakePoint(4.5, 10.35)];
			[path moveToPoint:NSMakePoint(4.5, 5.8)];
			[path curveToPoint:NSMakePoint(10.5, 10.35) controlPoint1:NSMakePoint(7.8, 5.8) controlPoint2:NSMakePoint(10.5, 7.6)];
			for(NSPoint center : {NSMakePoint(4.5, 3), NSMakePoint(4.5, 12), NSMakePoint(10.5, 12)})
				[path appendBezierPathWithOvalInRect:NSMakeRect(center.x-1.65, center.y-1.65, 3.3, 3.3)];
			[NSColor.blackColor setStroke];
			[path stroke];
			return YES;
		}];
		[image setTemplate:YES];
	});
	return image;
}

enum class ToolbarIcon { QuickActions, Fetch, Pull, Push, Sync, Merge, Rebase, ApplyStash, SaveStash, Refresh };

NSButton* ToolbarButton(ToolbarIcon icon, NSString* label, id target, SEL action)
{
	NSImage* image = [NSImage imageWithSize:NSMakeSize(20, 20) flipped:YES drawingHandler:^BOOL(NSRect rect){
		NSBezierPath* path = [NSBezierPath bezierPath];
		path.lineWidth = 1.35;
		path.lineCapStyle = NSLineCapStyleRound;
		path.lineJoinStyle = NSLineJoinStyleRound;
		[NSColor.blackColor set];
		auto move = [&](CGFloat x, CGFloat y){ [path moveToPoint:NSMakePoint(x, y)]; };
		auto line = [&](CGFloat x, CGFloat y){ [path lineToPoint:NSMakePoint(x, y)]; };
		auto curve = [&](CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2, CGFloat x, CGFloat y){
			[path curveToPoint:NSMakePoint(x, y) controlPoint1:NSMakePoint(x1, y1) controlPoint2:NSMakePoint(x2, y2)];
		};
		switch(icon) {
			case ToolbarIcon::QuickActions:
				move(6.1, 5.4); line(17.7, 17); [path stroke]; [path removeAllPoints];
				for(NSRect spark : {NSMakeRect(13.9, 4.2, 3.5, 3.5), NSMakeRect(4.4, 12.7, 2.75, 2.75), NSMakeRect(7.1, 15.8, 1.65, 1.65)}) {
					CGFloat x = spark.origin.x, y = spark.origin.y, r = spark.size.width;
					move(x, y-r); line(x+r*0.28, y-r*0.28); line(x+r, y); line(x+r*0.28, y+r*0.28);
					line(x, y+r); line(x-r*0.28, y+r*0.28); line(x-r, y); line(x-r*0.28, y-r*0.28); [path closePath];
				}
				[path fill];
				break;
			case ToolbarIcon::Fetch:
			case ToolbarIcon::Pull:
			case ToolbarIcon::Push:
			case ToolbarIcon::Sync: {
				// Rotate the pull shape to make Push, and pair smaller copies for Sync.
				auto bend = [&](CGFloat x, CGFloat y, CGFloat scale, BOOL rotate){
					auto point = [&](CGFloat u, CGFloat v){ return NSMakePoint(x+scale*(rotate ? 20-u : u), y+scale*(rotate ? 20-v : v)); };
					[path moveToPoint:point(2.2, 5.3)];
					[path lineToPoint:point(5.4, 8.1)];
					[path curveToPoint:point(17.9, 8.6) controlPoint1:point(9.3, 3.8) controlPoint2:point(13.9, 3.5)];
					[path curveToPoint:point(9.2, 11.7) controlPoint1:point(14.9, 7.9) controlPoint2:point(11.7, 9.2)];
					[path lineToPoint:point(12.1, 14.7)];
					[path lineToPoint:point(2.1, 15.2)];
					[path closePath];
				};
				if(icon == ToolbarIcon::Sync) {
					bend(0.2, -0.2, 0.69, NO);
					bend(6, 6.4, 0.69, YES);
				} else bend(0, 0, 1, icon == ToolbarIcon::Push);
				if(icon != ToolbarIcon::Fetch) [path fill];
				[path stroke];
				break;
			}
			case ToolbarIcon::Merge:
			case ToolbarIcon::Rebase: {
				CGFloat x = icon == ToolbarIcon::Merge ? 7.6 : 10;
				move(x, 5.9); line(x, 13.9);
				if(icon == ToolbarIcon::Merge) {
					move(13.8, 17.8); line(13.8, 13.5); curve(13.8, 10.1, x, 10.9, x, 7.9);
				}
				[path appendBezierPathWithOvalInRect:NSMakeRect(x-2.1, 13.9, 4.2, 4.2)];
				[path stroke]; [path removeAllPoints];
				move(x-2.7, 5.9); line(x, 1.9); line(x+2.7, 5.9); [path closePath]; [path fill];
				break;
			}
			case ToolbarIcon::ApplyStash:
			case ToolbarIcon::SaveStash: {
				[path appendBezierPathWithRoundedRect:NSMakeRect(2.5, 3.5, 15, 14.5) xRadius:1.4 yRadius:1.4];
				BOOL down = icon == ToolbarIcon::ApplyStash;
				CGFloat tip = down ? 14.7 : 8.6, shoulder = down ? tip-2.5 : tip+2.5;
				move(10, down ? 8.6 : 14.7); line(10, tip);
				move(7.5, shoulder); line(10, tip); line(12.5, shoulder);
				[path stroke]; [path removeAllPoints];
				[path appendBezierPathWithRoundedRect:NSMakeRect(6.6, 1.6, 6.8, 5) xRadius:1.05 yRadius:1.05];
				[path fill];
				break;
			}
			case ToolbarIcon::Refresh:
				move(16.8, 11.3); curve(16.8, 15.1, 13.8, 18.1, 10, 18.1);
				curve(6.2, 18.1, 3.2, 15.1, 3.2, 11.3); curve(3.2, 7.5, 6.2, 4.5, 10, 4.5);
				line(12.9, 4.5);
				move(9.6, 1.1); line(13.1, 4.5); line(9.6, 8);
				[path stroke];
				break;
		}
		return YES;
	}];
	[image setTemplate:YES];
	NSButton* button = [NSButton buttonWithImage:image target:target action:action];
	button.bezelStyle = NSBezelStyleAccessoryBarAction;
	button.bordered = NO;
	button.toolTip = label;
	button.accessibilityLabel = label;
	return button;
}

CGFloat PreviewMinimum(NSSplitView* split)
{
	return MIN(previewMinimum, MAX(0, NSWidth(split.bounds)-2*split.dividerThickness-navigationMinimum-changesMinimum));
}

NSColor* WorkspaceColor(NSColor* light, CGFloat red, CGFloat green, CGFloat blue)
{
	NSColor* dark = [NSColor colorWithSRGBRed:red green:green blue:blue alpha:1];
	return [NSColor colorWithName:nil dynamicProvider:^NSColor*(NSAppearance* appearance){
		return [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqual:NSAppearanceNameDarkAqua] ? dark : light;
	}];
}

NSColor* SidebarColor()
{
	return WorkspaceColor(NSColor.underPageBackgroundColor, 0.168, 0.172, 0.176);
}

void FillView(NSView* child, NSView* parent)
{
	child.translatesAutoresizingMaskIntoConstraints = NO;
	[parent addSubview:child];
	[NSLayoutConstraint activateConstraints:@[
		[child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor], [child.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor],
		[child.topAnchor constraintEqualToAnchor:parent.topAnchor], [child.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor],
	]];
}

NSDictionary* NavigationItem(NSString* identifier, NSString* name, NSString* icon, NSString* mode)
{
	return @{ @"id": identifier, @"name": name, @"icon": icon, @"mode": mode };
}

NSDictionary* NavigationGroup(NSString* name, NSString* identifier, NSArray* children)
{
	return @{ @"id": identifier, @"name": name, @"children": children, @"section": @YES };
}

NSArray* NavigationPath(NSArray* items, NSString* identifier)
{
	for(NSDictionary* item in items) {
		if([item[@"id"] isEqual:identifier]) return @[item];
		if(NSArray* path = NavigationPath(item[@"children"], identifier)) return [@[item] arrayByAddingObjectsFromArray:path];
	}
	return nil;
}

void AddReference(NSMutableArray* items, NSString* ref, NSString* path, NSString* prefix, NSString* icon, BOOL groupPaths, NSString* headRef, NSString* headBadge, NSSet* merged)
{
	NSRange separator = [path rangeOfString:@"/"];
	if(groupPaths && separator.location != NSNotFound) {
		NSString* name = [path substringToIndex:separator.location];
		NSString* identifier = [prefix stringByAppendingFormat:@"%@/", name];
		NSMutableArray* children = nil;
		for(NSDictionary* candidate in items) if([candidate[@"id"] isEqual:identifier]) { children = candidate[@"children"]; break; }
		if(!children) {
			children = [NSMutableArray array];
			[items addObject:@{ @"id": identifier, @"name": name, @"icon": [prefix isEqual:@"refs/remotes/"] ? @"folder.badge.gearshape" : @"folder", @"children": children }];
		}
		AddReference(children, ref, [path substringFromIndex:NSMaxRange(separator)], identifier, icon, YES, headRef, headBadge, merged);
		return;
	}
	NSMutableDictionary* item = [NavigationItem(ref, path, icon, @"history") mutableCopy];
	item[@"ref"] = ref;
	NSRange categoryEnd = [ref rangeOfString:@"/" options:0 range:NSMakeRange(5, ref.length-5)];
	item[@"title"] = [ref substringFromIndex:NSMaxRange(categoryEnd)];
	if([ref isEqual:headRef]) item[@"badge"] = headBadge;
	else if([merged containsObject:ref]) item[@"badge"] = @"Merged";
	[items addObject:item];
}

NSString* HeadBadge(NSString* tracking)
{
	NSMutableString* badge = [@"HEAD" mutableCopy];
	for(NSArray* pair in @[@[@"ahead ", @"↑"], @[@"behind ", @"↓"]]) {
		NSRange range = [tracking rangeOfString:pair[0] options:NSBackwardsSearch];
		if(tracking && range.location != NSNotFound) {
			NSInteger count = [[tracking substringFromIndex:NSMaxRange(range)] integerValue];
			if(count > 0) [badge appendFormat:@" %@%ld", pair[1], (long)count];
		}
	}
	return badge;
}
}

@interface GitWorkspaceSurface : NSView
@property (nonatomic) NSColor* fillColor;
@end

@implementation GitWorkspaceSurface
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect
{
	[self.fillColor setFill];
	NSRectFill(NSIntersectionRect(dirtyRect, self.bounds));
}
@end

@interface GitWorkspaceTitleBar : NSView
@property (nonatomic) CGFloat navigationWidth;
@property (nonatomic) CGFloat leadingControlsEnd;
@property (nonatomic) NSView* repositoryItems;
@property (nonatomic, copy) NSArray<NSButton*>* sidebarButtons;
@property (nonatomic, copy) void (^arrangeRepositoryItems)(NSSize size);
@end

@implementation GitWorkspaceTitleBar
- (void)layout
{
	CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
	if(width <= 0 || height <= 0) { [super layout]; return; }
	CGFloat boundary = MIN(width, self.navigationWidth);
	self.repositoryItems.frame = NSMakeRect(boundary, 0, width-boundary, height);
	CGFloat x = boundary-8;
	for(NSButton* button in self.sidebarButtons.reverseObjectEnumerator) {
		BOOL fits = x-26 >= self.leadingControlsEnd;
		button.hidden = !fits;
		if(fits) { x -= 26; button.frame = NSMakeRect(x, (height-24)/2, 26, 24); }
	}
	if(self.arrangeRepositoryItems) self.arrangeRepositoryItems(self.repositoryItems.frame.size);
	[super layout];
}

- (void)drawRect:(NSRect)dirtyRect
{
	CGFloat boundary = MIN(NSWidth(self.bounds), self.navigationWidth);
	NSRect nav = NSMakeRect(0, 0, boundary, NSHeight(self.bounds));
	NSRect tools = NSMakeRect(boundary, 0, NSWidth(self.bounds)-boundary, NSHeight(self.bounds));
	[SidebarColor() setFill];
	NSRectFill(NSIntersectionRect(nav, dirtyRect));
	[WorkspaceColor(NSColor.controlBackgroundColor, 0.225, 0.230, 0.231) setFill];
	NSRectFill(NSIntersectionRect(tools, dirtyRect));
	[NSColor.separatorColor setFill];
	NSRectFillUsingOperation(NSMakeRect(boundary, 0, 1, NSHeight(self.bounds)), NSCompositingOperationSourceOver);
	NSRectFillUsingOperation(NSMakeRect(boundary, 0, NSWidth(tools), 1), NSCompositingOperationSourceOver);
}

- (NSView*)hitTest:(NSPoint)point
{
	NSView* hit = [super hitTest:point];
	for(NSView* ancestor = hit; ancestor && ancestor != self; ancestor = ancestor.superview)
		if([ancestor isKindOfClass:NSControl.class] && ![ancestor isKindOfClass:NSTextField.class]) return hit;
		else if([ancestor isKindOfClass:NSTextField.class] && ((NSTextField*)ancestor).isEditable) return hit;
	return nil;
}
@end

@interface GitWorkspaceNavigationRow : NSTableRowView
@end
@implementation GitWorkspaceNavigationRow
- (void)drawSelectionInRect:(NSRect)dirtyRect
{
	if(self.selectionHighlightStyle == NSTableViewSelectionHighlightStyleNone) return;
	[WorkspaceColor(NSColor.selectedContentBackgroundColor, 0.365, 0.373, 0.377) setFill];
	[[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 3, 0) xRadius:5 yRadius:5] fill];
}
@end

@interface GitStashListRow : NSTableRowView
@property (nonatomic) BOOL separatesNextRow;
@end

@implementation GitStashListRow
- (void)drawSelectionInRect:(NSRect)dirtyRect
{
	if(self.selectionHighlightStyle == NSTableViewSelectionHighlightStyleNone) return;
	[WorkspaceColor(NSColor.unemphasizedSelectedContentBackgroundColor, 0.263, 0.267, 0.271) setFill];
	[[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 10, 0) xRadius:5 yRadius:5] fill];
}
- (void)drawBackgroundInRect:(NSRect)dirtyRect
{
	[super drawBackgroundInRect:dirtyRect];
	if(self.selected || !self.separatesNextRow) return;
	[NSColor.separatorColor setFill];
	CGFloat y = self.isFlipped ? NSMaxY(self.bounds)-1 : NSMinY(self.bounds);
	NSRectFillUsingOperation(NSMakeRect(36, y, MAX(0, NSWidth(self.bounds)-52), 1), NSCompositingOperationSourceOver);
}
@end

@interface GitHistoryMonthRow : NSTableRowView
@end
@implementation GitHistoryMonthRow
- (void)drawBackgroundInRect:(NSRect)dirtyRect { }
- (void)drawSelectionInRect:(NSRect)dirtyRect { }
- (void)drawSeparatorInRect:(NSRect)dirtyRect { }
@end

static NSString* const QuickActionPlaceholder = @"Search actions, branches, and tags…";

static NSArray<NSDictionary*>* QuickActionSuggestions(NSString* query)
{
	if(!query.length) return @[];
	NSMutableArray* matches = [NSMutableArray array];
	if(query.length >= 4 && [query rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location == NSNotFound)
		[matches addObject:@{ @"name": [NSString stringWithFormat:@"Find Commit %@", query], @"query": query, @"scope": @(GitHistorySearchHash) }];
	[matches addObject:@{ @"name": [NSString stringWithFormat:@"Show History for File: %@", query], @"query": query, @"scope": @(GitHistorySearchFile) }];
	return matches;
}

#if HAVE_OAK_SWIFTUI
static NSArray<OakCommandPaletteItem*>* QuickActionPaletteItems(NSArray<NSDictionary*>* entries)
{
	NSMutableArray* items = [NSMutableArray arrayWithCapacity:entries.count];
	for(NSDictionary* entry in entries) {
		NSString* name = entry[@"name"];
		OakCommandPaletteItem* item = [[OakCommandPaletteItem alloc] initWithTitle:name subtitle:@"" keyEquivalent:@""
			category:OakCommandPaletteCategoryMenuAction actionIdentifier:name];
		item.representedObject = entry;
		if(entry[@"checkout"]) item.icon = BranchImage();
		[items addObject:item];
	}
	return items;
}
#else
@interface GitQuickActionsPanel : NSPanel
@end

@implementation GitQuickActionsPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface GitQuickActions : OakChooser
@property (nonatomic, copy) NSArray<NSDictionary*>* entries;
- (void)showInWindow:(NSWindow*)parent;
@end

@implementation GitQuickActions
- (instancetype)init
{
	NSPanel* panel = [[GitQuickActionsPanel alloc] initWithContentRect:NSMakeRect(0, 0, 480, 400)
		styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
	if((self = [super initWithWindow:panel])) {
		panel.frameAutosaveName = @"";
		panel.hasShadow = YES;
		self.searchField.placeholderString = QuickActionPlaceholder;
		NSView* content = panel.contentView;
		self.searchField.bordered = NO;
		self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
		[content addSubview:self.searchField];
		self.scrollView.contentInsets = NSEdgeInsetsMake(34, 0, 0, 0);
		self.scrollView.automaticallyAdjustsContentInsets = NO;
		[NSLayoutConstraint activateConstraints:@[
			[self.searchField.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
			[self.searchField.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
			[self.searchField.topAnchor constraintEqualToAnchor:content.topAnchor constant:8],
		]];
		panel.initialFirstResponder = self.searchField;
	}
	return self;
}
- (void)showInWindow:(NSWindow*)parent
{
	NSRect frame = parent.frame;
	CGFloat width = MIN(MAX(NSWidth(frame)*0.5, 400), 700);
	CGFloat height = MIN(NSHeight(frame)-16, 400);
	[self.window setFrame:NSMakeRect(NSMidX(frame)-width/2, NSMaxY(frame)-height-MIN(72, NSHeight(frame)-height-8), width, height) display:NO];
	[parent addChildWindow:self.window ordered:NSWindowAbove];
	[self.window makeKeyAndOrderFront:nil];
	[self.window makeFirstResponder:self.searchField];
}
- (void)close
{
	[self.window.parentWindow removeChildWindow:self.window];
	[super close];
}
- (void)windowDidResignKey:(NSNotification*)notification { if(self.window.parentWindow) [self close]; }
- (void)cancel:(id)sender
{
	NSWindow* parent = self.window.parentWindow;
	[self close];
	[parent makeKeyWindow];
}
- (void)accept:(id)sender
{
	if(!self.selectedItems.count) return;
	[self cancel:sender];
	[NSApp sendAction:self.action to:self.target from:self];
}
- (void)updateItems:(id)sender
{
	NSString* query = [self.filterString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if(!query.length) { self.items = self.entries; return; }
	NSMutableArray* matches = [[self.entries filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary* entry, NSDictionary* bindings){
		return [entry[@"name"] localizedCaseInsensitiveContainsString:query];
	}]] mutableCopy];
	[matches addObjectsFromArray:QuickActionSuggestions(query)];
	self.items = matches;
}
@end
#endif

@interface GitWorkspaceViewController () <NSSplitViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate>
@end

@implementation GitWorkspaceViewController
{
	SourceControlViewController* _workingCopy;
	NSSplitView* _split;
	NSOutlineView* _navigation;
	GitWorkspaceTitleBar* _workspaceTitleBar;
	NSSearchField* _search;
	NSTextField* _projectName;
	NSTextField* _projectStatus;
	NSButton* _revealRepository;
	NSButton* _back;
	NSButton* _forward;
	NSButton* _quickActionsButton;
#if HAVE_OAK_SWIFTUI
	OakCommandPalette* _quickActions;
#else
	GitQuickActions* _quickActions;
#endif
	NSMenu* _historySearchMenu;
	NSString* _historyQuery;
	NSString* _pendingHistorySelection;
	GitHistorySearch _historySearchScope;
	NSUInteger _searchGeneration;
	NSDictionary<NSNumber*, NSButton*>* _operationButtons;
	NSButton* _stashShortcut;
	NSButton* _sidebarCreateBranch;
	NSMutableArray<NSString*>* _backDestinations;
	NSMutableArray<NSString*>* _forwardDestinations;
	NSMutableSet<NSString*>* _seenFolders;
	NSSet<NSString*>* _mergedRefs;
	NSDictionary<NSString*, NSDictionary*>* _branchPreferences;
	NSView* _history;
	NSTableView* _historyTable;
	NSTextField* _historyTitle;
	NSTextField* _historyStatus;
	NSButton* _loadMore;
	NSButton* _historyOptions;
	NSView* _historyFooter;
	NSLayoutConstraint* _historyListTop;
	NSLayoutConstraint* _historyListBottom;
	NSLayoutConstraint* _historyFooterBottom;
	BOOL _hideHistoryGraph;
	GitDiffView* _diff;
	NSView* _workspacePages;
	GitWorkspaceReviewPane* _pullRequests;
	GitWorkspaceReviewPane* _branchesReview;
	GitWorkspaceSettingsPane* _repositorySettings;
	NSView* _emptyPreview;
	NSTextField* _emptyTitle;
	NSArray* _navigationItems;
	NSArray<NSString*>* _references;
	NSArray<NSDictionary*>* _commits;
	NSArray<NSDictionary*>* _historyRows;
	CGFloat _graphWidth;
	GitRevisionView* _revisionInspector;
	NSSegmentedControl* _workingDiffTabs;
	NSPopUpButton* _diffContext;
	NSButton* _ignoreDiffWhitespace;
	NSButton* _showCompleteDiff;
	NSDictionary* _workingDiffSnapshot;
	NSDictionary* _workingDiffBuffers;
	NSString* _stashQuery;
	NSDictionary* _snapshot;
	NSDictionary* _destination;
	NSDictionary* _activeWorkingChange;
	NSDictionary* _displayedWorkingChange;
	NSString* _historyRoot;
	NSUInteger _fileCount;
	NSUInteger _stashCount;
	NSUInteger _navigationGeneration;
	NSUInteger _historyGeneration;
	NSUInteger _previewGeneration;
	NSUInteger _historyLimit;
	NSUInteger _historyTotal;
	BOOL _rebuildingNavigation;
	BOOL _updatingHistory;
	BOOL _historyLoaded;
	BOOL _historyHasMore;
	BOOL _stashDiffRunning;
	BOOL _navigatingHistory;
	CGFloat _navigationFraction;
	CGFloat _changesFraction;
	CGFloat _lastNavigationWidth;
	CGFloat _lastChangesWidth;
	BOOL _changingPaneWidth;
	NSMutableDictionary<NSString*,NSNumber*>* _paneSizes;
}

- (void)loadView
{
	_historyLimit = historyPage;
	_navigationFraction = navigationShare;
	_changesFraction = changesShare;
	_backDestinations = [NSMutableArray array];
	_forwardDestinations = [NSMutableArray array];
	_seenFolders = [NSMutableSet set];
	_paneSizes = [NSMutableDictionary dictionary];
	GitWorkspaceSurface* content = [[GitWorkspaceSurface alloc] initWithFrame:NSMakeRect(0, 0, 1140, 680)];
	content.fillColor = WorkspaceColor(NSColor.windowBackgroundColor, 0.145, 0.153, 0.157);
	content.clipsToBounds = YES;
	self.view = content;
	_titleBarItems = [self buildTitleBarItems];
	_split = [[NSSplitView alloc] initWithFrame:content.bounds];
	_split.vertical = YES;
	_split.dividerStyle = NSSplitViewDividerStyleThin;
	_split.delegate = self;
	NSView* navigation = [self buildNavigation];
	NSView* work = [self buildWorkPaneWithBackgroundColor:content.fillColor];
	NSView* preview = [self buildPreview];
	navigation.frame = NSMakeRect(0, 0, 235, 680);
	work.frame = NSMakeRect(236, 0, 310, 680);
	preview.frame = NSMakeRect(547, 0, 593, 680);
	for(NSView* pane in @[navigation, work, preview]) [_split addSubview:pane];
	[_split setHoldingPriority:NSLayoutPriorityDefaultHigh+1 forSubviewAtIndex:0];
	[_split setHoldingPriority:NSLayoutPriorityDefaultHigh forSubviewAtIndex:1];
	[_split setHoldingPriority:NSLayoutPriorityDefaultLow forSubviewAtIndex:2];
	FillView(_split, content);
	[self buildWorkspacePages];
	[self updateTitleBarWidth];
	_workingCopy.directory = _directory;
	[self rebuildNavigation];
}

- (NSView*)buildTitleBarItems
{
	_workspaceTitleBar = [[GitWorkspaceTitleBar alloc] initWithFrame:NSZeroRect];
	_workspaceTitleBar.clipsToBounds = YES;
	NSView* repositoryItems = [[NSView alloc] initWithFrame:NSZeroRect];
	_workspaceTitleBar.repositoryItems = repositoryItems;
	[_workspaceTitleBar addSubview:repositoryItems];
	_workspaceTitleBar.sidebarButtons = @[
		GitIconButton(@"internaldrive", @"Show Working Copy", self, @selector(openWorkingCopy:)),
		GitIconButton(@"clock.arrow.circlepath", @"Show History", self, @selector(openHistory:)),
	];
	for(NSButton* button in _workspaceTitleBar.sidebarButtons) [_workspaceTitleBar addSubview:button];

	_revealRepository = GitIconButton(@"folder", @"Reveal Repository in Finder", self, @selector(revealRepository:));
	_back = GitIconButton(@"chevron.left", @"Go Back in Git Workspace", self, @selector(goBack:));
	_forward = GitIconButton(@"chevron.right", @"Go Forward in Git Workspace", self, @selector(goForward:));
	NSStackView* navigation = [NSStackView stackViewWithViews:@[_revealRepository, _back, _forward]];
	navigation.spacing = 7;
	_projectName = GitLabel(@"Git Workspace", 13, NSFontWeightSemibold);
	_projectStatus = GitLabel(@"Working Copy", 11, NSFontWeightRegular);
	_projectStatus.textColor = NSColor.secondaryLabelColor;
	_projectStatus.lineBreakMode = NSLineBreakByTruncatingTail;
	NSStackView* title = [NSStackView stackViewWithViews:@[_projectName, _projectStatus]];
	title.orientation = NSUserInterfaceLayoutOrientationVertical;
	title.alignment = NSLayoutAttributeLeading;
	title.spacing = 1;
	for(NSView* label in @[_projectName, _projectStatus]) [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

	NSMutableDictionary* operationButtons = [NSMutableDictionary dictionary];
	NSMutableArray<NSButton*>* operations = [NSMutableArray array];
	struct { GitRepositoryAction action; ToolbarIcon icon; NSString* label; } const toolbarOperations[] = {
		{GitRepositoryFetch, ToolbarIcon::Fetch, @"Fetch"},
		{GitRepositoryPull, ToolbarIcon::Pull, @"Pull"},
		{GitRepositoryPush, ToolbarIcon::Push, @"Push"},
		{GitRepositorySync, ToolbarIcon::Sync, @"Sync"},
		{GitRepositoryMerge, ToolbarIcon::Merge, @"Merge"},
		{GitRepositoryRebase, ToolbarIcon::Rebase, @"Rebase"},
		{GitRepositoryApplyStash, ToolbarIcon::ApplyStash, @"Apply Stash"},
		{GitRepositorySaveStash, ToolbarIcon::SaveStash, @"Save Stash"},
	};
	for(auto const& operation : toolbarOperations) {
		NSButton* button = ToolbarButton(operation.icon, operation.label, self, @selector(runOperation:));
		button.tag = operation.action;
		operationButtons[@(operation.action)] = button;
		[operations addObject:button];
	}
	_operationButtons = operationButtons;
	_quickActionsButton = ToolbarButton(ToolbarIcon::QuickActions, @"Quick Actions", self, @selector(openQuickActions:));
	_quickActionsButton.keyEquivalent = @"a";
	_quickActionsButton.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
	NSButton* refresh = ToolbarButton(ToolbarIcon::Refresh, @"Refresh Git Workspace", self, @selector(refresh:));
	_search = [[NSSearchField alloc] init];
	_search.placeholderString = @"Search for File";
	_search.accessibilityLabel = @"Filter changed files";
	_search.delegate = self;
	_search.target = self;
	_search.action = @selector(searchChanged:);
	_historySearchMenu = [[NSMenu alloc] initWithTitle:@"Search History"];
	for(NSString* label in @[@"Message", @"Author", @"Hash", @"File"]) {
		NSInteger index = _historySearchMenu.numberOfItems;
		NSMenuItem* item = [_historySearchMenu addItemWithTitle:label action:@selector(changeHistorySearchScope:) keyEquivalent:@""];
		item.target = self;
		item.tag = index;
		item.state = index == 0 ? NSControlStateValueOn : NSControlStateValueOff;
	}
	NSArray* commandButtons = [@[_quickActionsButton] arrayByAddingObjectsFromArray:[operations arrayByAddingObject:refresh]];
	NSStackView* commands = [NSStackView stackViewWithViews:[commandButtons arrayByAddingObject:_search]];
	commands.spacing = 7;
	NSLayoutConstraint* searchWidth = [_search.widthAnchor constraintEqualToConstant:220];
	searchWidth.priority = NSLayoutPriorityDefaultHigh - 1;
	// The frame-based title bar can briefly have zero width while AppKit installs
	// its constraints. Let the tools extend past the clipped edge until it lays out.
	NSLayoutConstraint* commandsTrailing = [commands.trailingAnchor constraintEqualToAnchor:repositoryItems.trailingAnchor constant:-12];
	commandsTrailing.priority = NSLayoutPriorityRequired - 1;
	for(NSView* item in @[navigation, title, commands]) {
		item.translatesAutoresizingMaskIntoConstraints = NO;
		[repositoryItems addSubview:item];
	}
	for(NSView* button in [navigation.arrangedSubviews arrayByAddingObjectsFromArray:commandButtons]) [button.widthAnchor constraintEqualToConstant:24].active = YES;
	[NSLayoutConstraint activateConstraints:@[
		[navigation.leadingAnchor constraintEqualToAnchor:repositoryItems.leadingAnchor constant:12], [navigation.centerYAnchor constraintEqualToAnchor:repositoryItems.centerYAnchor],
		[title.leadingAnchor constraintEqualToAnchor:navigation.trailingAnchor constant:10], [title.centerYAnchor constraintEqualToAnchor:repositoryItems.centerYAnchor],
		[title.widthAnchor constraintGreaterThanOrEqualToConstant:0], [commands.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:12],
		commandsTrailing, [commands.centerYAnchor constraintEqualToAnchor:repositoryItems.centerYAnchor],
		[_search.widthAnchor constraintGreaterThanOrEqualToConstant:105], searchWidth,
	]];
	__weak GitWorkspaceViewController* weakSelf = self;
	_workspaceTitleBar.arrangeRepositoryItems = ^(NSSize size){ [weakSelf arrangeTitleBarForSize:size]; };
	return _workspaceTitleBar;
}

- (void)arrangeTitleBarForSize:(NSSize)size
{
	_projectStatus.hidden = size.height < 34;
	_search.controlSize = size.height < 34 ? NSControlSizeSmall : NSControlSizeRegular;
	_revealRepository.hidden = size.width < 410;
	for(NSNumber* action in _operationButtons) {
		CGFloat minimum = 740;
		if(action.integerValue == GitRepositoryPull || action.integerValue == GitRepositoryPush) minimum = 580;
		else if(action.integerValue == GitRepositoryFetch) minimum = 630;
		_operationButtons[action].hidden = size.width < minimum;
	}
}

- (void)layoutTitleBarAfterLeadingControls:(CGFloat)leadingControlsEnd
{
	_workspaceTitleBar.leadingControlsEnd = leadingControlsEnd;
	[_workspaceTitleBar setNeedsLayout:YES];
}

- (void)updateTitleBarWidth
{
	if(!_split.subviews.count) return;
	_workspaceTitleBar.navigationWidth = NSWidth(_split.subviews.firstObject.frame);
	CGFloat leading = _workspaceTitleBar.navigationWidth + _split.dividerThickness;
	_workspacePages.frame = NSMakeRect(leading, 0, MAX(0, NSWidth(_split.frame)-leading), NSHeight(_split.frame));
	[_workspaceTitleBar setNeedsLayout:YES];
	[_workspaceTitleBar setNeedsDisplay:YES];
}

- (void)buildWorkspacePages
{
	_workspacePages = [[GitWorkspaceSurface alloc] init];
	((GitWorkspaceSurface*)_workspacePages).fillColor = ((GitWorkspaceSurface*)self.view).fillColor;
	_workspacePages.clipsToBounds = YES;
	_workspacePages.hidden = YES;
	[self.view addSubview:_workspacePages];
	_pullRequests = [[GitWorkspaceReviewPane alloc] initWithPullRequests:YES];
	_branchesReview = [[GitWorkspaceReviewPane alloc] initWithPullRequests:NO];
	_pullRequests.softWrap = _branchesReview.softWrap = self.softWrap;
	_repositorySettings = [[GitWorkspaceSettingsPane alloc] init];
	__weak GitWorkspaceViewController* weakSelf = self;
	BOOL (^canChangeWorkingTree)(void) = ^BOOL{
		GitWorkspaceViewController* controller = weakSelf;
		return controller && (!controller.bufferProvider || !controller.bufferProvider().count)
			&& [controller->_workingCopy canPerformAction:GitRepositorySwitchBranch] && !controller->_snapshot[@"toolbarContext"][@"integration"];
	};
	void (^didChange)(void) = ^{
		GitWorkspaceViewController* controller = weakSelf;
		if(!controller) return;
		[controller->_workingCopy refresh:nil];
		[controller refreshReferences];
		if(controller.repositoryDidChange) controller.repositoryDidChange();
	};
	for(GitWorkspaceReviewPane* page in @[_pullRequests, _branchesReview]) {
		page.canCheckOut = canChangeWorkingTree;
		page.repositoryDidChange = didChange;
	}
	_branchesReview.showHistory = ^(NSString* ref){ [weakSelf selectDestination:ref]; };
	_branchesReview.populateBranchMenu = ^(NSMenu* menu, NSDictionary* branch, NSArray<NSDictionary*>* refs, NSArray<NSDictionary*>* githubRemotes){
		[weakSelf populateBranchReviewMenu:menu branch:branch refs:refs githubRemotes:githubRemotes];
	};
	_repositorySettings.repositoryDidChange = didChange;
	_repositorySettings.canChangeWorkingTree = canChangeWorkingTree;
	_repositorySettings.hasUnsavedBuffer = ^BOOL(NSString* path){
		GitWorkspaceViewController* controller = weakSelf;
		return controller.bufferProvider && controller.bufferProvider()[ProjectChangesBufferAbsolutePath(path)] != nil;
	};
}

- (NSViewController*)activeWorkspacePage
{
	NSString* mode = _destination[@"mode"];
	if([mode isEqual:@"pullRequests"]) return _pullRequests;
	if([mode isEqual:@"branchesReview"]) return _branchesReview;
	if([mode isEqual:@"settings"]) return _repositorySettings;
	return nil;
}

- (void)refreshWorkspacePage
{
	NSViewController* page = [self activeWorkspacePage];
	if(!page || !self.isActive) return;
	NSString* root = _snapshot[@"root"];
	if(page == _repositorySettings) {
		_repositorySettings.repository = root;
		[_repositorySettings refresh];
	} else {
		GitWorkspaceReviewPane* review = (GitWorkspaceReviewPane*)page;
		review.repository = root;
		[review refresh];
	}
}

- (NSView*)buildNavigation
{
	GitWorkspaceSurface* sidebar = [[GitWorkspaceSurface alloc] init];
	sidebar.fillColor = SidebarColor();
	_navigation = [[GitOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 208, 633)];
	_navigation.style = NSTableViewStyleSourceList;
	_navigation.accessibilityLabel = @"Git repository navigation";
	_navigation.backgroundColor = NSColor.clearColor;
	_navigation.headerView = nil;
	_navigation.floatsGroupRows = NO;
	_navigation.rowHeight = 28;
	_navigation.indentationPerLevel = 12;
	_navigation.allowsEmptySelection = NO;
	_navigation.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"repository"];
	column.resizingMask = NSTableColumnAutoresizingMask;
	[_navigation addTableColumn:column];
	_navigation.outlineTableColumn = column;
	_navigation.dataSource = self;
	_navigation.delegate = self;
	_navigation.target = self;
	_navigation.doubleAction = @selector(checkOutClickedBranch:);
	_navigation.menu = [[NSMenu alloc] init];
	_navigation.menu.delegate = self;
	NSScrollView* scroll = GitScrollView(_navigation);
	NSBox* rule = [[NSBox alloc] init];
	rule.boxType = NSBoxSeparator;
	NSButton* collapse = GitIconButton(@"line.3.horizontal.decrease.circle", @"Expand or Collapse Branch Folders", self, @selector(toggleBranchFolders:));
	_stashShortcut = GitIconButton(@"archivebox", @"Show Stashes", self, @selector(openStashes:));
	_stashShortcut.title = @"";
	_stashShortcut.imagePosition = NSImageLeading;
	_stashShortcut.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
	NSButton* plus = GitIconButton(@"plus", @"Create Branch…", self, @selector(createBranch:));
	plus.enabled = NO;
	NSButton* actions = GitIconButton(@"slider.horizontal.3", @"Repository Actions", self, @selector(openRepositoryActions:));
	NSStackView* shortcuts = [NSStackView stackViewWithViews:@[_stashShortcut, plus, actions]];
	shortcuts.spacing = 6;
	for(NSView* item in @[scroll, rule, collapse, shortcuts]) {
		item.translatesAutoresizingMaskIntoConstraints = NO;
		[sidebar addSubview:item];
	}
	[NSLayoutConstraint activateConstraints:@[
		[scroll.topAnchor constraintEqualToAnchor:sidebar.topAnchor], [scroll.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
		[rule.topAnchor constraintEqualToAnchor:scroll.bottomAnchor], [rule.heightAnchor constraintEqualToConstant:1],
		[rule.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor], [rule.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
		[rule.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor constant:-29],
		[collapse.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:10], [collapse.widthAnchor constraintEqualToConstant:20],
		[shortcuts.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:-9],
		[collapse.centerYAnchor constraintEqualToAnchor:sidebar.bottomAnchor constant:-14], [shortcuts.centerYAnchor constraintEqualToAnchor:collapse.centerYAnchor],
		[plus.widthAnchor constraintEqualToConstant:20], [actions.widthAnchor constraintEqualToConstant:23],
	]];
	_sidebarCreateBranch = plus;
	return sidebar;
}

- (NSView*)buildWorkPaneWithBackgroundColor:(NSColor*)backgroundColor
{
	NSView* pane = [[NSView alloc] init];
	_workingCopy = [[SourceControlViewController alloc] init];
	_workingCopy.workspaceLayout = YES;
	_workingCopy.themeBackgroundColor = backgroundColor;
	__weak GitWorkspaceViewController* weakSelf = self;
	_workingCopy.bufferProvider = ^NSDictionary*{
		GitWorkspaceViewController* controller = weakSelf;
		return controller.bufferProvider ? controller.bufferProvider() : @{};
	};
	_workingCopy.didRefresh = ^(NSDictionary* snapshot, NSUInteger count){ [weakSelf updateWorkingCopy:snapshot count:count]; };
	_workingCopy.controlsDidChange = ^{ [weakSelf updateTitleBarActions]; };
	_workingCopy.previewChange = ^(NSDictionary* item, NSDictionary* snapshot, NSDictionary* buffers){ [weakSelf previewWorkingChange:item snapshot:snapshot buffers:buffers force:NO]; };
	_workingCopy.showDiff = ^(NSDictionary* item, NSDictionary* snapshot, NSDictionary* buffers){ [weakSelf previewWorkingChange:item snapshot:snapshot buffers:buffers force:YES]; };
	_workingCopy.showFileHistory = ^(NSString* path){ [weakSelf showHistoryOfPath:path]; };
	_workingCopy.repositoryDidChange = ^{
		GitWorkspaceViewController* controller = weakSelf;
		if(!controller) return;
		[controller refresh:nil];
		if(controller.repositoryDidChange) controller.repositoryDidChange();
	};
	FillView(_workingCopy.view, pane);
	_history = [self buildHistory];
	FillView(_history, pane);
	_history.hidden = YES;
	return pane;
}

- (NSView*)buildHistory
{
	NSView* pane = [[NSView alloc] init];
	_historyTitle = GitLabel(@"All Branches, Remotes, Tags", 13, NSFontWeightMedium);
	[_historyTitle setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[_historyTitle setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	_historyOptions = GitIconButton(@"slider.horizontal.3", @"History options", self, @selector(showHistoryOptions:));
	NSStackView* heading = [NSStackView stackViewWithViews:@[_historyTitle, _historyOptions]];
	heading.spacing = 8;
	NSView* header = GitPaneHeader(heading);
	_historyStatus = GitLabel(@"", 11, NSFontWeightRegular);
	_loadMore = [NSButton buttonWithTitle:@"Load More" target:self action:@selector(loadMore:)];
	_loadMore.enabled = NO;
	_historyFooter = GitPaneFooter(_historyStatus, _loadMore);
	_historyTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 327, 480)];
	_historyTable.style = NSTableViewStylePlain;
	_historyTable.backgroundColor = NSColor.clearColor;
	_historyTable.rowHeight = 42;
	_historyTable.intercellSpacing = NSZeroSize;
	_historyTable.floatsGroupRows = NO;
	_historyTable.headerView = nil;
	_historyTable.accessibilityLabel = @"Commits";
	_historyTable.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"commit"];
	column.resizingMask = NSTableColumnAutoresizingMask;
	[_historyTable addTableColumn:column];
	_historyTable.dataSource = self;
	_historyTable.delegate = self;
	_historyTable.menu = [[NSMenu alloc] init];
	_historyTable.menu.delegate = self;
	NSScrollView* list = GitScrollView(_historyTable);
	NSView* previous = nil;
	for(NSView* item in @[header, list, _historyFooter]) {
		item.translatesAutoresizingMaskIntoConstraints = NO;
		[pane addSubview:item];
		NSLayoutConstraint* top = [item.topAnchor constraintEqualToAnchor:previous ? previous.bottomAnchor : pane.topAnchor];
		if(item == list) _historyListTop = top;
		[NSLayoutConstraint activateConstraints:@[
			[item.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor], [item.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
			top,
		]];
		previous = item;
	}
	_historyFooterBottom = [_historyFooter.bottomAnchor constraintEqualToAnchor:pane.bottomAnchor];
	_historyListBottom = [list.bottomAnchor constraintEqualToAnchor:pane.bottomAnchor];
	_historyFooterBottom.active = YES;
	return pane;
}

- (NSView*)buildPreview
{
	NSView* pane = [[NSView alloc] init];
	_diff = [[GitDiffView alloc] initWithFrame:NSZeroRect];
	_workingDiffTabs = [NSSegmentedControl segmentedControlWithLabels:@[@"Staged", @"Unstaged"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(selectWorkingDiff:)];
	_workingDiffTabs.controlSize = NSControlSizeSmall;
	[_diff.headerControls addArrangedSubview:_workingDiffTabs];
	_ignoreDiffWhitespace = GitIconButton(@"circle.slash", @"Ignore whitespace changes", self, @selector(changeDiffDisplay:));
	_showCompleteDiff = GitIconButton(@"arrow.up.and.down.text.horizontal", @"Show complete file", self, @selector(changeDiffDisplay:));
	for(NSButton* button in @[_ignoreDiffWhitespace, _showCompleteDiff]) {
		[button setButtonType:NSButtonTypePushOnPushOff];
		[_diff.footerOptions addArrangedSubview:button];
	}
	_diffContext = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	_diffContext.controlSize = NSControlSizeSmall;
	_diffContext.bordered = NO;
	_diffContext.accessibilityLabel = @"Context lines";
	_diffContext.target = self;
	_diffContext.action = @selector(changeDiffDisplay:);
	for(NSUInteger lines : {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 25, 50}) {
		[_diffContext addItemWithTitle:[NSString stringWithFormat:@"%lu %@", (unsigned long)lines, lines == 1 ? @"line" : @"lines"]];
		_diffContext.lastItem.tag = lines;
	}
	[_diffContext selectItemWithTag:7];
	NSTextField* contextLabel = GitLabel(@"Context:", 11, NSFontWeightRegular);
	contextLabel.textColor = NSColor.secondaryLabelColor;
	[_diff.footerControls addArrangedSubview:contextLabel];
	[_diff.footerControls addArrangedSubview:_diffContext];
	FillView(_diff, pane);
	_diff.hidden = YES;
	_revisionInspector = [[GitRevisionView alloc] initWithFrame:NSZeroRect];
	_diff.softWrap = _revisionInspector.softWrap = self.softWrap;
	__weak GitWorkspaceViewController* weakSelf = self;
	_revisionInspector.stashActionHandler = ^(GitStashAction action){
		GitWorkspaceViewController* controller = weakSelf;
		[controller performStashAction:action stash:controller.selectedCommit];
	};
	_revisionInspector.showFileHistory = ^(NSString* path){ [weakSelf showHistoryOfPath:path]; };
	_revisionInspector.restoreFile = ^(NSString* root, NSString* revision, NSString* path){
		GitWorkspaceViewController* controller = weakSelf;
		NSString* message = [NSString stringWithFormat:@"Replace the working copy of “%@” with its contents at this revision? The Git index will be left unchanged.", path];
		[controller promptRevisionAction:@"Restore File in Working Copy" message:message button:@"Restore" input:nil destructive:YES completion:^(NSString*){
			[weakSelf runRevisionMutation:root worktree:YES path:path arguments:@[@"restore", @"--worktree", @"--overlay", [@"--source=" stringByAppendingString:revision], @"--", path]];
		}];
	};
	FillView(_revisionInspector, pane);
	_revisionInspector.hidden = YES;
	NSImage* image = [[NSImage imageWithSystemSymbolName:@"doc" accessibilityDescription:nil]
		imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:60 weight:NSFontWeightUltraLight]];
	NSImageView* icon = [NSImageView imageViewWithImage:image];
	icon.contentTintColor = NSColor.tertiaryLabelColor;
	_emptyTitle = GitLabel(@"No file selected", 17, NSFontWeightMedium);
	_emptyTitle.textColor = NSColor.tertiaryLabelColor;
	NSStackView* placeholder = [NSStackView stackViewWithViews:@[icon, _emptyTitle]];
	placeholder.orientation = NSUserInterfaceLayoutOrientationVertical;
	placeholder.alignment = NSLayoutAttributeCenterX;
	placeholder.spacing = 11;
	placeholder.translatesAutoresizingMaskIntoConstraints = NO;
	[pane addSubview:placeholder];
	[NSLayoutConstraint activateConstraints:@[[placeholder.centerXAnchor constraintEqualToAnchor:pane.centerXAnchor],
		[placeholder.centerYAnchor constraintEqualToAnchor:pane.centerYAnchor], [placeholder.widthAnchor constraintLessThanOrEqualToAnchor:pane.widthAnchor constant:-24]]];
	_emptyPreview = placeholder;
	return pane;
}

- (CGFloat)splitView:(NSSplitView*)split constrainMinCoordinate:(CGFloat)coordinate ofSubviewAt:(NSInteger)index
{
	return index == 0 ? MAX(coordinate, navigationMinimum) : MAX(coordinate, NSMaxX(split.subviews[0].frame)+split.dividerThickness+changesMinimum);
}

- (CGFloat)splitView:(NSSplitView*)split constrainMaxCoordinate:(CGFloat)coordinate ofSubviewAt:(NSInteger)index
{
	return index == 0 ? MIN(coordinate, NSMinX(split.subviews[2].frame)-split.dividerThickness-changesMinimum)
		: MIN(coordinate, NSWidth(split.bounds)-split.dividerThickness-PreviewMinimum(split));
}

- (void)splitView:(NSSplitView*)split resizeSubviewsWithOldSize:(NSSize)oldSize
{
	if(split.subviews.count != 3) return;
	CGFloat divider = split.dividerThickness;
	CGFloat available = NSWidth(split.bounds)-2*divider;
	CGFloat preview = PreviewMinimum(split);
	CGFloat nav = MAX(navigationMinimum, MIN(round(NSWidth(split.bounds)*_navigationFraction), available-changesMinimum-preview));
	CGFloat work = MAX(changesMinimum, MIN(round(NSWidth(split.bounds)*_changesFraction), available-nav-preview));
	CGFloat height = NSHeight(split.bounds);
	_lastNavigationWidth = nav;
	_lastChangesWidth = work;
	split.subviews[0].frame = NSMakeRect(0, 0, nav, height);
	split.subviews[1].frame = NSMakeRect(nav+divider, 0, work, height);
	split.subviews[2].frame = NSMakeRect(nav+work+2*divider, 0, MAX(0, available-nav-work), height);
	[self updateTitleBarWidth];
}

- (void)splitViewDidResizeSubviews:(NSNotification*)notification
{
	if(_split.subviews.count != 3 || NSWidth(_split.bounds) <= 0) return;
	CGFloat navigation = NSWidth(_split.subviews[0].frame), work = NSWidth(_split.subviews[1].frame);
	if(_lastNavigationWidth && std::abs(navigation - _lastNavigationWidth) > 0.5) _navigationFraction = navigation / NSWidth(_split.bounds);
	if(!_changingPaneWidth && _lastChangesWidth && std::abs(work - _lastChangesWidth) > 0.5) _changesFraction = work / NSWidth(_split.bounds);
	_lastNavigationWidth = navigation;
	_lastChangesWidth = work;
	NSString* mode = _destination[@"mode"];
	if(!_changingPaneWidth && [@[@"working", @"history", @"stashes"] containsObject:mode ?: @""]) _paneSizes[mode] = @(_changesFraction);
	[self updateTitleBarWidth];
}

- (void)setDirectory:(NSString*)directory
{
	if(_directory == directory || [_directory isEqual:directory]) return;
	_directory = [directory copy];
	if(!self.isViewLoaded) return;
	[self dismissQuickActions];
	++_navigationGeneration;
	++_historyGeneration;
	_snapshot = nil;
	_pullRequests.repository = _branchesReview.repository = _repositorySettings.repository = nil;
	_references = @[];
	_mergedRefs = nil;
	_branchPreferences = nil;
	_fileCount = 0;
	[self setStashCount:0];
	[_backDestinations removeAllObjects];
	[_forwardDestinations removeAllObjects];
	[_seenFolders removeAllObjects];
	_destination = nil;
	_workingCopy.directory = directory;
	_historyQuery = nil;
	_pendingHistorySelection = nil;
	_stashQuery = nil;
	[self rebuildNavigation];
	[self updateProjectStatus];
	[self refreshReferences];
}

- (void)setSoftWrap:(BOOL)enabled
{
	_softWrap = enabled;
	_diff.softWrap = _revisionInspector.softWrap = enabled;
	_pullRequests.softWrap = _branchesReview.softWrap = enabled;
}

- (void)setActive:(BOOL)active
{
	if(_active == active) return;
	if(active) [self loadViewIfNeeded];
	_active = active;
	_workingCopy.panelVisible = active;
	if(active) [self refresh:nil];
	else {
		[self dismissQuickActions];
		++_searchGeneration;
		++_navigationGeneration;
		++_historyGeneration;
	}
}

- (void)focusWorkspace
{
	if([_destination[@"mode"] isEqual:@"working"]) [_workingCopy focusChanges];
	else if([self activeWorkspacePage] == _pullRequests) [_pullRequests focusList];
	else if([self activeWorkspacePage] == _branchesReview) [_branchesReview focusList];
	else if([self activeWorkspacePage] == _repositorySettings) [self.view.window makeFirstResponder:_navigation];
	else [self.view.window makeFirstResponder:_historyTable];
}

- (IBAction)openWorkingCopy:(id)sender { [self selectDestination:@"working"]; }
- (IBAction)openHistory:(id)sender { [self selectDestination:@"history"]; }
- (void)showHistoryOfPath:(NSString*)path
{
	if(![self selectDestination:@"history"]) return;
	[self setHistorySearchScope:GitHistorySearchFile];
	_historyQuery = nil;
	_search.stringValue = path;
	[self searchChanged:_search];
}
- (IBAction)openStashes:(id)sender { [self selectDestination:@"stashes"]; }
- (IBAction)createBranch:(id)sender { [_workingCopy performToolbarAction:GitRepositoryCreateBranch]; }
- (IBAction)openRepositoryActions:(NSButton*)sender { [_workingCopy openActions:sender]; }
- (IBAction)runOperation:(NSButton*)sender
{
	[self runToolbarAction:(GitRepositoryAction)sender.tag quick:(NSEvent.modifierFlags & NSEventModifierFlagOption) != 0];
}

- (void)runToolbarAction:(GitRepositoryAction)action quick:(BOOL)quick
{
	if(action != GitRepositoryApplyStash) {
		[_workingCopy showToolbarAction:action reference:_destination[@"ref"] quick:quick];
		return;
	}
	if(![_workingCopy canPerformAction:action]) return;
	NSString* root = _snapshot[@"root"];
	NSDictionary* preferred = [_destination[@"mode"] isEqual:@"stashes"] ? self.selectedCommit : nil;
	NSUInteger limit = MAX(_stashCount, historyPage);
	__weak GitWorkspaceViewController* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDictionary* result = GitRepositoryStashes(root, limit);
		dispatch_async(dispatch_get_main_queue(), ^{
			GitWorkspaceViewController* controller = weakSelf;
			if(!controller.isActive || ![controller->_snapshot[@"root"] isEqual:root] || ![controller->_workingCopy canPerformAction:action]) return;
			if([result[@"commits"] count]) [controller->_workingCopy chooseStashToApply:result[@"commits"] preferred:preferred];
			else [controller refresh:nil];
		});
	});
}

- (IBAction)openQuickActions:(id)sender
{
	NSMutableArray* entries = [NSMutableArray array];
	for(NSArray* item in @[@[@"Show Working Copy", @"working"], @[@"Show History", @"history"], @[@"Show Stashes", @"stashes"], @[@"Show Pull Requests", @"pullRequests"], @[@"Show Branches Review", @"branchesReview"], @[@"Open Repository Settings", @"settings"], @[@"Refresh", @"refresh"]])
		[entries addObject:@{ @"name": item[0], @"destination": item[1] }];
	for(NSNumber* key in @[@(GitRepositoryFetch), @(GitRepositoryPull), @(GitRepositoryPush), @(GitRepositorySync), @(GitRepositoryMerge), @(GitRepositoryRebase), @(GitRepositoryApplyStash), @(GitRepositorySaveStash)])
		if(_operationButtons[key].enabled) [entries addObject:@{ @"name": _operationButtons[key].toolTip, @"operation": key }];
	if(NSString* integration = _snapshot[@"toolbarContext"][@"integration"]) {
		[entries addObject:@{ @"name": [@"Continue " stringByAppendingString:integration.capitalizedString], @"operation": @(GitRepositoryContinueIntegration) }];
		[entries addObject:@{ @"name": [@"Abort " stringByAppendingString:integration.capitalizedString], @"operation": @(GitRepositoryAbortIntegration) }];
	}
	if([_workingCopy canPerformAction:GitRepositoryCreateBranch]) [entries addObject:@{ @"name": @"Create Branch…", @"create": @YES }];
	for(NSString* ref in _references) {
		BOOL tag = [ref hasPrefix:@"refs/tags/"];
		NSRange slash = [ref rangeOfString:@"/" options:0 range:NSMakeRange(5, ref.length-5)];
		NSString* name = [ref substringFromIndex:NSMaxRange(slash)];
		[entries addObject:@{ @"name": [NSString stringWithFormat:tag ? @"Show Tag %@" : @"Check Out %@", name], tag ? @"destination" : @"checkout": ref }];
	}
	[self showQuickActionsWithEntries:entries];
}

- (void)showQuickActionsWithEntries:(NSArray<NSDictionary*>*)entries
{
	NSWindow* parent = self.view.window;
	if(!self.isActive || !parent || parent.attachedSheet) return;
#if HAVE_OAK_SWIFTUI
	if(_quickActions.isVisible) { [_quickActions dismiss]; [parent makeKeyWindow]; return; }
	if(!_quickActions) _quickActions = [[OakCommandPalette alloc] initWithTheme:[[OakThemeEnvironment alloc] init]];
	__weak GitWorkspaceViewController* weakSelf = self;
	[_quickActions showIn:parent items:QuickActionPaletteItems(entries) label:@"Git" placeholder:QuickActionPlaceholder suggestions:^NSArray*(NSString* query){
		return QuickActionPaletteItems(QuickActionSuggestions(query));
	} onSelect:^(OakCommandPaletteItem* item){ [weakSelf takeQuickAction:item.representedObject]; }];
#else
	if(_quickActions.window.isVisible) { [_quickActions cancel:nil]; return; }
	if(!_quickActions) {
		_quickActions = [[GitQuickActions alloc] init];
		_quickActions.target = self;
		_quickActions.action = @selector(acceptQuickAction:);
	}
	_quickActions.entries = entries;
	_quickActions.filterString = @"";
	[_quickActions updateItems:nil];
	[_quickActions showInWindow:parent];
#endif
}

- (void)dismissQuickActions
{
#if HAVE_OAK_SWIFTUI
	[_quickActions dismiss];
#else
	[_quickActions close];
#endif
}

#if !HAVE_OAK_SWIFTUI
- (IBAction)acceptQuickAction:(GitQuickActions*)sender { [self takeQuickAction:sender.selectedItems.firstObject]; }
#endif

- (void)takeQuickAction:(NSDictionary*)item
{
	if(!self.isActive) return;
	if(item[@"checkout"]) [_workingCopy checkOutReference:item[@"checkout"]];
	else if(item[@"create"]) [self createBranch:nil];
	else if(item[@"operation"]) [self runToolbarAction:(GitRepositoryAction)[item[@"operation"] unsignedIntegerValue] quick:NO];
	else if(item[@"query"] && [self selectDestination:@"history"]) {
		[self setHistorySearchScope:(GitHistorySearch)[item[@"scope"] unsignedIntegerValue]];
		_search.stringValue = item[@"query"];
		[self searchChanged:_search];
	}
	else if([item[@"destination"] isEqual:@"refresh"]) [self refresh:nil];
	else if(item[@"destination"]) [self selectDestination:item[@"destination"]];
}

- (IBAction)revealRepository:(id)sender
{
	if(NSString* root = _snapshot[@"root"]) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:root isDirectory:YES]]];
}

- (void)updateTitleBarActions
{
	_revealRepository.enabled = _snapshot[@"root"] != nil;
	_back.enabled = _backDestinations.count > 0;
	_forward.enabled = _forwardDestinations.count > 0;
	_sidebarCreateBranch.enabled = [_workingCopy canPerformAction:GitRepositoryCreateBranch];
	for(NSNumber* tag in _operationButtons) _operationButtons[tag].enabled = [_workingCopy canPerformAction:(GitRepositoryAction)tag.unsignedIntegerValue];
	_operationButtons[@(GitRepositoryApplyStash)].enabled &= _stashCount != 0;
	[self updateStashActions];
}

- (BOOL)canActOnStash:(NSDictionary*)stash
{
	return self.isActive && _historyLoaded && [_destination[@"mode"] isEqual:@"stashes"]
		&& [_historyRoot isEqual:_snapshot[@"root"]] && stash && [_commits containsObject:stash];
}

- (void)updateStashActions
{
	BOOL current = [self canActOnStash:self.selectedCommit];
	[_revisionInspector setStashActionsEnabled:current && [_workingCopy canPerformAction:GitRepositoryApplyStash]
		diffToolEnabled:current && !_stashDiffRunning];
}

- (void)setStashCount:(NSUInteger)count
{
	if(_stashCount == count) return;
	_stashCount = count;
	[self updateTitleBarActions];
	_stashShortcut.title = count ? [NSString stringWithFormat:@"%lu", (unsigned long)count] : @"";
	_stashShortcut.accessibilityLabel = count ? [NSString stringWithFormat:@"Show %lu %@", (unsigned long)count, count == 1 ? @"stash" : @"stashes"] : @"Show Stashes";
	[self updateProjectStatus];
}

- (BOOL)selectDestination:(NSString*)identifier
{
	NSArray* path = NavigationPath(_navigationItems, identifier);
	if(![path.lastObject objectForKey:@"mode"]) return NO;
	for(NSUInteger index = 0; index+1 < path.count; ++index) [_navigation expandItem:path[index]];
	NSInteger row = [_navigation rowForItem:path.lastObject];
	if(row < 0) return NO;
	[_navigation selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	[_navigation scrollRowToVisible:row];
	return YES;
}

- (void)navigateFrom:(NSMutableArray<NSString*>*)source to:(NSMutableArray<NSString*>*)destination
{
	NSString* current = _destination[@"id"];
	_navigatingHistory = YES;
	while(source.count) {
		NSString* candidate = source.lastObject;
		[source removeLastObject];
		if(![candidate isEqualToString:current] && [self selectDestination:candidate]) {
			if(current) [destination addObject:current];
			break;
		}
	}
	_navigatingHistory = NO;
	[self updateTitleBarActions];
}

- (IBAction)goBack:(id)sender { [self navigateFrom:_backDestinations to:_forwardDestinations]; }
- (IBAction)goForward:(id)sender { [self navigateFrom:_forwardDestinations to:_backDestinations]; }

- (IBAction)toggleBranchFolders:(id)sender
{
	NSArray* paths = NavigationPath(_navigationItems, @"refs/heads/");
	NSArray* folders = [[paths.lastObject objectForKey:@"children"] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary* item, NSDictionary* bindings){ return [item[@"children"] count] > 0; }]];
	BOOL expanded = NO;
	for(NSDictionary* item in folders) expanded |= [_navigation isItemExpanded:item];
	if(expanded && [_destination[@"ref"] hasPrefix:@"refs/heads/"] && NavigationPath(_navigationItems, _destination[@"id"]).count > 2) [self openWorkingCopy:nil];
	for(NSDictionary* item in folders)
		if(expanded) [_navigation collapseItem:item];
		else [_navigation expandItem:item expandChildren:YES];
}

- (IBAction)refresh:(id)sender
{
	if(!self.isActive) return;
	[_workingCopy refresh:nil];
	[self refreshReferences];
	[self refreshWorkspacePage];
	if(_history && !_history.hidden) [self loadHistory];
}

- (void)refreshReferences
{
	if(!self.isActive || !self.directory.length) return;
	NSUInteger generation = ++_navigationGeneration;
	NSString* directory = self.directory;
	__weak GitWorkspaceViewController* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSDictionary* result = GitRepositoryReferences(directory);
		NSDictionary* prefs = result[@"error"] ? @{} : GitWorkspaceBranchPreferences(directory);
		dispatch_async(dispatch_get_main_queue(), ^{
			GitWorkspaceViewController* controller = weakSelf;
			if(!controller || generation != controller->_navigationGeneration) return;
			NSArray* refs = result[@"refs"] ?: @[];
			NSSet* merged = [NSSet setWithArray:result[@"merged"] ?: @[]];
			[controller setStashCount:[result[@"stashCount"] unsignedIntegerValue]];
			if(![controller->_references isEqual:refs] || ![controller->_mergedRefs isEqual:merged] || ![controller->_branchPreferences isEqual:prefs]) {
				controller->_references = refs;
				controller->_mergedRefs = merged;
				controller->_branchPreferences = prefs;
				[controller rebuildNavigation];
			}
		});
	});
}

- (void)updateWorkingCopy:(NSDictionary*)snapshot count:(NSUInteger)count
{
	BOOL revisionChanged = ![(_snapshot[@"head"] ?: @"") isEqual:(snapshot[@"head"] ?: @"")] || ![(_snapshot[@"branch"] ?: @"") isEqual:(snapshot[@"branch"] ?: @"")];
	BOOL rootChanged = ![(_snapshot[@"root"] ?: @"") isEqual:(snapshot[@"root"] ?: @"")];
	BOOL navigationChanged = revisionChanged || ![(_snapshot[@"tracking"] ?: @"") isEqual:(snapshot[@"tracking"] ?: @"")] || _fileCount != count;
	_snapshot = snapshot;
	_fileCount = count;
	[self updateTitleBarActions];
	[self updateProjectStatus];
	if(navigationChanged) [self rebuildNavigation];
	if(revisionChanged) [self refreshReferences];
	if(rootChanged || (revisionChanged && [self activeWorkspacePage] == _branchesReview)) [self refreshWorkspacePage];
}

- (void)updateProjectStatus
{
	NSString* root = _snapshot[@"root"] ?: _directory;
	_projectName.stringValue = root.lastPathComponent.length ? root.lastPathComponent : @"Git Workspace";
	_projectName.toolTip = root;
	NSString* mode = _destination[@"name"] ?: @"Working Copy";
	if([_destination[@"mode"] isEqual:@"stashes"] && _stashCount) {
		_projectStatus.stringValue = [NSString stringWithFormat:@"Stashes (%lu %@)", (unsigned long)_stashCount, _stashCount == 1 ? @"Stash" : @"Stashes"];
		return;
	}
	if([_destination[@"mode"] isEqual:@"history"] && _historyLoaded && _commits.count) {
		_projectStatus.stringValue = [NSString stringWithFormat:@"%@ (%lu%@ %@)", _destination[@"title"] ?: mode, (unsigned long)MAX(_historyTotal, _commits.count), _historyHasMore && _historyTotal <= _commits.count ? @"+" : @"", _commits.count == 1 ? @"Commit" : @"Commits"];
		return;
	}
	if(![_destination[@"mode"] isEqual:@"working"]) { _projectStatus.stringValue = _destination[@"title"] ?: mode; return; }
	NSString* branch = _snapshot[@"branch"];
	_projectStatus.stringValue = branch ? [NSString stringWithFormat:@"Working Copy (%@ – %lu %@)", branch, (unsigned long)_fileCount, _fileCount == 1 ? @"changed file" : @"changed files"]
		: _snapshot[@"error"] ? @"Open a Git repository" : @"Working Copy";
}

- (void)rebuildNavigation
{
	NSMutableSet* expanded = [NSMutableSet set];
	for(NSInteger row = 0; row < _navigation.numberOfRows; ++row) {
		NSDictionary* item = [_navigation itemAtRow:row];
		if([_navigation isItemExpanded:item]) [expanded addObject:item[@"id"]];
	}
	NSString* selected = _destination[@"id"];
	NSMutableDictionary* working = [NavigationItem(@"working", @"Working Copy", @"folder", @"working") mutableCopy];
	if(_fileCount) working[@"badge"] = [NSString stringWithFormat:@"%lu", (unsigned long)_fileCount];
	NSArray* tools = @[working, NavigationItem(@"history", @"History", @"clock.arrow.circlepath", @"history"),
		NavigationItem(@"stashes", @"Stashes", @"list.clipboard", @"stashes"),
		NavigationItem(@"pullRequests", @"Pull Requests", @"arrow.triangle.branch", @"pullRequests"),
		NavigationItem(@"branchesReview", @"Branches Review", @"arrow.left.arrow.right.circle", @"branchesReview"),
		NavigationItem(@"settings", @"Settings", @"gearshape", @"settings")];
	NSMutableArray* items = [NSMutableArray arrayWithObject:NavigationGroup(@"Workspace", @"workspace", tools)];
	NSString* headBadge = HeadBadge(_snapshot[@"tracking"]);
	NSString* headRef = [@"refs/heads/" stringByAppendingString:_snapshot[@"branch"] ?: @""];
	NSString* archives = [@"refs/heads/" stringByAppendingString:GitWorkspaceArchivePrefix];
	NSMutableSet* visibleMerged = [_mergedRefs mutableCopy];
	for(NSString* ref in _branchPreferences) if([_branchPreferences[ref][@"hidemergedhint"] boolValue]) [visibleMerged removeObject:ref];
	for(NSArray* section in @[@[@"Branches", @"refs/heads/", branchIcon, @YES], @[@"Archived Branches", archives, @"archivebox", @NO],
		@[@"Tags", @"refs/tags/", @"tag", @NO], @[@"Remotes", @"refs/remotes/", branchIcon, @YES]]) {
		NSString* prefix = section[1];
		NSMutableArray* children = [NSMutableArray array];
		if([prefix isEqual:@"refs/heads/"] && [_references containsObject:headRef])
			AddReference(children, headRef, _snapshot[@"branch"], prefix, section[2], NO, headRef, headBadge, visibleMerged);
		if([prefix isEqual:@"refs/heads/"]) for(NSString* ref in _references) {
			if([ref hasPrefix:prefix] && ![ref hasPrefix:archives] && ![ref isEqual:headRef] && [_branchPreferences[ref][@"pinned"] boolValue])
				AddReference(children, ref, [ref substringFromIndex:prefix.length], prefix, @"pin", NO, headRef, headBadge, visibleMerged);
		}
		for(NSString* ref in _references) if([ref hasPrefix:prefix] && ![ref isEqual:headRef] && !([prefix isEqual:@"refs/heads/"] && [ref hasPrefix:archives])) {
			if([prefix isEqual:@"refs/heads/"] && [_branchPreferences[ref][@"pinned"] boolValue]) continue;
			AddReference(children, ref, [ref substringFromIndex:prefix.length], prefix, section[2], [section[3] boolValue], headRef, headBadge, visibleMerged);
		}
		if(children.count || _snapshot[@"root"]) [items addObject:NavigationGroup(section[0], prefix, children)];
	}
	_rebuildingNavigation = YES;
	_navigationItems = items;
	[_navigation reloadData];
	for(NSInteger row = 0; row < _navigation.numberOfRows; ++row) {
		NSDictionary* item = [_navigation itemAtRow:row];
		NSString* identifier = item[@"id"];
		BOOL localFolder = [item[@"children"] count] && [identifier hasPrefix:@"refs/heads/"];
		if([item[@"section"] boolValue] || [expanded containsObject:identifier] || (localFolder && ![_seenFolders containsObject:identifier]))
			[_navigation expandItem:item];
		if(localFolder) [_seenFolders addObject:identifier];
	}
	NSInteger target = [_navigation rowForItem:working];
	for(NSInteger row = 0; row < _navigation.numberOfRows; ++row) {
		if([[[_navigation itemAtRow:row] objectForKey:@"id"] isEqual:selected]) { target = row; break; }
	}
	if(target >= 0) [_navigation selectRowIndexes:[NSIndexSet indexSetWithIndex:target] byExtendingSelection:NO];
	_rebuildingNavigation = NO;
	[self updateDestination];
}

- (NSInteger)outlineView:(NSOutlineView*)outline numberOfChildrenOfItem:(NSDictionary*)item { return item ? [item[@"children"] count] : _navigationItems.count; }
- (id)outlineView:(NSOutlineView*)outline child:(NSInteger)index ofItem:(NSDictionary*)item { return (item ? item[@"children"] : _navigationItems)[index]; }
- (BOOL)outlineView:(NSOutlineView*)outline isItemExpandable:(NSDictionary*)item { return [item[@"children"] count] != 0; }
- (BOOL)outlineView:(NSOutlineView*)outline isGroupItem:(NSDictionary*)item { return [item[@"section"] boolValue]; }
- (BOOL)outlineView:(NSOutlineView*)outline shouldSelectItem:(NSDictionary*)item { return item[@"mode"] != nil; }

- (NSTableRowView*)outlineView:(NSOutlineView*)outline rowViewForItem:(NSDictionary*)item
{
	return [item[@"section"] boolValue] ? nil : [[GitWorkspaceNavigationRow alloc] init];
}

- (NSView*)outlineView:(NSOutlineView*)outline viewForTableColumn:(NSTableColumn*)column item:(NSDictionary*)item
{
	NSString* name = item[@"name"];
	NSTextField* label = GitLabel(name, [item[@"section"] boolValue] ? 11 : 13, [item[@"section"] boolValue] ? NSFontWeightSemibold : NSFontWeightRegular);
	if([item[@"section"] boolValue]) { label.textColor = NSColor.secondaryLabelColor; return label; }
	label.toolTip = item[@"title"] ?: name;
	[label setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSString* symbol = item[@"icon"];
	NSImage* image = [symbol isEqual:branchIcon] ? BranchImage() : [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
	NSImageView* icon = image ? [NSImageView imageViewWithImage:image] : [[NSImageView alloc] init];
	icon.contentTintColor = NSColor.secondaryLabelColor;
	icon.imageScaling = NSImageScaleProportionallyDown;
	NSMutableArray* views = [NSMutableArray arrayWithArray:@[icon, label]];
	if(NSString* badge = item[@"badge"]) {
		if([badge isEqual:@"Merged"]) label.textColor = NSColor.secondaryLabelColor;
		NSTextField* count = GitLabel(badge, 10, NSFontWeightSemibold);
		[count setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
		if(item[@"ref"]) {
			NSBox* capsule = [[NSBox alloc] init];
			capsule.boxType = NSBoxCustom;
			capsule.titlePosition = NSNoTitle;
			capsule.borderWidth = 0;
			capsule.cornerRadius = 9;
			capsule.fillColor = WorkspaceColor(NSColor.quaternaryLabelColor, 0.235, 0.252, 0.255);
			if([badge isEqual:@"Merged"]) capsule.toolTip = @"This branch tip is already in the current branch history";
			capsule.contentViewMargins = NSZeroSize;
			count.translatesAutoresizingMaskIntoConstraints = NO;
			[capsule.contentView addSubview:count];
			[NSLayoutConstraint activateConstraints:@[
				[capsule.heightAnchor constraintEqualToConstant:19],
				[count.leadingAnchor constraintEqualToAnchor:capsule.contentView.leadingAnchor constant:7], [count.trailingAnchor constraintEqualToAnchor:capsule.contentView.trailingAnchor constant:-7],
				[count.centerYAnchor constraintEqualToAnchor:capsule.contentView.centerYAnchor],
			]];
			[views addObject:capsule];
		} else [views addObject:count];
	}
	NSStackView* row = [NSStackView stackViewWithViews:views];
	row.distribution = NSStackViewDistributionFill;
	row.edgeInsets = NSEdgeInsetsMake(0, 0, 0, 12);
	row.spacing = 6;
	[icon.widthAnchor constraintEqualToConstant:15].active = YES;
	[icon.heightAnchor constraintEqualToConstant:15].active = YES;
	return row;
}

- (void)outlineViewSelectionDidChange:(NSNotification*)notification { [self updateDestination]; }

- (IBAction)checkOutClickedBranch:(NSOutlineView*)sender
{
	NSInteger row = sender.clickedRow;
	if(row >= 0 && row < sender.numberOfRows) [_workingCopy checkOutReference:[sender itemAtRow:row][@"ref"]];
}

- (void)menuNeedsUpdate:(NSMenu*)menu
{
	[menu removeAllItems];
	NSString* root = _snapshot[@"root"];
	if(!root || !self.isActive) return;
	menu.autoenablesItems = NO;
	BOOL canChange = [_workingCopy canPerformAction:GitRepositorySwitchBranch] && !_snapshot[@"toolbarContext"][@"integration"];
	if(menu == _navigation.menu) {
		NSInteger row = _navigation.clickedRow;
		if(row >= 0 && row < _navigation.numberOfRows) [self populateReferenceMenu:menu entry:[_navigation itemAtRow:row] root:root canChange:canChange];
		return;
	}
	if(menu != _historyTable.menu || !_historyLoaded || ![_historyRoot isEqual:_snapshot[@"root"]]) return;
	NSDictionary* commit = [self commitAtHistoryRow:_historyTable.clickedRow];
	if(!commit) return;
	if(![_destination[@"mode"] isEqual:@"stashes"]) {
		[self populateCommitMenu:menu commit:commit root:root canChange:canChange];
		NSDictionary* context = _snapshot[@"commitContext"];
		if(NSURL* issue = GitWorkspaceIssueURL(context[@"issueURL"], context[@"issuePrefix"], commit[@"subject"])) {
			[menu addItem:NSMenuItem.separatorItem];
			NSMenuItem* open = [menu addItemWithTitle:@"Open Related Issue" action:@selector(openHistoryIssue:) keyEquivalent:@""];
			open.target = self;
			open.representedObject = issue;
		}
		return;
	}
	if(![self canActOnStash:commit]) return;
	for(NSArray* command in @[@[@"Apply Stash…", @0], @[@"Pop Stash…", @1], @[@"Delete Stash…", @2], @[@"Open Diff Tool", @3]]) {
		if([command[1] integerValue] == 3) [menu addItem:NSMenuItem.separatorItem];
		NSMenuItem* item = [menu addItemWithTitle:command[0] action:@selector(runStashAction:) keyEquivalent:@""];
		item.target = self;
		item.representedObject = commit;
		item.tag = [command[1] integerValue];
		item.enabled = item.tag == 3 ? !_stashDiffRunning : canChange;
	}
	[menu addItem:NSMenuItem.separatorItem];
	[self addRevisionMenuItem:menu title:@"Copy Commit Hash to Clipboard" action:CopyRevision context:@{@"root": root, @"revision": commit[@"id"]} enabled:YES];
}

- (void)addRevisionMenuItem:(NSMenu*)menu title:(NSString*)title action:(RevisionMenuAction)action context:(NSDictionary*)context enabled:(BOOL)enabled
{
	NSMenuItem* item = [menu addItemWithTitle:title action:@selector(runRevisionMenuAction:) keyEquivalent:@""];
	item.target = self;
	item.tag = action;
	item.representedObject = context;
	item.enabled = enabled;
}

- (void)populateCommitMenu:(NSMenu*)menu commit:(NSDictionary*)commit root:(NSString*)root canChange:(BOOL)canChange
{
	NSString* hash = commit[@"id"], *shortHash = [hash substringToIndex:MIN(8, hash.length)];
	if(!shortHash.length) return;
	NSDictionary* context = @{@"root": root, @"revision": hash, @"commit": commit};
	auto add = [&](NSString* title, RevisionMenuAction action, BOOL enabled = YES){ [self addRevisionMenuItem:menu title:title action:action context:context enabled:enabled]; };
	BOOL head = [commit[@"head"] boolValue], merge = [commit[@"parents"] count] > 1;
	add(@"Copy Commit Hash to Clipboard", CopyRevision);
	add(@"Copy Commit Info to Clipboard", CopyRevisionInfo);
	add(@"Reveal in History", RevealRevision, _historyQuery.length || _destination[@"ref"] != nil);
	[menu addItem:NSMenuItem.separatorItem];
	add([NSString stringWithFormat:@"Check Out “%@”", shortHash], CheckOutRevision, canChange && !head);
	[menu addItem:NSMenuItem.separatorItem];
	add([NSString stringWithFormat:@"Reset HEAD to “%@”…", shortHash], ResetRevision, canChange && !head);
	add(@"Revert…", RevertRevision, canChange && !merge);
	add([NSString stringWithFormat:@"Cherry-Pick “%@”…", shortHash], CherryPickRevision, canChange && !merge);
	[menu addItem:NSMenuItem.separatorItem];
	add([NSString stringWithFormat:@"Create New Branch from “%@”…", shortHash], CreateBranchAtRevision, canChange);
	add([NSString stringWithFormat:@"Create New Tag from “%@”…", shortHash], CreateTagAtRevision, canChange);
	[menu addItem:NSMenuItem.separatorItem];
	add([NSString stringWithFormat:@"Save Patch for “%@”…", shortHash], SaveRevisionPatch);
	add([NSString stringWithFormat:@"Export Files from “%@”…", shortHash], ExportRevision);
	add([NSString stringWithFormat:@"Compare “%@” to Revision…", shortHash], CompareRevision);
}

- (void)populateReferenceMenu:(NSMenu*)menu entry:(NSDictionary*)entry root:(NSString*)root canChange:(BOOL)canChange
{
	NSString* ref = entry[@"ref"], *name = entry[@"title"];
	if(!ref.length || !name.length) return;
	BOOL local = [ref hasPrefix:@"refs/heads/"], tag = [ref hasPrefix:@"refs/tags/"], archived = local && [name hasPrefix:GitWorkspaceArchivePrefix];
	BOOL head = local && [name isEqual:_snapshot[@"branch"]];
	NSDictionary* context = @{@"root": root, @"revision": ref, @"name": name};
	auto add = [&](NSString* title, RevisionMenuAction action, BOOL enabled = YES){ [self addRevisionMenuItem:menu title:title action:action context:context enabled:enabled]; };
	if(!archived) {
		add(local || tag ? @"Check Out" : @"Check Out as Local Branch…", tag ? CheckOutRevision : CheckOutBranch, canChange && !head);
		if(local || tag) add(@"Check Out in New Worktree…", CheckOutWorktree, canChange && !head);
		[menu addItem:NSMenuItem.separatorItem];
	}
	if(local || tag) {
		if(local) {
			if(!archived) add(@"Track Upstream Branch…", TrackBranch, canChange && [_references indexOfObjectPassingTest:^BOOL(NSString* reference, NSUInteger index, BOOL* stop){ return [reference hasPrefix:@"refs/remotes/"]; }] != NSNotFound);
			add(archived ? @"Restore Branch…" : @"Archive Branch…", ArchiveBranch, canChange && !head);
			if(!archived) add(@"Rename Branch…", RenameBranch, canChange);
		}
		add(tag ? @"Delete Tag…" : @"Delete Branch…", DeleteReference, canChange && !head);
		[menu addItem:NSMenuItem.separatorItem];
	}
	add(@"Create New Branch…", CreateBranchAtRevision, canChange);
	add(@"Create New Tag…", CreateTagAtRevision, canChange);
	[menu addItem:NSMenuItem.separatorItem];
	add(@"Export Files…", ExportRevision);
	add(@"Compare to Revision…", CompareRevision);
	[menu addItem:NSMenuItem.separatorItem];
	add(@"Reveal in History", RevealRevision);
	add(tag ? @"Copy Tag Name" : @"Copy Branch Name", CopyRevision);
}

- (void)populateBranchReviewMenu:(NSMenu*)menu branch:(NSDictionary*)branch refs:(NSArray<NSDictionary*>*)refs githubRemotes:(NSArray<NSDictionary*>*)githubRemotes
{
	NSString* root = _snapshot[@"root"], *ref = branch[@"ref"], *name = branch[@"name"];
	if(!self.isActive || !root || ![root isEqual:_branchesReview.repository] || ![ref hasPrefix:@"refs/heads/"] || !name.length) return;
	BOOL archived = [branch[@"archived"] boolValue], checkedOut = [branch[@"checkedOut"] boolValue];
	BOOL canChange = [_workingCopy canPerformAction:GitRepositorySwitchBranch] && !_snapshot[@"toolbarContext"][@"integration"];
	BOOL canCheckOut = canChange && !checkedOut && (!_branchesReview.canCheckOut || _branchesReview.canCheckOut());
	NSArray* remotes = _snapshot[@"toolbarContext"][@"remotes"] ?: @[];
	NSString* upstream = branch[@"upstreamRef"], *parent = branch[@"prefs"][@"parent"], *target = branch[@"upstreamTarget"], *remote = branch[@"upstreamRemote"];
	NSDictionary* remoteBranch = nil, *github = nil;
	for(NSDictionary* candidate in refs) if([candidate[@"ref"] isEqual:upstream]) { remoteBranch = candidate; break; }
	for(NSDictionary* candidate in githubRemotes) if([candidate[@"name"] isEqual:remote]) { github = candidate; break; }
	BOOL published = [remoteBranch[@"id"] length] && [target hasPrefix:@"refs/heads/"] && [remotes containsObject:remote ?: @""];
	NSDictionary* context = @{@"root": root, @"revision": ref, @"name": name, @"branch": branch,
		@"remotes": remotes, @"remoteTip": remoteBranch[@"id"] ?: @"", @"github": github ?: @{}};
	menu.autoenablesItems = NO;
	auto title = [&](NSString* format){ return [NSString stringWithFormat:format, name]; };
	auto add = [&](NSString* label, RevisionMenuAction action, BOOL enabled){
		[self addRevisionMenuItem:menu title:label action:action context:context enabled:enabled];
		return menu.itemArray.lastObject;
	};
	auto separator = [&]{ [menu addItem:NSMenuItem.separatorItem]; };
	auto tracking = [&](NSString* label, RevisionMenuAction action, NSString* selected, BOOL local){
		NSMenu* submenu = [[NSMenu alloc] initWithTitle:label];
		submenu.autoenablesItems = NO;
		NSMutableDictionary* clear = [context mutableCopy];
		clear[@"choice"] = @"";
		[self addRevisionMenuItem:submenu title:@"None" action:action context:clear enabled:canChange && selected.length];
		submenu.itemArray.lastObject.state = selected.length ? NSControlStateValueOff : NSControlStateValueOn;
		for(NSDictionary* candidate in refs) {
			NSString* reference = candidate[@"ref"];
			if([candidate[@"local"] boolValue] != local || [candidate[@"archived"] boolValue] || [reference isEqual:ref]) continue;
			if(submenu.numberOfItems == 1) [submenu addItem:NSMenuItem.separatorItem];
			NSMutableDictionary* selection = [context mutableCopy];
			selection[@"choice"] = reference;
			[self addRevisionMenuItem:submenu title:candidate[@"name"] action:action context:selection enabled:canChange];
			submenu.itemArray.lastObject.state = [reference isEqual:selected] ? NSControlStateValueOn : NSControlStateValueOff;
		}
		NSMenuItem* item = [menu addItemWithTitle:label action:NULL keyEquivalent:@""];
		item.submenu = submenu;
		item.enabled = canChange && (selected.length || submenu.numberOfItems > 1);
	};
	if(!archived) {
		add(title(@"Check Out “%@”"), CheckOutBranch, canCheckOut);
		add(title(@"Check Out “%@” in New Worktree…"), CheckOutWorktree, canChange && !checkedOut);
		separator();
		add(title([branch[@"prefs"][@"pinned"] boolValue] ? @"Unpin “%@”" : @"Pin “%@”"), PinBranch, canChange);
		separator();
		add(@"Force Push with Lease…", ForcePushBranchWithLease, canChange && published);
		separator();
		add(title(@"Publish “%@”…"), PublishBranch, canChange && remotes.count && !published);
		add(title(@"Push “%@” To…"), PushBranchTo, canChange && remotes.count);
		separator();
		tracking(@"Track Upstream Branch", SetBranchUpstream, upstream, NO);
		tracking(@"Track Parent Branch", SetBranchParent, parent, YES);
		separator();
	}
	add(title(archived ? @"Restore “%@”" : @"Archive “%@”"), ArchiveBranch, canChange && !checkedOut);
	if(!archived) {
		for(NSArray* option in @[@[@"Skips Auto-Archiving", @(SkipAutoArchive), @"skipautoarchive"], @[@"Hides Fully Merged Hint", @(HideMergedHint), @"hidemergedhint"]]) {
			NSMenuItem* item = add(option[0], (RevisionMenuAction)[option[1] integerValue], canChange);
			item.indentationLevel = 1;
			item.state = [branch[@"prefs"][option[2]] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
		}
	}
	separator();
	if(!archived) add(title(@"Rename “%@”…"), RenameBranch, canChange);
	add(title(@"Delete “%@”…"), DeleteReference, canChange && !checkedOut);
	separator();
	add(title(@"Create New Branch from “%@”…"), CreateBranchAtRevision, canChange);
	add(title(@"Create New Stacked Branch from “%@”…"), CreateStackedBranch, canChange && !archived);
	add(title(@"Create New Tag from “%@”…"), CreateTagAtRevision, canChange);
	add(title(@"Create New Pull Request from “%@”…"), CreatePullRequestFromBranch, canChange && !archived && published && github != nil);
	separator();
	add(title(@"Export Files from “%@”…"), ExportRevision, YES);
	add(title(@"Compare “%@” with Revision…"), CompareRevision, YES);
	separator();
	add(@"Reveal in History", RevealRevision, [_references containsObject:ref]);
	add(@"Copy Branch Name to Clipboard", CopyRevision, YES);
}

- (IBAction)openHistoryIssue:(NSMenuItem*)sender { [NSWorkspace.sharedWorkspace openURL:sender.representedObject]; }

- (void)promptRevisionAction:(NSString*)title message:(NSString*)message button:(NSString*)button input:(NSString*)input
	destructive:(BOOL)destructive completion:(void(^)(NSString*))completion
{
	if(!self.isActive || !self.view.window || self.view.window.attachedSheet) return;
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = title;
	alert.informativeText = message;
	NSTextField* field = nil;
	if(input) {
		field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 330, 24)];
		field.stringValue = input;
		field.accessibilityLabel = title;
		alert.accessoryView = field;
		alert.window.initialFirstResponder = field;
	}
	[alert addButtonWithTitle:button].hasDestructiveAction = destructive;
	[alert addButtonWithTitle:@"Cancel"];
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		if(response == NSAlertFirstButtonReturn) completion([field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
	}];
}

- (void)runRevisionMutation:(NSString*)root worktree:(BOOL)worktree path:(NSString*)path arguments:(NSArray*)arguments
{
	[self runRevisionMutation:root worktree:worktree path:path execute:^NSString*{
		return GitWorkspaceError(GitRepositoryCommand(root, arguments, YES, 45), @"Git could not complete the operation.");
	}];
}

- (void)runRevisionMutation:(NSString*)root worktree:(BOOL)worktree path:(NSString*)path execute:(NSString*(^)(void))execute
{
	if(self.isActive && !_snapshot[@"toolbarContext"][@"integration"])
		[_workingCopy runWorkspaceMutationAtRoot:root changesWorktree:worktree path:path execute:execute];
}

- (void)showRevisionError:(NSString*)error atRoot:(NSString*)root
{
	if(!error || !self.isActive || ![_snapshot[@"root"] isEqual:root] || !self.view.window || self.view.window.attachedSheet) return;
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = @"Git action could not finish";
	alert.informativeText = error;
	[alert beginSheetModalForWindow:self.view.window completionHandler:nil];
}

- (void)saveRevision:(NSString*)revision root:(NSString*)root exportFiles:(BOOL)exportFiles commit:(NSDictionary*)commit
{
	NSSavePanel* panel = [NSSavePanel savePanel];
	NSString* ext = exportFiles ? @"zip" : @"patch";
	panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:ext]];
	NSString* name = commit ? [revision substringToIndex:MIN(8, revision.length)] : revision.lastPathComponent;
	panel.nameFieldStringValue = [name stringByAppendingPathExtension:ext];
	[panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		if(response != NSModalResponseOK) return;
		NSURL* destination = panel.URL;
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			NSFileManager* files = NSFileManager.defaultManager;
			NSError* fileError = nil;
			NSURL* temp = [files URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:destination create:YES error:&fileError];
			NSString* error = fileError.localizedDescription;
			if(temp) {
				NSURL* output = [temp URLByAppendingPathComponent:[@"revision" stringByAppendingPathExtension:ext]];
				NSString* outputOption = [@"--output=" stringByAppendingString:output.path];
				NSString* parent = [commit[@"parents"] firstObject];
				NSArray* args = exportFiles ? @[@"archive", @"--format=zip", outputOption, revision]
					: parent ? @[@"diff", @"--binary", @"--no-ext-diff", @"--no-textconv", outputOption, parent, revision, @"--"]
					: @[@"diff-tree", @"--root", @"--no-commit-id", @"-r", @"--binary", @"--no-ext-diff", @"--no-textconv", outputOption, revision, @"--"];
				error = GitWorkspaceError(GitRepositoryCommand(root, args, NO, 45), @"Git could not export this revision.");
				if(!error) {
					if([files fileExistsAtPath:destination.path]) [files replaceItemAtURL:destination withItemAtURL:output backupItemName:nil options:0 resultingItemURL:nil error:&fileError];
					else [files moveItemAtURL:output toURL:destination error:&fileError];
					error = fileError.localizedDescription;
				}
				[files removeItemAtURL:temp error:nil];
			}
			dispatch_async(dispatch_get_main_queue(), ^{ [self showRevisionError:error atRoot:root]; });
		});
	}];
}

- (void)compareRevision:(NSString*)revision withInput:(NSString*)input root:(NSString*)root
{
	if(!input.length || ![_snapshot[@"root"] isEqual:root]) return;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		auto resolve = [&](NSString* value){
			return [GitWorkspaceText(GitRepositoryCommand(root, @[@"rev-parse", @"--verify", @"--end-of-options", [value stringByAppendingString:@"^{commit}"]]))
				stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
		};
		NSString* base = resolve(input), *tip = resolve(revision);
		dispatch_async(dispatch_get_main_queue(), ^{
			if(!self.isActive || ![self->_snapshot[@"root"] isEqual:root] || !self.view.window || self.view.window.attachedSheet) return;
			if(!base.length || !tip.length) { [self showRevisionError:@"Enter an existing branch, tag, or commit." atRoot:root]; return; }
			NSWindow* sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 740, 485) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
			sheet.title = [NSString stringWithFormat:@"Compare %@ → %@", input, revision];
			GitRevisionView* view = [[GitRevisionView alloc] initWithFrame:NSMakeRect(0, 42, 740, 443)];
			view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
			view.softWrap = self.softWrap;
			view.syntaxThemeUUID = self.syntaxThemeUUID;
			[sheet.contentView addSubview:view];
			[view showComparison:@{@"range": [NSString stringWithFormat:@"%@..%@", base, tip], @"base": base, @"tip": tip, @"summary": sheet.title} repository:root];
			NSButton* done = [NSButton buttonWithTitle:@"Done" target:self action:@selector(closeRevisionComparison:)];
			done.keyEquivalent = @"\r";
			done.frame = NSMakeRect(645, 8, 82, 26);
			[sheet.contentView addSubview:done];
			[self.view.window beginSheet:sheet completionHandler:nil];
		});
	});
}

- (IBAction)closeRevisionComparison:(NSButton*)sender { [sender.window.sheetParent endSheet:sender.window]; }

- (void)revealRevision:(NSString*)hash
{
	if(![self selectDestination:@"history"]) return;
	[self setHistorySearchScope:GitHistorySearchHash];
	_pendingHistorySelection = hash;
	_historyQuery = hash;
	_search.stringValue = hash;
	[self loadHistory];
}

- (void)runReviewedBranchMutation:(NSString*)root branch:(NSDictionary*)branch worktree:(BOOL)worktree execute:(NSString*(^)(void))execute
{
	[self runRevisionMutation:root worktree:worktree path:nil execute:^NSString*{
		NSString* current = [GitWorkspaceText(GitRepositoryCommand(root, @[@"rev-parse", @"--verify", @"--end-of-options", branch[@"ref"]])) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
		if(![current isEqual:branch[@"id"]]) return @"The branch changed. Refresh Branches Review and try again.";
		return execute();
	}];
}

- (void)runReviewedBranchMutation:(NSString*)root branch:(NSDictionary*)branch worktree:(BOOL)worktree arguments:(NSArray*)arguments
{
	if(!branch) { [self runRevisionMutation:root worktree:worktree path:nil arguments:arguments]; return; }
	[self runReviewedBranchMutation:root branch:branch worktree:worktree execute:^NSString*{
		return GitWorkspaceError(GitRepositoryCommand(root, arguments, YES, 45), @"Git could not complete this branch operation.");
	}];
}

- (void)showPushReviewedBranch:(NSDictionary*)context action:(RevisionMenuAction)action
{
	NSString* root = context[@"root"], *name = context[@"name"];
	NSDictionary* branch = context[@"branch"];
	BOOL force = action == ForcePushBranchWithLease, publish = action == PublishBranch;
	NSArray* remotes = context[@"remotes"];
	NSString* remote = branch[@"upstreamRemote"], *upstream = branch[@"upstreamTarget"], *remoteTip = context[@"remoteTip"];
	if(!remotes.count || (force && (!remoteTip.length || ![upstream hasPrefix:@"refs/heads/"] || ![remotes containsObject:remote ?: @""]))) return;
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = [NSString stringWithFormat:force ? @"Force Push “%@” with Lease?" : publish ? @"Publish “%@”" : @"Push “%@” To", name];
	NSPopUpButton* picker = nil;
	NSTextField* field = nil;
	if(force) {
		alert.informativeText = [NSString stringWithFormat:@"Replace %@/%@ with the reviewed local branch. Git will refuse if the remote branch has changed since the last fetch.", remote, [upstream substringFromIndex:11]];
	} else {
		alert.informativeText = publish ? @"Push this branch and set the destination as its upstream." : @"Choose a remote and enter the destination branch name.";
		picker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 310, 26) pullsDown:NO];
		[picker addItemsWithTitles:remotes];
		picker.accessibilityLabel = @"Remote";
		if([remotes containsObject:remote ?: @""]) [picker selectItemWithTitle:remote];
		else if([remotes containsObject:@"origin"]) [picker selectItemWithTitle:@"origin"];
		if(publish) alert.accessoryView = picker;
		else {
			field = [NSTextField textFieldWithString:[upstream hasPrefix:@"refs/heads/"] ? [upstream substringFromIndex:11] : name];
			field.accessibilityLabel = @"Destination Branch";
			field.placeholderString = @"Destination Branch";
			NSView* form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 310, 59)];
			picker.frame = NSMakeRect(0, 33, 310, 26);
			field.frame = NSMakeRect(0, 0, 310, 24);
			[form addSubview:picker];
			[form addSubview:field];
			alert.accessoryView = form;
		}
	}
	[alert addButtonWithTitle:force ? @"Force Push" : publish ? @"Publish" : @"Push"].hasDestructiveAction = force;
	[alert addButtonWithTitle:@"Cancel"];
	[alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
		if(response != NSAlertFirstButtonReturn || ![self->_snapshot[@"root"] isEqual:root]) return;
		NSString* chosen = force ? remote : picker.titleOfSelectedItem;
		NSString* destination = force ? upstream : [@"refs/heads/" stringByAppendingString:publish ? name : [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
		if(![self->_snapshot[@"toolbarContext"][@"remotes"] containsObject:chosen ?: @""]) { [self showRevisionError:@"Choose a remote configured for this repository." atRoot:root]; return; }
		[self runRevisionMutation:root worktree:NO path:nil execute:^NSString*{ return GitWorkspacePushBranch(root, branch, chosen, destination, publish, force ? remoteTip : nil); }];
	}];
}

- (IBAction)runRevisionMenuAction:(NSMenuItem*)sender
{
	NSDictionary* context = sender.representedObject;
	NSString* root = context[@"root"], *revision = context[@"revision"], *name = context[@"name"];
	NSDictionary* commit = context[@"commit"];
	NSDictionary* branch = context[@"branch"];
	if(!self.isActive || ![root isEqual:_snapshot[@"root"]] || !revision.length || !sender.enabled || !self.view.window || self.view.window.attachedSheet) return;
	NSString* refLabel = name ?: [revision substringToIndex:MIN(8, revision.length)];
	BOOL tag = [revision hasPrefix:@"refs/tags/"];
	BOOL local = [revision hasPrefix:@"refs/heads/"];
	if(sender.tag == CopyRevision) {
		[NSPasteboard.generalPasteboard clearContents];
		[NSPasteboard.generalPasteboard setString:name ?: revision forType:NSPasteboardTypeString];
		return;
	}
	if(sender.tag == CopyRevisionInfo) {
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			NSDictionary* result = GitRepositoryCommand(root, @[@"show", @"--no-patch", @"--format=medium", revision, @"--"]);
			NSString* error = GitWorkspaceError(result, @"Git could not read this commit.");
			dispatch_async(dispatch_get_main_queue(), ^{
				if(error) [self showRevisionError:error atRoot:root];
				else if(NSString* text = GitWorkspaceText(result)) {
					[NSPasteboard.generalPasteboard clearContents];
					[NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
				}
			});
		});
		return;
	}
	if(sender.tag == RevealRevision) {
		if(name) [self selectDestination:revision];
		else [self revealRevision:revision];
		return;
	}
	if(sender.tag == SaveRevisionPatch || sender.tag == ExportRevision) { [self saveRevision:revision root:root exportFiles:sender.tag == ExportRevision commit:commit]; return; }
	if(sender.tag == CheckOutBranch) {
		if(branch) [self runReviewedBranchMutation:root branch:branch worktree:YES arguments:@[@"switch", @"--", name]];
		else [_workingCopy checkOutReference:revision];
		return;
	}
	if(sender.tag == PublishBranch || sender.tag == PushBranchTo || sender.tag == ForcePushBranchWithLease) {
		[self showPushReviewedBranch:context action:(RevisionMenuAction)sender.tag];
		return;
	}
	if(sender.tag == CreatePullRequestFromBranch) {
		NSString* target = branch[@"upstreamTarget"], *parent = branch[@"prefs"][@"parent"];
		NSString* base = [parent hasPrefix:@"refs/heads/"] ? [parent substringFromIndex:11] : nil;
		if([target hasPrefix:@"refs/heads/"] && [root isEqual:_branchesReview.repository])
			[_branchesReview showCreatePullRequestFromBranch:[target substringFromIndex:11] remote:context[@"github"] base:base];
		return;
	}
	if(sender.tag == PinBranch || sender.tag == SkipAutoArchive || sender.tag == HideMergedHint || sender.tag == SetBranchParent) {
		NSString* key = sender.tag == PinBranch ? @"pinned" : sender.tag == SkipAutoArchive ? @"skipautoarchive" : sender.tag == HideMergedHint ? @"hidemergedhint" : @"parent";
		NSString* value = sender.tag == SetBranchParent ? context[@"choice"] : [branch[@"prefs"][key] boolValue] ? nil : @"true";
		[self runReviewedBranchMutation:root branch:branch worktree:NO execute:^NSString*{ return GitWorkspaceSetBranchPreference(root, revision, key, value); }];
		return;
	}
	if(sender.tag == SetBranchUpstream) {
		NSString* upstream = context[@"choice"];
		NSArray* args = upstream.length ? @[@"branch", [@"--set-upstream-to=" stringByAppendingString:upstream], @"--", name] : @[@"branch", @"--unset-upstream", @"--", name];
		[self runReviewedBranchMutation:root branch:branch worktree:NO arguments:args];
		return;
	}
	if(sender.tag == CompareRevision) {
		[self promptRevisionAction:@"Compare to Revision" message:@"Enter the branch, tag, or commit to compare against." button:@"Compare" input:@"HEAD" destructive:NO completion:^(NSString* input){ [self compareRevision:revision withInput:input root:root]; }];
		return;
	}
	if(sender.tag == CheckOutWorktree) {
		NSOpenPanel* panel = [NSOpenPanel openPanel];
		panel.canChooseDirectories = YES;
		panel.canChooseFiles = NO;
		panel.canCreateDirectories = YES;
		panel.message = @"Choose an empty directory for the new worktree.";
		panel.prompt = @"Create Worktree";
		[panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
			if(response != NSModalResponseOK) return;
			NSArray* args = tag ? @[@"worktree", @"add", @"--detach", @"--", panel.URL.path, revision] : @[@"worktree", @"add", @"--", panel.URL.path, name];
			[self runReviewedBranchMutation:root branch:branch worktree:NO arguments:args];
		}];
		return;
	}
	NSString* title = nil, *message = nil, *input = nil;
	BOOL worktree = NO, destructive = NO;
	NSArray* args = nil;
	switch(sender.tag) {
		case CheckOutRevision:
			title = @"Check Out Revision"; message = @"This will move the working copy to the selected revision in detached HEAD state.";
			args = @[@"switch", @"--detach", @"--", revision]; worktree = YES; break;
		case ResetRevision:
			title = @"Reset HEAD"; message = @"Move HEAD to the selected commit. Git will refuse if the reset would overwrite local changes.";
			args = @[@"reset", @"--keep", revision, @"--"]; worktree = destructive = YES; break;
		case RevertRevision:
			title = @"Revert Commit"; message = @"Create a new commit that reverses the selected commit.";
			args = @[@"revert", @"--no-edit", revision]; worktree = YES; break;
		case CherryPickRevision:
			title = @"Cherry-Pick Commit"; message = @"Apply the selected commit to the current checkout.";
			args = @[@"cherry-pick", @"--no-edit", revision]; worktree = YES; break;
		case CreateBranchAtRevision: title = @"Create Branch"; message = @"Enter the name of the new branch."; input = @""; break;
		case CreateStackedBranch: title = @"Create Stacked Branch"; message = @"Create a branch at this revision and track it as the parent of the new branch."; input = @""; break;
		case CreateTagAtRevision: title = @"Create Tag"; message = @"Enter the name of the new tag."; input = @""; break;
		case RenameBranch: title = @"Rename Branch"; message = @"Enter the new local branch name."; input = name; break;
		case TrackBranch: title = @"Track Upstream Branch"; message = @"Enter a remote branch, such as origin/main."; input = @""; break;
		case DeleteReference:
			title = tag ? @"Delete Tag" : @"Delete Branch"; message = tag ? @"This removes the local tag." : @"Git will refuse to delete an unmerged branch.";
			args = @[tag ? @"tag" : @"branch", @"-d", @"--", name]; destructive = YES; break;
		case ArchiveBranch:
			title = [name hasPrefix:GitWorkspaceArchivePrefix] ? @"Restore Branch" : @"Archive Branch";
			message = @"Move this branch between Branches and Archived Branches."; break;
		default: return;
	}
	NSInteger action = sender.tag;
	[self promptRevisionAction:title message:[NSString stringWithFormat:@"%@\n\n%@", refLabel, message] button:title input:input destructive:destructive completion:^(NSString* value){
		if(input && !value.length) return;
		if(action == ArchiveBranch && local) {
			[self runRevisionMutation:root worktree:NO path:nil execute:^NSString*{
				if(branch) return GitWorkspaceArchiveBranch(root, branch, [branch[@"archived"] boolValue]);
				for(NSDictionary* branch in GitWorkspaceReviewRefs(root)) if([branch[@"ref"] isEqual:revision]) return GitWorkspaceArchiveBranch(root, branch, [name hasPrefix:GitWorkspaceArchivePrefix]);
				return @"The branch is no longer available.";
			}];
			return;
		}
		if(action == CreateStackedBranch) {
			[self runRevisionMutation:root worktree:NO path:nil execute:^NSString*{ return GitWorkspaceCreateStackedBranch(root, value, branch); }];
			return;
		}
		NSArray* command = args;
		if(action == CreateBranchAtRevision || action == CreateTagAtRevision) command = @[action == CreateBranchAtRevision ? @"branch" : @"tag", @"--", value, revision];
		if(action == RenameBranch) command = @[@"branch", @"-m", @"--", name, value];
		if(action == TrackBranch) {
			NSString* upstream = [value hasPrefix:@"refs/remotes/"] ? value : [@"refs/remotes/" stringByAppendingString:value];
			if(![self->_references containsObject:upstream]) { [self showRevisionError:@"Choose an existing remote branch." atRoot:root]; return; }
			command = @[@"branch", [@"--set-upstream-to=" stringByAppendingString:upstream], @"--", name];
		}
		if(command) [self runReviewedBranchMutation:root branch:branch worktree:worktree arguments:command];
	}];
}

- (IBAction)runStashAction:(NSMenuItem*)sender
{
	NSDictionary* stash = sender.representedObject;
	if(![self canActOnStash:stash]) return;
	if(sender.tag == 1) [_workingCopy applyStash:stash pop:YES];
	else [self performStashAction:sender.tag == 2 ? GitStashDelete : sender.tag == 3 ? GitStashDiffTool : GitStashApply stash:stash];
}

- (void)performStashAction:(GitStashAction)action stash:(NSDictionary*)stash
{
	if(![self canActOnStash:stash] || self.view.window.attachedSheet) return;
	if(action == GitStashApply) { [_workingCopy applyStash:stash pop:NO]; return; }
	if(action == GitStashDelete) { [_workingCopy deleteStash:stash]; return; }
	if(_stashDiffRunning) return;
	_stashDiffRunning = YES;
	[self updateStashActions];
	NSString* root = _historyRoot, *commit = stash[@"id"];
	__weak GitWorkspaceViewController* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString* error = GitRepositoryOpenStashDiffTool(root, commit);
		dispatch_async(dispatch_get_main_queue(), ^{
			GitWorkspaceViewController* controller = weakSelf;
			if(!controller) return;
			controller->_stashDiffRunning = NO;
			[controller updateStashActions];
			if(!error || ![controller canActOnStash:stash] || !controller.view.window || controller.view.window.attachedSheet) return;
			NSAlert* alert = [[NSAlert alloc] init];
			alert.messageText = @"Could Not Open Diff Tool";
			alert.informativeText = error;
			[alert beginSheetModalForWindow:controller.view.window completionHandler:nil];
		});
	});
}

- (void)updateDestination
{
	if(_rebuildingNavigation || _navigation.selectedRow < 0) return;
	NSDictionary* item = [_navigation itemAtRow:_navigation.selectedRow];
	if(!item[@"mode"] || [_destination[@"id"] isEqual:item[@"id"]]) return;
	if(!_navigatingHistory && _destination[@"id"]) {
		[_backDestinations addObject:_destination[@"id"]];
		if(_backDestinations.count > 100) [_backDestinations removeObjectAtIndex:0];
		[_forwardDestinations removeAllObjects];
	}
	_destination = item;
	_pendingHistorySelection = nil;
	_historyLoaded = NO;
	[self updateTitleBarActions];
	BOOL working = [item[@"mode"] isEqual:@"working"];
	NSViewController* page = [self activeWorkspacePage];
	_workspacePages.hidden = !page;
	for(NSViewController* controller in @[_pullRequests, _branchesReview, _repositorySettings])
		if(controller.isViewLoaded) controller.view.hidden = controller != page;
	if(page) {
		[page loadViewIfNeeded];
		if(!page.view.superview) FillView(page.view, _workspacePages);
		page.view.hidden = NO;
	}
	BOOL stashes = [item[@"mode"] isEqual:@"stashes"];
	_historyOptions.hidden = stashes;
	_historyTitle.font = [NSFont systemFontOfSize:13 weight:stashes ? NSFontWeightRegular : NSFontWeightMedium];
	_historyTitle.textColor = stashes ? NSColor.secondaryLabelColor : NSColor.labelColor;
	_historyListTop.constant = stashes ? 10 : 0;
	[self setHistoryFooterVisible:!stashes];
	_history.hidden = working || page;
	_workingCopy.view.hidden = !working;
	NSString* mode = item[@"mode"];
	if(!page) {
		NSNumber* preferred = _paneSizes[mode];
		_changesFraction = preferred ? preferred.doubleValue : [mode isEqual:@"history"] ? 0.467 : [mode isEqual:@"stashes"] ? 0.223 : changesShare;
		CGFloat width = NSWidth(_split.bounds);
		if(width > 0) {
			CGFloat divider = _split.dividerThickness;
			CGFloat start = NSMaxX(_split.subviews.firstObject.frame)+divider;
			CGFloat desired = MAX(start+changesMinimum, MIN(start+round(width*_changesFraction), width-divider-PreviewMinimum(_split)));
			_changingPaneWidth = YES;
			[_split setPosition:desired ofDividerAtIndex:1];
			_changingPaneWidth = NO;
		}
	}
	++_searchGeneration;
	[self updateSearchField];
	[self updateProjectStatus];
	[self clearPreview:working ? @"No file selected" : [item[@"mode"] isEqual:@"stashes"] ? @"No stash selected" : @"No commit selected"];
	++_historyGeneration;
	if(page) {
		[self refreshWorkspacePage];
	} else if(working) {
		[_workingCopy refresh:nil];
	} else {
		_historyTitle.stringValue = [item[@"id"] isEqual:@"history"] ? @"All Branches, Remotes, Tags" : item[@"title"] ?: item[@"name"];
		_historyTable.accessibilityLabel = [mode isEqual:@"stashes"] ? @"Stashes" : @"Commits";
		_historyLimit = historyPage;
		_commits = @[];
		_historyRows = @[];
		[_historyTable reloadData];
		[self loadHistory];
	}
}

- (void)updateSearchField
{
	BOOL working = [_destination[@"mode"] isEqual:@"working"], history = [_destination[@"mode"] isEqual:@"history"], stashes = [_destination[@"mode"] isEqual:@"stashes"];
	NSViewController* page = [self activeWorkspacePage];
	BOOL pullRequests = page == _pullRequests, branchesReview = page == _branchesReview;
	_search.enabled = working || history || stashes || pullRequests || branchesReview;
	_search.searchMenuTemplate = history ? _historySearchMenu : nil;
	NSString* scope = @[@"Message", @"Author", @"Hash", @"File"][_historySearchScope];
	_search.placeholderString = history ? [@"Search for " stringByAppendingString:scope] : stashes ? @"Search for Stash Message" : pullRequests ? @"Search Pull Requests" : branchesReview ? @"Search for Branch with Name" : working ? @"Search for File" : @"Search";
	_search.accessibilityLabel = history ? [@"Search history by " stringByAppendingString:scope.lowercaseString] : _search.placeholderString;
	_search.stringValue = history ? _historyQuery ?: @"" : stashes ? _stashQuery ?: @"" : working ? _workingCopy.searchString ?: @"" : (pullRequests || branchesReview) ? ((GitWorkspaceReviewPane*)page).filter ?: @"" : @"";
}

- (void)setHistorySearchScope:(GitHistorySearch)scope
{
	_historySearchScope = scope;
	for(NSMenuItem* item in _historySearchMenu.itemArray) item.state = item.tag == scope ? NSControlStateValueOn : NSControlStateValueOff;
	[self updateSearchField];
}

- (IBAction)changeHistorySearchScope:(NSMenuItem*)sender
{
	NSString* query = _search.stringValue;
	[self setHistorySearchScope:(GitHistorySearch)sender.tag];
	_search.stringValue = query;
	_historyQuery = nil;
	[self searchChanged:_search];
}

- (IBAction)showHistoryOptions:(NSButton*)sender
{
	NSMenu* menu = [[NSMenu alloc] init];
	NSMenuItem* graph = [menu addItemWithTitle:@"Show Commit Graph" action:@selector(toggleHistoryGraph:) keyEquivalent:@""];
	graph.target = self;
	graph.state = _hideHistoryGraph ? NSControlStateValueOff : NSControlStateValueOn;
	[menu addItem:NSMenuItem.separatorItem];
	for(NSMenuItem* scope in _historySearchMenu.itemArray) {
		NSMenuItem* item = [menu addItemWithTitle:[@"Search by " stringByAppendingString:scope.title] action:@selector(changeHistorySearchScope:) keyEquivalent:@""];
		item.target = self;
		item.tag = scope.tag;
		item.state = scope.state;
	}
	[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds)+3) inView:sender];
}

- (IBAction)toggleHistoryGraph:(id)sender { _hideHistoryGraph = !_hideHistoryGraph; [_historyTable reloadData]; }

- (IBAction)searchChanged:(NSSearchField*)sender
{
	if([_destination[@"mode"] isEqual:@"working"]) { _workingCopy.searchString = sender.stringValue; return; }
	NSViewController* page = [self activeWorkspacePage];
	if(page == _pullRequests || page == _branchesReview) { ((GitWorkspaceReviewPane*)page).filter = sender.stringValue; return; }
	BOOL stashes = [_destination[@"mode"] isEqual:@"stashes"];
	if(!stashes && ![_destination[@"mode"] isEqual:@"history"]) return;
	NSString* query = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if([(stashes ? _stashQuery : _historyQuery) isEqual:query]) return;
	_pendingHistorySelection = nil;
	if(stashes) _stashQuery = query;
	else _historyQuery = query;
	_historyLimit = historyPage;
	++_historyGeneration;
	_historyLoaded = NO;
	_loadMore.enabled = NO;
	[self updateStashActions];
	NSUInteger generation = ++_searchGeneration;
	__weak GitWorkspaceViewController* weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
		GitWorkspaceViewController* controller = weakSelf;
		if(controller && controller->_searchGeneration == generation) [controller loadHistory];
	});
}
- (void)controlTextDidChange:(NSNotification*)notification { [self searchChanged:_search]; }

- (void)loadHistory
{
	if(!self.isActive || _history.hidden) return;
	NSUInteger generation = ++_historyGeneration;
	NSString* directory = self.directory;
	NSString* ref = _destination[@"ref"];
	BOOL stashes = [_destination[@"mode"] isEqual:@"stashes"];
	NSUInteger limit = _historyLimit;
	NSString* query = stashes ? _stashQuery : _historyQuery;
	GitHistorySearch scope = _historySearchScope;
	_historyLoaded = NO;
	_loadMore.enabled = NO;
	[self updateStashActions];
	_historyStatus.stringValue = stashes ? @"Loading stashes…" : @"Loading history…";
	__weak GitWorkspaceViewController* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDictionary* result = stashes ? GitRepositoryStashes(directory, limit, query) : GitRepositorySearchHistory(directory, ref, limit, query, scope);
		dispatch_async(dispatch_get_main_queue(), ^{
			GitWorkspaceViewController* controller = weakSelf;
			if(controller && generation == controller->_historyGeneration) [controller showHistory:result stashes:stashes];
		});
	});
}

- (IBAction)loadMore:(id)sender
{
	if(!_historyLoaded || !_historyHasMore) return;
	_historyLimit += historyPage;
	[self loadHistory];
}

- (NSDictionary*)historyEntryAtRow:(NSInteger)row
{
	return row >= 0 && row < _historyRows.count ? _historyRows[row] : nil;
}

- (NSDictionary*)commitAtHistoryRow:(NSInteger)row { return [self historyEntryAtRow:row][@"commit"]; }
- (NSDictionary*)selectedCommit { return [self commitAtHistoryRow:_historyTable.selectedRow]; }

- (void)setHistoryFooterVisible:(BOOL)visible
{
	_historyFooter.hidden = !visible;
	if(visible) { _historyListBottom.active = NO; _historyFooterBottom.active = YES; }
	else { _historyFooterBottom.active = NO; _historyListBottom.active = YES; }
}

- (void)showHistory:(NSDictionary*)result stashes:(BOOL)stashes
{
	NSDictionary* selected = self.selectedCommit;
	_historyLoaded = YES;
	_historyRoot = result[@"root"];
	_commits = result[@"commits"] ?: @[];
	NSArray<NSDictionary*>* graph = stashes ? nil : GitGraphLayout(_commits, result[@"primaryCommits"]);
	NSMutableArray<NSDictionary*>* rows = [NSMutableArray arrayWithCapacity:_commits.count];
	NSString* previousMonth = nil;
	NSUInteger lanes = 1;
	for(NSUInteger index = 0; index < _commits.count; ++index) {
		NSDictionary* commit = _commits[index];
		if(stashes) { [rows addObject:@{@"commit": commit}]; continue; }
		NSDictionary* tracks = graph[index];
		lanes = MAX(lanes, [tracks[@"tracks"] unsignedIntegerValue]);
		NSString* date = commit[@"date"];
		NSString* month = date.length >= 7 ? [date substringToIndex:7] : nil;
		if(month && ![month isEqual:previousMonth])
			[rows addObject:@{@"month": month, @"tracks": @{@"incoming": tracks[@"incoming"]}}];
		previousMonth = month;
		[rows addObject:@{@"commit": commit, @"tracks": tracks}];
	}
	_historyRows = rows;
	_graphWidth = MIN(82, 11+13*lanes);
	_historyHasMore = [result[@"more"] boolValue];
	_historyTotal = [result[@"total"] unsignedIntegerValue];
	_loadMore.enabled = _historyHasMore;
	_loadMore.hidden = stashes && !_historyHasMore;
	[self setHistoryFooterVisible:!stashes || _historyHasMore || !_commits.count];
	_historyStatus.stringValue = result[@"error"] ?: (_commits.count ? [NSString stringWithFormat:@"%lu %@%@", (unsigned long)_commits.count,
		stashes ? (_commits.count == 1 ? @"stash" : @"stashes") : (_commits.count == 1 ? @"commit" : @"commits"), _historyHasMore ? @" loaded" : @""] : (stashes ? (_stashQuery.length ? @"No matching stashes" : @"No stashes") : _historyQuery.length ? @"No matching commits" : @"No commits yet"));
	_historyStatus.toolTip = _historyStatus.stringValue;
	_updatingHistory = YES;
	[_historyTable reloadData];
	NSUInteger row = selected ? [_historyRows indexOfObjectPassingTest:^BOOL(NSDictionary* entry, NSUInteger idx, BOOL* stop){
		NSDictionary* commit = entry[@"commit"];
		return [commit[@"id"] isEqual:selected[@"id"]] && (!stashes || [commit[@"refs"] isEqual:selected[@"refs"]]);
	}] : NSNotFound;
	if(stashes && row == NSNotFound && selected) row = [_historyRows indexOfObjectPassingTest:^BOOL(NSDictionary* entry, NSUInteger idx, BOOL* stop){
		return [entry[@"commit"][@"id"] isEqual:selected[@"id"]];
	}];
	BOOL reveal = !stashes && _pendingHistorySelection != nil;
	if(reveal) {
		row = [_historyRows indexOfObjectPassingTest:^BOOL(NSDictionary* entry, NSUInteger idx, BOOL* stop){ return [entry[@"commit"][@"id"] isEqual:self->_pendingHistorySelection]; }];
		_pendingHistorySelection = nil;
	}
	if(stashes && row == NSNotFound && _historyRows.count) row = 0;
	[_historyTable selectRowIndexes:row == NSNotFound ? NSIndexSet.indexSet : [NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	if((stashes || reveal) && row != NSNotFound) [_historyTable scrollRowToVisible:row];
	_updatingHistory = NO;
	[self updateProjectStatus];
	[self previewCommit:self.selectedCommit];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)table { return _historyRows.count; }
- (BOOL)tableView:(NSTableView*)table isGroupRow:(NSInteger)row { return [self historyEntryAtRow:row][@"month"] != nil; }
- (BOOL)tableView:(NSTableView*)table shouldSelectRow:(NSInteger)row { return [self commitAtHistoryRow:row] != nil; }
- (NSTableRowView*)tableView:(NSTableView*)table rowViewForRow:(NSInteger)row
{
	if([_destination[@"mode"] isEqual:@"stashes"]) {
		GitStashListRow* view = [[GitStashListRow alloc] init];
		view.separatesNextRow = row+1 < _historyRows.count;
		return view;
	}
	return [self tableView:table isGroupRow:row] ? [[GitHistoryMonthRow alloc] init] : GitListRow();
}

- (CGFloat)tableView:(NSTableView*)table heightOfRow:(NSInteger)row
{
	if([_destination[@"mode"] isEqual:@"stashes"]) return 52;
	return [self tableView:table isGroupRow:row] ? historyMonthHeight : historyCommitHeight;
}

- (NSView*)historyMonthHeading:(NSString*)month tracks:(NSDictionary*)tracks
{
	NSArray<NSString*>* parts = [month componentsSeparatedByString:@"-"];
	NSDateComponents* components = [[NSDateComponents alloc] init];
	components.year = parts.firstObject.integerValue;
	components.month = parts.lastObject.integerValue;
	components.day = 1;
	NSDate* date = [[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian] dateFromComponents:components];
	NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
	[formatter setLocalizedDateFormatFromTemplate:@"MMMM y"];
	NSTextField* label = GitLabel(date ? [[formatter stringFromDate:date] localizedUppercaseString] : month, 10, NSFontWeightSemibold);
	label.textColor = NSColor.secondaryLabelColor;
	label.translatesAutoresizingMaskIntoConstraints = NO;
	NSView* heading = [[NSView alloc] init];
	[heading addSubview:label];
	[NSLayoutConstraint activateConstraints:@[
		[label.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor constant:(_hideHistoryGraph ? 0 : _graphWidth) + 5],
		[label.bottomAnchor constraintEqualToAnchor:heading.bottomAnchor constant:-7],
	]];
	if(!_hideHistoryGraph && [tracks[@"incoming"] count]) {
		GitGraphTracksView* graph = [[GitGraphTracksView alloc] init];
		graph.tracks = tracks;
		graph.clipsToBounds = YES;
		graph.translatesAutoresizingMaskIntoConstraints = NO;
		[heading addSubview:graph];
		[NSLayoutConstraint activateConstraints:@[
			[graph.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor],
			[graph.topAnchor constraintEqualToAnchor:heading.topAnchor],
			[graph.bottomAnchor constraintEqualToAnchor:heading.bottomAnchor],
			[graph.widthAnchor constraintEqualToConstant:_graphWidth],
		]];
	}
	return heading;
}

- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row
{
	NSDictionary* entry = [self historyEntryAtRow:row];
	if(entry[@"month"]) return [self historyMonthHeading:entry[@"month"] tracks:entry[@"tracks"]];
	NSDictionary* commit = entry[@"commit"];
	if(!commit) return nil;
	NSString* subjectText = [commit[@"subject"] length] ? commit[@"subject"] : @"(No subject)";
	NSString* hash = commit[@"id"];
	NSString* date = commit[@"date"];
	NSString* dateText = [[date substringToIndex:MIN(date.length, 10)] stringByReplacingOccurrencesOfString:@"-" withString:@"/"];
	NSTextField* dateLabel = GitLabel(dateText, 11, NSFontWeightRegular);
	dateLabel.textColor = NSColor.secondaryLabelColor;
	NSTextField* subject = GitLabel(subjectText, 12, NSFontWeightMedium);
	[subject setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[subject setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	if([_destination[@"mode"] isEqual:@"stashes"]) {
		NSRange first = [subjectText rangeOfString:@": "];
		NSString* branch = @"…";
		if(first.location != NSNotFound && ([subjectText hasPrefix:@"On "] || [subjectText hasPrefix:@"WIP on "])) {
			NSUInteger start = [subjectText hasPrefix:@"On "] ? 3 : 7;
			if(first.location >= start) branch = [subjectText substringWithRange:NSMakeRange(start, first.location-start)];
			subject.stringValue = [subjectText substringFromIndex:NSMaxRange(first)];
		}
		NSTextField* basedOn = GitLabel(@"Based on", 12, NSFontWeightRegular);
		basedOn.textColor = NSColor.secondaryLabelColor;
		dateLabel.font = basedOn.font;
		CGFloat branchWidth = [branch sizeWithAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium]}].width;
		NSView* badge = GitBadge(branchWidth > 61 ? @"…" : branch, WorkspaceColor(NSColor.secondaryLabelColor, 0.52, 0.53, 0.55));
		badge.toolTip = branch;
		subject.lineBreakMode = NSLineBreakByTruncatingTail;
		NSStackView* basedOnBranch = [NSStackView stackViewWithViews:@[basedOn, badge]];
		basedOnBranch.spacing = 8;
		NSView* cell = [[NSView alloc] init];
		for(NSView* view in @[basedOnBranch, dateLabel, subject]) {
			view.translatesAutoresizingMaskIntoConstraints = NO;
			[cell addSubview:view];
		}
		[NSLayoutConstraint activateConstraints:@[
			[basedOnBranch.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:36],
			[basedOnBranch.topAnchor constraintEqualToAnchor:cell.topAnchor constant:8],
			[dateLabel.centerYAnchor constraintEqualToAnchor:basedOnBranch.centerYAnchor],
			[dateLabel.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-36],
			[basedOnBranch.trailingAnchor constraintLessThanOrEqualToAnchor:dateLabel.leadingAnchor constant:-8],
			[subject.leadingAnchor constraintEqualToAnchor:basedOnBranch.leadingAnchor],
			[subject.trailingAnchor constraintEqualToAnchor:dateLabel.trailingAnchor],
			[subject.topAnchor constraintEqualToAnchor:basedOnBranch.bottomAnchor constant:2],
		]];
		cell.toolTip = subjectText;
		return cell;
	}
	GitGraphTracksView* graph = [[GitGraphTracksView alloc] init];
	graph.tracks = entry[@"tracks"];
	graph.head = [commit[@"head"] boolValue];
	graph.clipsToBounds = YES;
	graph.hidden = _hideHistoryGraph;
	[graph.widthAnchor constraintEqualToConstant:_graphWidth].active = YES;
	[graph.heightAnchor constraintEqualToConstant:historyCommitHeight].active = YES;
	NSTextField* shortHash = GitLabel([hash substringToIndex:MIN(hash.length, 8)], 11, NSFontWeightRegular);
	shortHash.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
	shortHash.textColor = NSColor.secondaryLabelColor;
	NSMutableArray<NSView*>* columns = [NSMutableArray arrayWithArray:@[graph, shortHash]];
	NSArray* refs = [commit[@"refs"] componentsSeparatedByString:@", "];
	for(NSUInteger i = 0; i < MIN(refs.count, 3); ++i) {
		NSString* name = refs[i];
		if(!name.length) continue;
		BOOL tag = [name hasPrefix:@"tag: "];
		NSTextField* badge = GitLabel(tag ? [name substringFromIndex:5] : name, 10, NSFontWeightSemibold);
		badge.drawsBackground = YES;
		badge.backgroundColor = [(tag ? NSColor.systemYellowColor : i == 0 ? NSColor.systemBlueColor : NSColor.secondaryLabelColor) colorWithAlphaComponent:0.24];
		[badge.widthAnchor constraintLessThanOrEqualToConstant:98].active = YES;
		[badge setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
		[columns addObject:badge];
	}
	NSTextField* author = GitLabel(commit[@"author"], 11, NSFontWeightRegular);
	author.textColor = NSColor.secondaryLabelColor;
	[author.widthAnchor constraintLessThanOrEqualToConstant:90].active = YES;
	[author setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[columns addObjectsFromArray:@[subject, author, dateLabel]];
	NSStackView* line = [NSStackView stackViewWithViews:columns];
	line.distribution = NSStackViewDistributionFill;
	line.spacing = 5;
	line.edgeInsets = NSEdgeInsetsMake(0, 0, 0, 9);
	line.toolTip = subjectText;
	return line;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification
{
	if(!_updatingHistory) [self previewCommit:self.selectedCommit];
}

- (void)clearPreview:(NSString*)title
{
	++_previewGeneration;
	_activeWorkingChange = _displayedWorkingChange = nil;
	_emptyTitle.stringValue = title;
	_emptyPreview.hidden = NO;
	_diff.hidden = YES;
	_revisionInspector.hidden = YES;
	[_revisionInspector showRevision:nil repository:nil stash:NO];
}

- (void)previewWorkingChange:(NSDictionary*)change snapshot:(NSDictionary*)snapshot buffers:(NSDictionary*)buffers force:(BOOL)force
{
	if(![_destination[@"mode"] isEqual:@"working"]) return;
	if(!change || !snapshot[@"root"]) {
		[self clearPreview:snapshot[@"root"] && _workingCopy.workingCopySelectionCount > 1 ? @"Multiple files selected" : @"No file selected"];
		return;
	}
	_workingDiffSnapshot = snapshot;
	_workingDiffBuffers = buffers;
	BOOL samePath = [_activeWorkingChange[@"path"] isEqual:change[@"path"]];
	// While a file remains selected, keep an explicitly chosen staged/unstaged comparison.
	if(!force && samePath && ![_activeWorkingChange[@"group"] isEqual:change[@"group"]]) {
		for(NSDictionary* variant in GitRepositoryChanges(snapshot)) {
			if([variant[@"path"] isEqual:change[@"path"]] && [variant[@"group"] isEqual:_activeWorkingChange[@"group"]]) { change = variant; break; }
		}
	}
	_activeWorkingChange = change;
	NSUInteger generation = ++_previewGeneration;
	_workingDiffTabs.enabled = NO;
	[_diff setChunkActionsEnabled:NO];
	NSUInteger group = [change[@"group"] unsignedIntegerValue];
	BOOL staged = group == GitChangeStaged, unstaged = group == GitChangeWorking;
	for(NSDictionary* variant in GitRepositoryChanges(snapshot)) if([variant[@"path"] isEqual:change[@"path"]]) {
		staged |= [variant[@"group"] unsignedIntegerValue] == GitChangeStaged;
		unstaged |= [variant[@"group"] unsignedIntegerValue] == GitChangeWorking;
	}
	NSString* file = change[@"path"];
	BOOL directory = [change[@"directory"] boolValue];
	NSString* subtitle = directory ? @"Untracked folder" : group == GitChangeStaged ? @"Last commit → Staged changes" : group == GitChangeConflict ? @"Merge conflict"
		: [change[@"unsaved"] boolValue] ? @"Staged version → Unsaved editor buffer" : @"Staged version → Working tree";
	NSUInteger contextLines = [self diffContextLines];
	BOOL ignoreWhitespace = _ignoreDiffWhitespace.state == NSControlStateValueOn;
	BOOL hasStaged = staged, hasUnstaged = unstaged;
	__weak GitWorkspaceViewController* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDictionary* patch = GitRepositoryChangeDiff(snapshot, change, buffers ?: @{}, contextLines, ignoreWhitespace);
		NSArray* hunks = GitDiffHunks(patch[@"text"]);
		dispatch_async(dispatch_get_main_queue(), ^{
			GitWorkspaceViewController* self = weakSelf;
			if(!self || generation != self->_previewGeneration) return;
			BOOL preserve = [self->_displayedWorkingChange[@"path"] isEqual:file] && [self->_displayedWorkingChange[@"group"] isEqual:change[@"group"]];
			self->_displayedWorkingChange = change;
			self->_workingDiffTabs.selectedSegment = group == GitChangeStaged ? 0 : 1;
			self->_workingDiffTabs.hidden = directory || group == GitChangeConflict;
			self->_workingDiffTabs.enabled = YES;
			[self->_workingDiffTabs setEnabled:hasStaged forSegment:0];
			[self->_workingDiffTabs setEnabled:hasUnstaged forSegment:1];
			self->_diff.syntaxPath = file;
			self->_diff.syntaxThemeUUID = self.syntaxThemeUUID;
			UTType* type = directory ? UTTypeFolder : file.pathExtension.length ? [UTType typeWithFilenameExtension:file.pathExtension] : UTTypeData;
			self->_diff.fileIcon = [NSWorkspace.sharedWorkspace iconForContentType:type ?: UTTypeData];
			[self configureHunks:hunks];
			[self->_diff showTitle:file.lastPathComponent subtitle:subtitle patch:patch preserveScroll:preserve];
			[self->_diff setChunkActionsEnabled:YES];
			self->_emptyPreview.hidden = YES;
			self->_revisionInspector.hidden = YES;
			self->_diff.hidden = NO;
		});
	});
}

- (IBAction)selectWorkingDiff:(NSSegmentedControl*)sender
{
	GitChangeGroup group = sender.selectedSegment == 0 ? GitChangeStaged : GitChangeWorking;
	for(NSDictionary* variant in GitRepositoryChanges(_workingDiffSnapshot)) if([variant[@"path"] isEqual:_activeWorkingChange[@"path"]] && [variant[@"group"] unsignedIntegerValue] == group) {
		[self previewWorkingChange:variant snapshot:_workingDiffSnapshot buffers:_workingDiffBuffers force:YES];
		return;
	}
}

- (void)configureHunks:(NSArray<NSString*>*)hunks
{
	NSDictionary* change = _activeWorkingChange;
	BOOL editable = hunks.count && [change[@"code"] isEqual:@"M"] && ![change[@"unsaved"] boolValue];
	// Only an unfiltered patch identifies the exact lines Git will apply.
	if(!editable || _ignoreDiffWhitespace.state == NSControlStateValueOn) { [_diff setChunkActions:@[] handler:nil]; return; }
	BOOL staged = [change[@"group"] unsignedIntegerValue] == GitChangeStaged;
	NSUInteger contextLines = [self diffContextLines];
	__weak GitWorkspaceViewController* weakSelf = self;
	[_diff setChunkActions:staged ? @[@(GitRepositoryUnstage)] : @[@(GitRepositoryDiscard), @(GitRepositoryStage)] handler:^(NSUInteger index, GitRepositoryAction action){
		GitWorkspaceViewController* owner = weakSelf;
		if(owner && index < hunks.count) [owner->_workingCopy performHunk:hunks[index] change:change action:action contextLines:contextLines];
	}];
}

- (NSUInteger)diffContextLines
{
	return _showCompleteDiff.state == NSControlStateValueOn ? GitDiffCompleteFileContext : _diffContext.selectedTag;
}

- (IBAction)changeDiffDisplay:(id)sender
{
	_diffContext.enabled = _showCompleteDiff.state != NSControlStateValueOn;
	if(_activeWorkingChange) [self previewWorkingChange:_activeWorkingChange snapshot:_workingDiffSnapshot buffers:_workingDiffBuffers force:YES];
}

- (void)previewCommit:(NSDictionary*)commit
{
	[self updateStashActions];
	BOOL stashes = [_destination[@"mode"] isEqual:@"stashes"];
	NSString* root = _historyRoot;
	if(!commit || !root) { [self clearPreview:stashes ? @"No stash selected" : @"No commit selected"]; return; }
	_revisionInspector.syntaxThemeUUID = self.syntaxThemeUUID;
	__weak GitWorkspaceViewController* weakSelf = self;
	[_revisionInspector showRevision:commit repository:root stash:stashes completion:^{
		GitWorkspaceViewController* self = weakSelf;
		if(!self) return;
		self->_emptyPreview.hidden = YES;
		self->_diff.hidden = YES;
		self->_revisionInspector.hidden = NO;
	}];
}
@end
