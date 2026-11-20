#import "OutlineViewController.h"
#import "outline_tree.h"
#import <document/OakDocument.h>
#import <document/OakDocument Private.h>
#import <lsp/LSPManager.h>
#import <selection/types.h>
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <OakFoundation/OakFoundation.h>
#import <OakFoundation/NSString Additions.h>
#import <ns/ns.h>

// The wire values are defined by LSP SymbolKind.
typedef NS_ENUM(NSInteger, OutlineSymbolKind) {
	OutlineSymbolUnknown = 0,
	OutlineSymbolFile = 1, OutlineSymbolModule, OutlineSymbolNamespace, OutlineSymbolPackage,
	OutlineSymbolClass, OutlineSymbolMethod, OutlineSymbolProperty, OutlineSymbolField, OutlineSymbolConstructor,
	OutlineSymbolEnum, OutlineSymbolInterface, OutlineSymbolFunction, OutlineSymbolVariable, OutlineSymbolConstant,
	OutlineSymbolString, OutlineSymbolNumber, OutlineSymbolBoolean, OutlineSymbolArray, OutlineSymbolObject,
	OutlineSymbolKey, OutlineSymbolNull, OutlineSymbolEnumMember, OutlineSymbolStruct, OutlineSymbolEvent,
	OutlineSymbolOperator, OutlineSymbolTypeParameter,
};

@interface OutlineSymbolItem : NSObject
@property (nonatomic) NSString* name;
@property (nonatomic) NSString* selection; // “line:column” for OakTextView.selectionString
@property (nonatomic) NSUInteger line;     // 0-based, for following the caret
@property (nonatomic) OutlineSymbolKind kind;
@property (nonatomic, weak) OutlineSymbolItem* parent;
@property (nonatomic) NSMutableArray<OutlineSymbolItem*>* children;
@end

@implementation OutlineSymbolItem
- (NSString*)description { return self.name; }
@end

namespace
{
	struct outline_entry_t
	{
		std::string name;
		size_t line   = 0;
		size_t column = 0;
		size_t depth  = 0;
		OutlineSymbolKind kind = OutlineSymbolUnknown;
	};

	OutlineSymbolKind grammar_symbol_kind (scope::scope_t const& scope)
	{
		static scope::selector_t const function("entity.name.function");
		static scope::selector_t const module("entity.name.namespace | entity.name.module | entity.name.package");
		static scope::selector_t const type("entity.name.type");
		static scope::selector_t const value("variable | constant");
		if(function.does_match(scope)) return OutlineSymbolFunction;
		if(module.does_match(scope)) return OutlineSymbolNamespace;
		if(type.does_match(scope)) return OutlineSymbolClass;
		if(value.does_match(scope)) return OutlineSymbolVariable;
		return OutlineSymbolUnknown;
	}

