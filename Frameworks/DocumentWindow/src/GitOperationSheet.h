#import <Cocoa/Cocoa.h>

@interface GitOperationSheet : NSView
- (instancetype)initWithTitle:(NSString*)title detail:(NSString*)detail helpTopic:(NSString*)helpTopic;
- (void)addField:(NSControl*)control label:(NSString*)label;
- (NSButton*)addOption:(NSString*)title detail:(NSString*)detail;
- (void)setControls:(NSArray<NSControl*>*)controls enabledWhen:(NSButton*)option checked:(BOOL)checked;
- (void)beginOptions;
- (void)requireBranch:(NSComboBox*)branch remote:(NSPopUpButton*)remote;
- (void)presentInWindow:(NSWindow*)parent firstResponder:(NSView*)firstResponder accept:(void(^)(void))accept;
@end
