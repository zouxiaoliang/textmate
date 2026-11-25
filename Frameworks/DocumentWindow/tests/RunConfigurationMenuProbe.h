#import <Cocoa/Cocoa.h>

@interface RunConfigurationMenuProbe : NSMenu
@property (nonatomic) BOOL opened;
@end

@implementation RunConfigurationMenuProbe
- (BOOL)popUpMenuPositioningItem:(NSMenuItem*)item atLocation:(NSPoint)location inView:(NSView*)view
{
	self.opened = YES;
	OAK_ASSERT(!item);
	OAK_ASSERT_EQ(self.minimumWidth, NSWidth(view.bounds));
	NSPoint anchor = [view convertPoint:location toView:view.window.contentView];
	NSRect button = [view convertRect:view.bounds toView:view.window.contentView];
	OAK_ASSERT_LT(anchor.y, NSMinY(button));
	return NO;
}
@end