	NSImage* symbol_image (OutlineSymbolKind kind, BOOL hasChildren)
	{
		NSString* symbol;
		switch(kind)
		{
			case OutlineSymbolFile: symbol = @"doc"; break;
			case OutlineSymbolModule: case OutlineSymbolNamespace: case OutlineSymbolPackage: symbol = @"shippingbox"; break;
			case OutlineSymbolClass: case OutlineSymbolInterface: case OutlineSymbolStruct: case OutlineSymbolTypeParameter: symbol = @"cube"; break;
			case OutlineSymbolMethod: case OutlineSymbolConstructor: case OutlineSymbolFunction: case OutlineSymbolOperator: symbol = @"function"; break;
			case OutlineSymbolEnum: case OutlineSymbolEnumMember: case OutlineSymbolArray: case OutlineSymbolObject: symbol = @"list.bullet"; break;
			case OutlineSymbolProperty: case OutlineSymbolField: case OutlineSymbolVariable: case OutlineSymbolConstant: case OutlineSymbolKey: symbol = @"diamond"; break;
			case OutlineSymbolString: symbol = @"textformat"; break;
			case OutlineSymbolNumber: symbol = @"number"; break;
			case OutlineSymbolBoolean: case OutlineSymbolNull: symbol = @"circle.lefthalf.filled"; break;
			case OutlineSymbolEvent: symbol = @"bolt"; break;
			default: symbol = hasChildren ? @"list.bullet" : @"circle"; break;
		}
		return [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]
			imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium]];
	}

	// Flatten an LSP documentSymbol response (DocumentSymbol[] tree or
	// SymbolInformation[] list) into entries with 0-based line/column,
	// ordered depth-first. Mirrors OakDocumentView’s FlattenDocumentSymbols.
	void flatten_lsp_symbols (NSArray* nodes, NSUInteger depth, std::vector<outline_entry_t>& out)
	{
		for(NSDictionary* node in nodes)
		{
			if([node isKindOfClass:[NSDictionary class]] == NO)
				continue;

			NSString* name = node[@"name"];
			NSDictionary* start = node[@"selectionRange"][@"start"] ?: node[@"location"][@"range"][@"start"];
			if(!name || !start)
				continue;

			outline_entry_t entry;
			entry.name   = to_s(name);
			entry.line   = [start[@"line"] unsignedIntegerValue];
			entry.column = [start[@"character"] unsignedIntegerValue];
			entry.depth  = depth;
			if(NSNumber* kind = [node[@"kind"] isKindOfClass:NSNumber.class] ? node[@"kind"] : nil)
				entry.kind = (OutlineSymbolKind)kind.integerValue;
			out.push_back(entry);

			if([node[@"children"] isKindOfClass:[NSArray class]])
				flatten_lsp_symbols(node[@"children"], depth + 1, out);
		}
	}
}

@interface OutlineViewController () <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property (nonatomic) NSOutlineView* outlineView;
@property (nonatomic) NSArray<OutlineSymbolItem*>* roots;
@property (nonatomic) NSArray<OutlineSymbolItem*>* flatItems; // depth-first, document order
@property (nonatomic) NSMutableSet<NSString*>* expandedKeys;
@property (nonatomic) NSTimer* reloadTimer;
@property (nonatomic) dispatch_block_t lspCancel;
@property (nonatomic) BOOL programmaticSelection;
@end

@implementation OutlineViewController
- (instancetype)initWithNibName:(NSString*)nibNameOrNil bundle:(NSBundle*)nibBundleOrNil
{
	if(self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil])
	{
		_expandedKeys = [NSMutableSet set];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(lspServerStatusDidChange:) name:LSPServerStatusDidChangeNotification object:nil];
	}
	return self;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
	[_reloadTimer invalidate];
	if(_lspCancel) _lspCancel();
}

- (void)loadView
{
	_outlineView = [[OakSidebarTreeView alloc] initWithFrame:NSZeroRect];
	_outlineView.accessibilityLabel       = @"Outline";
	_outlineView.allowsMultipleSelection  = NO;
	_outlineView.autoresizesOutlineColumn = NO;
	_outlineView.focusRingType            = NSFocusRingTypeNone;
	_outlineView.headerView               = nil;
	_outlineView.style                    = NSTableViewStylePlain;
	_outlineView.backgroundColor          = NSColor.controlBackgroundColor;
	_outlineView.rowHeight                = 21;
	_outlineView.delegate                 = self;
	_outlineView.dataSource               = self;
	_outlineView.target                   = self;
	_outlineView.doubleAction             = @selector(takeSymbolFromSender:);

	NSTableColumn* tableColumn = [[NSTableColumn alloc] initWithIdentifier:@"symbol"];
	[_outlineView addTableColumn:tableColumn];
	[_outlineView setOutlineTableColumn:tableColumn];
	[_outlineView sizeLastColumnToFit];

	NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	scrollView.borderType            = NSNoBorder;
	scrollView.documentView          = _outlineView;
	scrollView.hasHorizontalScroller = NO;
	scrollView.hasVerticalScroller   = YES;
	scrollView.autohidesScrollers    = YES;
	scrollView.drawsBackground       = NO;

	self.view                   = [[NSView alloc] initWithFrame:NSZeroRect];
	self.view.accessibilityRole = NSAccessibilityGroupRole;
	self.view.accessibilityLabel = @"Outline";
	OakAddAutoLayoutViewsToSuperview(@[ scrollView ], self.view);
	[NSLayoutConstraint activateConstraints:@[
		[scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
	]];
}

// ================================
// = Document and panel lifecycle =
// ================================

- (void)setDocument:(OakDocument*)newDocument
{
	if(_document == newDocument)
		return;

	if(_document)
	{
		[NSNotificationCenter.defaultCenter removeObserver:self name:OakDocumentContentDidChangeNotification object:_document];
		[NSNotificationCenter.defaultCenter removeObserver:self name:OakDocumentDidReloadNotification object:_document];
		[NSNotificationCenter.defaultCenter removeObserver:self name:LSPDocumentDidOpenNotification object:_document];
	}
	_document = newDocument;
	if(_document)
	{
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentDidChange:) name:OakDocumentContentDidChangeNotification object:_document];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentDidChange:) name:OakDocumentDidReloadNotification object:_document];
		// The initial symbol request may precede didOpen when a server is starting.
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentDidChange:) name:LSPDocumentDidOpenNotification object:_document];
	}

	if(self.panelVisible)
		[self reloadNow];
}

