#import <Foundation/Foundation.h>

NSData* DebugAdapterEncodeMessage(NSDictionary* message);

@interface DebugAdapterFraming : NSObject
- (NSArray<NSDictionary*>*)consumeData:(NSData*)data error:(NSError**)error;
@end
