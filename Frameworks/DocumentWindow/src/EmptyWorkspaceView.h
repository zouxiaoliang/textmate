#import <Cocoa/Cocoa.h>

@interface EmptyWorkspaceView : NSScrollView
@property (nonatomic, readonly) NSTextField* heading;
- (void)setProjectOpen:(BOOL)projectOpen;
- (void)setFileShortcuts:(NSArray<NSArray<NSString*>*>*)files toolShortcuts:(NSArray<NSArray<NSString*>*>*)tools;
@end