- (void)setPanelVisible:(BOOL)flag
{
	if(_panelVisible == flag)
		return;
	_panelVisible = flag;
	if(flag)
		[self reloadNow];
	else
		[self cancelPendingReload];
}

- (void)cancelPendingReload
{
	[_reloadTimer invalidate];
	_reloadTimer = nil;
	if(_lspCancel) { _lspCancel(); _lspCancel = nil; }
}

- (void)scheduleReload
{
	if(!self.panelVisible)
		return;
	[_reloadTimer invalidate];
	_reloadTimer = [NSTimer scheduledTimerWithTimeInterval:0.3 target:self selector:@selector(reloadTimerFired:) userInfo:nil repeats:NO];
}

- (void)documentDidChange:(NSNotification*)aNotification
{
	[self scheduleReload];
}

- (void)lspServerStatusDidChange:(NSNotification*)aNotification
{
	// The server may have more symbols after a change in indexing status.
	if(self.panelVisible && self.document && [[LSPManager sharedManager] hasClientForDocument:self.document])
		[self scheduleReload];
}

- (void)reloadTimerFired:(NSTimer*)aTimer
{
	_reloadTimer = nil;
	[self reloadNow];
}

- (void)reloadNow
{
	if(!self.panelVisible)
		return;

	[self cancelPendingReload];
	[self rebuildFromGrammarSymbols];
	[self requestLSPDocumentSymbols];
	[self refreshSelectionFromCaret];
}

// =====================
// = Symbol collection =
// =====================

- (void)rebuildFromGrammarSymbols
{
	__block std::vector<outline_entry_t> entries;
	OakDocument* document = self.document;
	[document enumerateSymbolsUsingBlock:^(text::pos_t const& pos, NSString* symbol){
		outline_entry_t entry;
		entry.line   = pos.line;
		entry.column = pos.column;
		entry.depth  = oak::outline_symbol_depth(to_s(symbol), entry.name);
		ng::buffer_t const& buffer = [document buffer];
		entry.kind   = grammar_symbol_kind(buffer.scope(buffer.convert(pos), false).right);
		entries.push_back(entry);
	}];

	entries.erase(std::remove_if(entries.begin(), entries.end(), [](outline_entry_t const& entry){
		return oak::outline_is_separator(entry.name) || entry.name.empty();
	}), entries.end());

	[self rebuildTreeWithEntries:entries];
}

- (void)requestLSPDocumentSymbols
{
	if(_lspCancel) { _lspCancel(); _lspCancel = nil; }

	OakDocument* document = self.document;
	if(!document.path || ![[LSPManager sharedManager] hasClientForDocument:document])
		return;

	__weak OutlineViewController* weakSelf = self;
	_lspCancel = [LSPManager.sharedManager requestDocumentSymbolsForDocument:document completion:^(NSArray* symbols){
		dispatch_async(dispatch_get_main_queue(), ^{
			OutlineViewController* strongSelf = weakSelf;
			if(!strongSelf || strongSelf.document != document || !strongSelf.panelVisible)
				return;

			[strongSelf rebuildFromLSPDocumentSymbols:symbols];
		});
	}];
}

