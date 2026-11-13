#import "OakWorkspaceSymbolChooser.h"
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <OakFoundation/OakFoundation.h>
#import <OakFoundation/NSString Additions.h>
#import <lsp/LSPManager.h>
#import <ns/ns.h>
#import <text/ranker.h>

@implementation OakWorkspaceSymbolItem
- (id)objectForKey:(id)key { return [self valueForKey:key]; }
@end

static NSString* DisplayPathForPath (NSString* path, NSString* baseDir)
{
	if(baseDir && [path hasPrefix:baseDir] && path.length > baseDir.length)
		return [path substringFromIndex:baseDir.length + 1];
	return path;
}

@implementation OakWorkspaceSymbolChooser
{
	NSUInteger _requestSerial;
	dispatch_block_t _pendingCancel;
}

- (instancetype)initWithBaseDocument:(OakDocument*)document
{
	if((self = [super init]))
	{
		_baseDocument = document;

		self.window.title = @"Go to Symbol in Workspace";

		NSDictionary* titlebarViews = @{
			@"searchField": self.searchField,
		};

		NSView* titlebarView = [[NSView alloc] initWithFrame:NSZeroRect];
		OakAddAutoLayoutViewsToSuperview(titlebarViews.allValues, titlebarView);

		[titlebarView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(8)-[searchField]-(8)-|" options:0 metrics:nil views:titlebarViews]];
		[titlebarView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(4)-[searchField]-(8)-|" options:0 metrics:nil views:titlebarViews]];
		[self addTitlebarAccessoryView:titlebarView];

		NSDictionary* footerViews = @{
			@"dividerView":        OakCreateNSBoxSeparator(),
			@"statusTextField":    self.statusTextField,
			@"itemCountTextField": self.itemCountTextField,
		};

		NSView* footerView = self.footerView;
		OakAddAutoLayoutViewsToSuperview(footerViews.allValues, footerView);

		[footerView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[dividerView]|"                                 options:0 metrics:nil views:footerViews]];
		[footerView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-[statusTextField]-[itemCountTextField]-|"      options:NSLayoutFormatAlignAllCenterY metrics:nil views:footerViews]];
		[footerView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[dividerView(==1)]-(4)-[statusTextField]-(5)-|" options:0 metrics:nil views:footerViews]];

		[self updateScrollViewInsets];

		self.window.initialFirstResponder = self.searchField;
	}
	return self;
}

- (void)dealloc
{
	if(_pendingCancel)
		_pendingCancel();
}

- (void)setBaseDocument:(OakDocument*)aDocument
{
	if(_baseDocument == aDocument)
		return;
	_baseDocument = aDocument;
	[self refreshItems];
}

- (void)refreshItems
{
	[self updateItems:self];
}

- (void)updateItems:(id)sender
{
	if(_pendingCancel)
	{
		_pendingCancel();
		_pendingCancel = nil;
	}
	_requestSerial++;

	NSString* query = self.filterString;
	if(query.length == 0 || !_baseDocument.path)
	{
		self.items = @[];
		return;
	}

	std::string const filter = oak::normalize_filter(to_s(query));
	NSString* baseDir        = _baseDocument.path ? [_baseDocument.path stringByDeletingLastPathComponent] : nil;

	NSUInteger const serial = _requestSerial;
	__weak OakWorkspaceSymbolChooser* weakSelf = self;
	_pendingCancel = [LSPManager.sharedManager requestLanguageQuery:@"workspace/symbol" forDocument:_baseDocument params:@{ @"query": query } completion:^(id raw, NSString* errorCode){
		dispatch_async(dispatch_get_main_queue(), ^{
			OakWorkspaceSymbolChooser* strongSelf = weakSelf;
			if(!strongSelf || strongSelf->_requestSerial != serial)
				return;

			strongSelf->_pendingCancel = nil;
			if(errorCode || ![raw isKindOfClass:[NSArray class]])
			{
				strongSelf.items = @[];
				return;
			}

			std::multimap<double, OakWorkspaceSymbolItem*> ranked;
			for(NSDictionary* si in raw)
			{
				if([si isKindOfClass:[NSDictionary class]] == NO)
					continue;

				NSString* symbolName = si[@"name"];
				NSDictionary* location = si[@"location"];
				NSString* uri = location[@"uri"];
				NSDictionary* start = location[@"range"][@"start"];
				if(OakIsEmptyString(symbolName) || !uri || !start)
					continue;

				NSString* displayName = symbolName;
				NSString* container = si[@"containerName"];
				if(OakIsEmptyString(container) == NO)
					displayName = [NSString stringWithFormat:@"%@ — %@", symbolName, container];

				std::vector< std::pair<size_t, size_t> > ranges;
				double const rank = oak::rank(filter, to_s(displayName), &ranges);
				if(rank == 0)
					continue;

				OakWorkspaceSymbolItem* item = [OakWorkspaceSymbolItem new];
				item.name          = CreateAttributedStringWithMarkedUpRanges(to_s(displayName), ranges, NSLineBreakByTruncatingTail);
				item.containerName = container;
				item.fileURI       = uri;
				item.filePath      = [NSURL URLWithString:uri].path;
				item.displayPath   = DisplayPathForPath(item.filePath ?: @"", baseDir);
				item.line          = [start[@"line"] unsignedIntegerValue];
				item.column        = [start[@"character"] unsignedIntegerValue];
				item.infoString    = [item.displayPath stringByAppendingFormat:@":%@", [NSString stringWithCxxString:text::pos_t(item.line, item.column)]];
				ranked.emplace(1 - rank, item);
			}

			NSMutableArray* res = [NSMutableArray arrayWithCapacity:ranked.size()];
			for(auto const& pair : ranked)
				[res addObject:pair.second];
			strongSelf.items = res;
		});
	}];
}

- (void)updateStatusText:(id)sender
{
	if(self.items.count != 0)
	{
		OakWorkspaceSymbolItem* item = self.items[self.tableView.selectedRow == -1 ? 0 : self.tableView.selectedRow];
		self.statusTextField.stringValue = item.infoString ?: @"";
	}
	else if(self.filterString.length != 0 && _baseDocument.path)
	{
		self.statusTextField.stringValue = @"No symbols found";
	}
	else
	{
		self.statusTextField.stringValue = @"Type to search for symbols in the workspace";
	}
}
@end
