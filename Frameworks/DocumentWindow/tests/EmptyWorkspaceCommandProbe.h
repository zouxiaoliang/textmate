#import <Cocoa/Cocoa.h>

@interface EmptyWorkspaceCommandProbe : NSObject <NSMenuItemValidation>
@property (nonatomic) NSMenuItem* invokedItem;
@property (nonatomic) BOOL allowsAction;
@end

@implementation EmptyWorkspaceCommandProbe
- (BOOL)validateMenuItem:(NSMenuItem*)item { return self.allowsAction; }
- (void)orderFrontFindPanel:(NSMenuItem*)item { self.invokedItem = item; }
- (void)openDocument:(NSMenuItem*)item { self.invokedItem = item; }
@end
