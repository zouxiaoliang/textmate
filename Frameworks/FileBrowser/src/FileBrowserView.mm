#import "FileBrowserView.h"
#import "FileBrowserOutlineView.h"
#import "OFB/OFBHeaderView.h"
#import "OFB/OFBActionsView.h"
#import <OakAppKit/OakUIConstructionFunctions.h>

@interface FileBrowserView () <NSAccessibilityGroup>
@property (nonatomic) NSScrollView* scrollView;
@end

@implementation FileBrowserView
- (instancetype)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		self.accessibilityRole  = NSAccessibilityGroupRole;
		self.accessibilityLabel = @"File browser";

		_headerView    = [[OFBHeaderView alloc] initWithFrame:NSZeroRect];
		_actionsView   = [[OFBActionsView alloc] initWithFrame:NSZeroRect];

		_outlineView = [[FileBrowserOutlineView alloc] initWithFrame:NSZeroRect];
		_outlineView.accessibilityLabel       = @"Files";
		_outlineView.allowsMultipleSelection  = YES;
		_outlineView.autoresizesOutlineColumn = NO;
		_outlineView.focusRingType            = NSFocusRingTypeNone;
		_outlineView.headerView               = nil;

		if(@available(macos 11.0, *))
		{
			_outlineView.style = NSTableViewStylePlain;
			_outlineView.floatsGroupRows = NO;
		}

		[_outlineView setDraggingSourceOperationMask:NSDragOperationLink|NSDragOperationMove|NSDragOperationCopy forLocal:YES];
		[_outlineView setDraggingSourceOperationMask:NSDragOperationEvery forLocal:NO];
		[_outlineView registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];

		NSTableColumn* tableColumn = [[NSTableColumn alloc] init];
		[_outlineView addTableColumn:tableColumn];
		[_outlineView setOutlineTableColumn:tableColumn];
		[_outlineView sizeLastColumnToFit];

		_scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
		_scrollView.borderType            = NSNoBorder;
		_scrollView.documentView          = _outlineView;
		_scrollView.hasHorizontalScroller = NO;
		_scrollView.hasVerticalScroller   = YES;
		_scrollView.autohidesScrollers    = YES;

		NSDictionary* views = @{
			@"header":  _headerView,
			@"files":   _scrollView,
		};

		OakAddAutoLayoutViewsToSuperview(views.allValues, self);

		OakSetupKeyViewLoop(@[ self, _headerView, _outlineView ]);

		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[files(==header)]|" options:0 metrics:nil views:views]];
		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[header][files]|" options:NSLayoutFormatAlignAllLeading metrics:nil views:views]];
		_scrollView.automaticallyAdjustsContentInsets = NO;
		_outlineView.backgroundColor = NSColor.controlBackgroundColor;
		_scrollView.drawsBackground  = NO;
	}
	return self;
}
@end