- (void)rebuildFromLSPDocumentSymbols:(id)response
{
	std::vector<outline_entry_t> entries;
	if([response isKindOfClass:NSArray.class])
		flatten_lsp_symbols(response, 0, entries);
	if(!entries.empty()) // keep grammar-derived symbols when the server has nothing
		[self rebuildTreeWithEntries:entries];
}

- (void)rebuildTreeWithEntries:(std::vector<outline_entry_t> const&)entries
{
	std::vector<size_t> depths;
	depths.reserve(entries.size());
	for(auto const& entry : entries)
		depths.push_back(entry.depth);
	std::vector<std::ptrdiff_t> const parents = oak::outline_parents(oak::outline_normalized_depths(depths));

	NSMutableArray<OutlineSymbolItem*>* items = [NSMutableArray array];
	for(size_t i = 0; i < entries.size(); ++i)
	{
		OutlineSymbolItem* item = [[OutlineSymbolItem alloc] init];
		item.name      = [NSString stringWithCxxString:entries[i].name];
		item.line      = entries[i].line;
		item.kind      = entries[i].kind;
		item.selection = [NSString stringWithCxxString:text::pos_t(entries[i].line, entries[i].column)];
		[items addObject:item];
	}

	NSMutableArray<OutlineSymbolItem*>* roots = [NSMutableArray array];
	for(size_t i = 0; i < entries.size(); ++i)
	{
		OutlineSymbolItem* item = items[i];
		std::ptrdiff_t const parent = parents[i];
		if(parent == -1)
		{
			[roots addObject:item];
		}
		else
		{
			OutlineSymbolItem* parentItem = items[parent];
			if(!parentItem.children)
				parentItem.children = [NSMutableArray array];
			item.parent = parentItem;
			[parentItem.children addObject:item];
		}
	}

	self.roots     = roots;
	self.flatItems = items;

	[self.outlineView reloadData];

	// Restore what the user had expanded before the reload.
	if(self.expandedKeys.count)
	{
		for(OutlineSymbolItem* item in items)
		{
			if(!item.children.count)
				continue;
			if([self.expandedKeys containsObject:[self keyPathForItem:item]])
				[self.outlineView expandItem:item];
		}
	}
}

- (NSString*)keyPathForItem:(OutlineSymbolItem*)anItem
{
	NSMutableArray<NSString*>* names = [NSMutableArray array];
	for(OutlineSymbolItem* item = anItem; item; item = item.parent)
		[names insertObject:item.name atIndex:0];
	return [names componentsJoinedByString:@"\x1F"];
}

// ================================
// = Selection and current symbol =
// ================================

- (NSString*)selectedSelectionString
{
	NSInteger const row = self.outlineView.selectedRow;
	if(row == -1)
		return nil;
	OutlineSymbolItem* item = [self.outlineView itemAtRow:row];
	return item.selection;
}

- (IBAction)takeSymbolFromSender:(id)sender
{
	if(self.selectedSelectionString && _target && _action && [_target respondsToSelector:_action])
		[_target performSelector:_action withObject:self];
}

- (void)setSelectionString:(NSString*)aSelectionString
{
	if(_selectionString == aSelectionString || [_selectionString isEqualToString:aSelectionString])
		return;
	_selectionString = [aSelectionString copy];
	[self refreshSelectionFromCaret];
}

