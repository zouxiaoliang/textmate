#import "OFBHeaderView.h"
#import <OakAppKit/OakAppKit.h>
#import <OakAppKit/OakUIConstructionFunctions.h>

static NSButton* OakCreateImageButton (NSString* imageName)
{
	NSButton* res = [[NSButton alloc] initWithFrame:NSZeroRect];
	[res setButtonType:NSButtonTypeMomentaryChange];
	[res setBordered:NO];
	[res setImage:[NSImage imageNamed:imageName]];
	[res setImagePosition:NSImageOnly];
	return res;
}

static NSPopUpButton* OakCreateFolderPopUpButton ()
{
	NSPopUpButton* res = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
	[res setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	[res setContentHuggingPriority:NSLayoutPriorityFittingSizeCompression forOrientation:NSLayoutConstraintOrientationHorizontal];
	[res setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
	[res setBordered:NO];
	res.font = [NSFont systemFontOfSize:12];
	return res;
}

@implementation OFBHeaderView
- (id)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		_folderDisclosureButton = [NSButton buttonWithTitle:@"" target:nil action:nil];
		_folderDisclosureButton.bordered = NO;
		_folderDisclosureButton.imagePosition = NSImageOnly;
		_folderDisclosureButton.imageScaling = NSImageScaleNone;
		_folderDisclosureButton.accessibilityRole = NSAccessibilityDisclosureTriangleRole;
		_folderDisclosureButton.accessibilityLabel = @"Current folder contents";
		[self updateFolderDisclosureForCollapsed:NO];

		self.folderPopUpButton       = OakCreateFolderPopUpButton();
		self.goBackButton            = OakCreateImageButton(NSImageNameGoLeftTemplate);
		self.goBackButton.toolTip    = @"Go Back";
		self.goForwardButton         = OakCreateImageButton(NSImageNameGoRightTemplate);
		self.goForwardButton.toolTip = @"Go Forward";

		self.folderPopUpButton.accessibilityLabel           = @"Current folder";
		self.goBackButton.image.accessibilityDescription    = self.goBackButton.toolTip;
		self.goForwardButton.image.accessibilityDescription = self.goForwardButton.toolTip;

		NSDictionary* views = @{
			@"disclosure":    self.folderDisclosureButton,
			@"folder":        self.folderPopUpButton,
			@"divider":       OakCreateNSBoxSeparator(),
			@"back":          self.goBackButton,
			@"forward":       self.goForwardButton,
		};

		OakAddAutoLayoutViewsToSuperview([views allValues], self);
		OakSetupKeyViewLoop(@[ self, _folderDisclosureButton, _folderPopUpButton, _goBackButton, _goForwardButton ]);

		NSDictionary* metrics = @{
			@"disclosureInset": @(kOakSidebarDisclosureCenter - 9),
		};
		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-disclosureInset-[disclosure(18)][folder(>=20)]-3-[divider(1)]-2-[back(22)]-2-[forward(==back)]-3-|" options:NSLayoutFormatAlignAllCenterY metrics:metrics views:views]];
		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-4-[divider(==15)]-4-|" options:0 metrics:nil views:views]];
		[_folderDisclosureButton.heightAnchor constraintEqualToConstant:20].active = YES;
	}
	return self;
}

- (void)updateFolderDisclosureForCollapsed:(BOOL)collapsed
{
	static NSImage* const collapsedChevron = OakSidebarDisclosureImage(NO, 12);
	static NSImage* const expandedChevron = OakSidebarDisclosureImage(YES, 12);
	self.folderDisclosureButton.image = collapsed ? collapsedChevron : expandedChevron;
	self.folderDisclosureButton.accessibilityExpanded = !collapsed;
	self.folderDisclosureButton.toolTip = collapsed ? @"Expand current folder" : @"Collapse current folder";
}
@end
