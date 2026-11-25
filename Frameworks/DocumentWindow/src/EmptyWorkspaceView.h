#import <Cocoa/Cocoa.h>

@interface EmptyWorkspaceCommandButton : NSButton
- (instancetype)initWithName:(NSString*)name shortcut:(NSString*)shortcut menuItem:(NSMenuItem*)item;
@end

@interface EmptyWorkspaceView : NSScrollView
@property (nonatomic, readonly) NSTextField* heading;
- (void)setProjectOpen:(BOOL)projectOpen;
- (void)setFileCommands:(NSArray<EmptyWorkspaceCommandButton*>*)files toolCommands:(NSArray<EmptyWorkspaceCommandButton*>*)tools;
@end
