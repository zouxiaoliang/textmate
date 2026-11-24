#import <Cocoa/Cocoa.h>

@interface GitGraphTracksView : NSView
// With no node, draw incoming lanes across the whole row for a section heading.
@property (nonatomic, copy) NSDictionary* tracks;
@property (nonatomic) BOOL head;
@end
