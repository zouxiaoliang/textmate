#import <OakAppKit/OakUIConstructionFunctions.h>

@interface OFBHeaderView : NSView
@property (nonatomic, readonly) NSButton* folderDisclosureButton;
@property (nonatomic) NSPopUpButton* folderPopUpButton;
@property (nonatomic) NSButton* goBackButton;
@property (nonatomic) NSButton* goForwardButton;
- (void)updateFolderDisclosureForCollapsed:(BOOL)collapsed;
@end
