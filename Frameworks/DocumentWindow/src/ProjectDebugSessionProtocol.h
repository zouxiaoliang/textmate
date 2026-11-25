#import "ProjectDebugSession.h"

@interface ProjectDebugSession ()
- (void)beginSessionWithLaunchArguments:(NSDictionary*)arguments breakpoints:(NSDictionary<NSString*, NSArray<NSDictionary*>*>*)breakpoints;
- (void)transportDidConnect;
- (void)receiveBytes:(NSData*)bytes;
- (NSData*)pendingRequestBytes;
- (void)didWriteRequestBytes:(NSUInteger)length;
@end
