#import "OFBActionsView.h"
#import <OakAppKit/OakAppKit.h>
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <OakAppKit/NSImage Additions.h>

static CGFloat const kActionWidth = 19;
static CGFloat const kMenuWidth = 30;
static CGFloat const kActionSpacing = 2;

@interface OFBActionsView ()
@property (nonatomic) NSArray<NSButton*>* toolbarButtons;
@end

static NSButton* OakCreateImageButton (NSImage* image)
{
	NSButton* res = [NSButton new];
	[res setButtonType:NSButtonTypeMomentaryChange];
	[res setBordered:NO];
	[res setImage:image];
	[res setImagePosition:NSImageOnly];
	return res;
}

@implementation OFBActionsView
- (id)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		self.createButton       = OakCreateImageButton([NSImage imageNamed:NSImageNameAddTemplate]);
		self.actionsPopUpButton = OakCreateActionPopUpButton();
		self.reloadButton       = OakCreateImageButton([NSImage imageNamed:NSImageNameRefreshTemplate]);
		self.searchButton       = OakCreateImageButton([NSImage imageNamed:@"SearchTemplate" inSameBundleAsClass:[self class]]);
		self.favoritesButton    = OakCreateImageButton([NSImage imageNamed:@"FavoritesTemplate" inSameBundleAsClass:[self class]]);
		self.scmButton          = OakCreateImageButton([NSImage imageNamed:@"SCMTemplate" inSameBundleAsClass:[self class]]);

		self.createButton.toolTip       = @"Create new file";
		self.reloadButton.toolTip       = @"Reload file browser";
		self.searchButton.toolTip       = @"Search current folder";
		self.favoritesButton.toolTip    = @"Show favorites";
		self.scmButton.toolTip          = @"Show source control management status";

		self.reloadButton.image.accessibilityDescription    = self.reloadButton.toolTip;
		self.createButton.image.accessibilityDescription    = self.createButton.toolTip;
		self.searchButton.image.accessibilityDescription    = self.searchButton.toolTip;
		self.favoritesButton.image.accessibilityDescription = self.favoritesButton.toolTip;
		self.scmButton.image.accessibilityDescription       = self.scmButton.toolTip;

		NSPopUpButtonCell* actionsCell = (NSPopUpButtonCell*)_actionsPopUpButton.cell;
		actionsCell.arrowPosition = NSPopUpNoArrow;
		actionsCell.imagePosition = NSImageOnly;
		actionsCell.menuItem.image = [[NSImage imageWithSystemSymbolName:@"ellipsis" accessibilityDescription:nil]
			imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium]];
		self.actionsPopUpButton.toolTip = @"Project Actions";
		self.actionsPopUpButton.accessibilityLabel = self.actionsPopUpButton.toolTip;
		_toolbarButtons = @[ _createButton, _reloadButton, _searchButton, _favoritesButton, _scmButton ];
		NSArray<NSButton*>* buttons = [_toolbarButtons arrayByAddingObject:_actionsPopUpButton];
		for(NSButton* button in buttons)
			[self addSubview:button];
		[self setContentCompressionResistancePriority:NSLayoutPriorityDragThatCannotResizeWindow - 2 forOrientation:NSLayoutConstraintOrientationHorizontal];
		[self setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
		[self.widthAnchor constraintGreaterThanOrEqualToConstant:kMenuWidth].active = YES;
		OakSetupKeyViewLoop([@[ self ] arrayByAddingObjectsFromArray:buttons]);
	}
	return self;
}

- (NSSize)intrinsicContentSize
{
	return NSMakeSize(kMenuWidth + self.toolbarButtons.count * (kActionWidth + kActionSpacing), 22);
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
	[self setNeedsLayout:YES];
}

- (void)layout
{
	[super layout];
	CGFloat width = NSWidth(self.bounds);
	CGFloat buttonSpacing = kActionWidth + kActionSpacing;
	NSUInteger buttonCount = MIN(self.toolbarButtons.count, (NSUInteger)MAX(0, floor((width - kMenuWidth) / buttonSpacing)));
	CGFloat offset = width - kMenuWidth - buttonCount * buttonSpacing;
	BOOL rightToLeft = self.userInterfaceLayoutDirection == NSUserInterfaceLayoutDirectionRightToLeft;
	NSUInteger index = 0;
	for(NSButton* button in self.toolbarButtons)
	{
		button.hidden = index++ >= buttonCount;
		if(!button.hidden)
		{
			button.frame = NSMakeRect(rightToLeft ? width - offset - kActionWidth : offset, 0, kActionWidth, NSHeight(self.bounds));
			offset += buttonSpacing;
		}
	}
	self.actionsPopUpButton.frame = NSMakeRect(rightToLeft ? 0 : width - kMenuWidth, 0, kMenuWidth, NSHeight(self.bounds));
}
@end