- (void)refreshSelectionFromCaret
{
	if(!self.panelVisible || self.flatItems.count == 0)
		return;

	// “line:column” (1-based line) with an optional “-line:column” range suffix.
	unsigned long long caretLine = 0;
	NSScanner* scanner = [NSScanner scannerWithString:_selectionString ?: @""];
	if(![scanner scanUnsignedLongLong:&caretLine] || caretLine == 0)
		return;
	caretLine -= 1;

	OutlineSymbolItem* current = nil;
	for(OutlineSymbolItem* item in self.flatItems) // depth-first, document order
	{
		if(item.line > caretLine)
			break;
		current = item;
	}
	if(!current)
		return;

	NSInteger row = [self.outlineView rowForItem:current];
	if(row == -1) // hidden behind a collapsed ancestor: reveal it
	{
		NSMutableArray<OutlineSymbolItem*>* ancestors = [NSMutableArray array];
		for(OutlineSymbolItem* ancestor = current.parent; ancestor; ancestor = ancestor.parent)
			[ancestors addObject:ancestor];
		for(OutlineSymbolItem* ancestor in ancestors.reverseObjectEnumerator)
			[self.outlineView expandItem:ancestor];
		row = [self.outlineView rowForItem:current];
		if(row == -1)
			return;
	}

	if(row == self.outlineView.selectedRow)
		return;

	NSRange const visible = [self.outlineView rowsInRect:self.outlineView.visibleRect];
	if(!NSLocationInRange((NSUInteger)row, visible))
		[self.outlineView scrollRowToVisible:row];

	self.programmaticSelection = YES;
	[self.outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	self.programmaticSelection = NO;
}

// =============================
// = NSOutlineView data source =
// =============================

- (NSInteger)outlineView:(NSOutlineView*)outlineView numberOfChildrenOfItem:(id)item
{
	return item ? [(OutlineSymbolItem*)item children].count : self.roots.count;
}

- (id)outlineView:(NSOutlineView*)outlineView child:(NSInteger)index ofItem:(id)item
{
	return item ? [(OutlineSymbolItem*)item children][index] : self.roots[index];
}

- (BOOL)outlineView:(NSOutlineView*)outlineView isItemExpandable:(id)item
{
	return [(OutlineSymbolItem*)item children].count > 0;
}

- (id)outlineView:(NSOutlineView*)outlineView objectValueForTableColumn:(NSTableColumn*)tableColumn byItem:(id)item
{
	return [(OutlineSymbolItem*)item name];
}

- (NSTableRowView*)outlineView:(NSOutlineView*)outlineView rowViewForItem:(id)item
{
	return [(OakSidebarTreeView*)outlineView makeTreeRowView];
}

- (NSView*)outlineView:(NSOutlineView*)outlineView viewForTableColumn:(NSTableColumn*)tableColumn item:(OutlineSymbolItem*)item
{
	NSTableCellView* res = [outlineView makeViewWithIdentifier:tableColumn.identifier owner:self];
	if(!res)
	{
		res = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
		res.identifier = tableColumn.identifier;
		res.clipsToBounds = YES;

		NSTextField* textField = OakCreateLabel(@"", [NSFont systemFontOfSize:12]);
		NSImageView* imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
		imageView.imageScaling = NSImageScaleProportionallyDown;
		imageView.contentTintColor = NSColor.secondaryLabelColor;
		imageView.accessibilityElement = NO;
		res.imageView = imageView;
		res.textField = textField;
		OakAddAutoLayoutViewsToSuperview(@[ imageView, textField ], res);
		NSLayoutConstraint* trailing = [textField.trailingAnchor constraintEqualToAnchor:res.trailingAnchor constant:-8];
		trailing.priority = NSLayoutPriorityDefaultHigh;
		[NSLayoutConstraint activateConstraints:@[
			[imageView.leadingAnchor constraintEqualToAnchor:res.leadingAnchor],
			[imageView.centerYAnchor constraintEqualToAnchor:res.centerYAnchor],
			[imageView.widthAnchor constraintEqualToConstant:16],
			[imageView.heightAnchor constraintEqualToConstant:16],
			[textField.leadingAnchor constraintEqualToAnchor:imageView.trailingAnchor constant:2],
			trailing,
			[textField.centerYAnchor constraintEqualToAnchor:res.centerYAnchor],
		]];
	}
	res.textField.stringValue = item.name;
	res.imageView.image = symbol_image(item.kind, item.children.count > 0);
	return res;
}

// ==========
// = Delegate =
// ==========

- (void)outlineViewSelectionDidChange:(NSNotification*)notification
{
	if(self.programmaticSelection)
		return;
	[self takeSymbolFromSender:self];
}

- (void)outlineViewItemDidExpand:(NSNotification*)notification
{
	OutlineSymbolItem* item = notification.userInfo[@"NSObject"];
	if(item.children.count)
		[self.expandedKeys addObject:[self keyPathForItem:item]];
}

- (void)outlineViewItemDidCollapse:(NSNotification*)notification
{
	OutlineSymbolItem* item = notification.userInfo[@"NSObject"];
	[self.expandedKeys removeObject:[self keyPathForItem:item]];
}
@end
