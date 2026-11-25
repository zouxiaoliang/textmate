#import "DebugAdapterFraming.h"

static NSUInteger const MaxHeaderLength = 4096;
static NSUInteger const MaxBodyLength = 8 * 1024 * 1024;

NSData* DebugAdapterEncodeMessage(NSDictionary* message)
{
	NSData* body = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
	if(!body.length || body.length > MaxBodyLength)
		return nil;
	NSMutableData* data = [[[NSString stringWithFormat:@"Content-Length: %lu\r\n\r\n", (unsigned long)body.length] dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
	[data appendData:body];
	return data;
}

static id InvalidFrame(NSError** error)
{
	if(error)
		*error = [NSError errorWithDomain:@"TextMate.DebugAdapter" code:1 userInfo:@{ NSLocalizedDescriptionKey: @"Delve sent an invalid debug message." }];
	return nil;
}

@implementation DebugAdapterFraming
{
	NSMutableData* _buffer;
	NSUInteger _bodyLength;
}

- (instancetype)init
{
	if(self = [super init])
		_buffer = [NSMutableData data];
	return self;
}

- (NSArray<NSDictionary*>*)consumeData:(NSData*)data error:(NSError**)error
{
	[_buffer appendData:data];
	NSMutableArray* messages = [NSMutableArray array];
	NSData* delimiter = [NSData dataWithBytes:"\r\n\r\n" length:4];
	while(_buffer.length)
	{
		if(!_bodyLength)
		{
			NSRange end = [_buffer rangeOfData:delimiter options:0 range:NSMakeRange(0, MIN(_buffer.length, MaxHeaderLength))];
			if(end.location == NSNotFound)
				return _buffer.length < MaxHeaderLength ? messages : InvalidFrame(error);
			NSString* header = [[NSString alloc] initWithData:[_buffer subdataWithRange:NSMakeRange(0, end.location)] encoding:NSASCIIStringEncoding];
			for(NSString* field in [header componentsSeparatedByString:@"\r\n"])
			{
				NSRange colon = [field rangeOfString:@":"];
				if(colon.location == NSNotFound)
					return InvalidFrame(error);
				if([[field substringToIndex:colon.location] caseInsensitiveCompare:@"Content-Length"] != NSOrderedSame)
					continue;
				NSString* value = [[field substringFromIndex:NSMaxRange(colon)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
				if(_bodyLength || !value.length || value.length > 8 || [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location != NSNotFound)
					return InvalidFrame(error);
				_bodyLength = (NSUInteger)value.longLongValue;
				if(!_bodyLength || _bodyLength > MaxBodyLength)
					return InvalidFrame(error);
			}
			if(!_bodyLength)
				return InvalidFrame(error);
			[_buffer replaceBytesInRange:NSMakeRange(0, NSMaxRange(end)) withBytes:nil length:0];
		}
		if(_buffer.length < _bodyLength)
			break;
		id object = [NSJSONSerialization JSONObjectWithData:[_buffer subdataWithRange:NSMakeRange(0, _bodyLength)] options:0 error:nil];
		if(![object isKindOfClass:NSDictionary.class])
			return InvalidFrame(error);
		[messages addObject:object];
		[_buffer replaceBytesInRange:NSMakeRange(0, _bodyLength) withBytes:nil length:0];
		_bodyLength = 0;
	}
	return messages;
}
@end
