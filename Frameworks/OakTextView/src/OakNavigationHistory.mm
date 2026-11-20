#import "OakNavigationHistory.h"

NSNotificationName const OakNavigationHistoryDidChangeNotification = @"OakNavigationHistoryDidChangeNotification";

static NSUInteger const kNavigationHistoryLimit = 100;

@implementation OakNavigationEntry
- (instancetype)initWithPath:(NSString*)path selection:(text::range_t)selection
{
	if((self = [super init]))
	{
		_path     = path;
		_selection = selection;
	}
	return self;
}

- (BOOL)isEqualToEntry:(OakNavigationEntry*)entry
{
	return entry && [_path isEqualToString:entry.path] && _selection == entry.selection;
}

- (BOOL)isEqual:(id)object
{
	return [self isEqualToEntry:object];
}

- (NSUInteger)hash
{
	return _path.hash ^ std::hash<size_t>{}(_selection.min().line) ^ std::hash<size_t>{}(_selection.max().line);
}
@end

@implementation OakNavigationHistory
{
	NSMutableArray<OakNavigationEntry*>* _backStack;
	NSMutableArray<OakNavigationEntry*>* _forwardStack;
}

+ (instancetype)sharedInstance
{
	static OakNavigationHistory* sharedInstance = [self new];
	return sharedInstance;
}

- (instancetype)init
{
	if((self = [super init]))
	{
		_backStack    = [NSMutableArray new];
		_forwardStack = [NSMutableArray new];
	}
	return self;
}

- (void)recordLocationForDocument:(OakDocument*)document selection:(text::range_t)selection
{
	if(!document.path)
		return;

	// Avoid stacking identical positions from repeated jumps to the same spot.
	if(_backStack.count)
	{
		OakNavigationEntry* top = _backStack.lastObject;
		if([top.path isEqualToString:document.path] && top.selection == selection)
			return;
	}

	[_backStack addObject:[[OakNavigationEntry alloc] initWithPath:document.path selection:selection]];
	if(_backStack.count > kNavigationHistoryLimit)
		[_backStack removeObjectAtIndex:0];
	[_forwardStack removeAllObjects];
	[self notifyChange];
}

- (BOOL)goBackFromDocument:(OakDocument*)document selection:(text::range_t)selection jump:(void(^)(NSString* path, text::range_t selection))jump
{
	if(_backStack.count == 0)
		return NO;

	if(document.path)
	{
		OakNavigationEntry* current = [[OakNavigationEntry alloc] initWithPath:document.path selection:selection];
		if(_forwardStack.count == 0 || ![_forwardStack.lastObject isEqualToEntry:current])
			[_forwardStack addObject:current];
	}

	OakNavigationEntry* target = _backStack.lastObject;
	[_backStack removeLastObject];
	[self notifyChange];
	jump(target.path, target.selection);
	return YES;
}

- (BOOL)goForwardFromDocument:(OakDocument*)document selection:(text::range_t)selection jump:(void(^)(NSString* path, text::range_t selection))jump
{
	if(_forwardStack.count == 0)
		return NO;

	if(document.path)
	{
		OakNavigationEntry* current = [[OakNavigationEntry alloc] initWithPath:document.path selection:selection];
		if(_backStack.count == 0 || ![_backStack.lastObject isEqualToEntry:current])
			[_backStack addObject:current];
	}

	OakNavigationEntry* target = _forwardStack.lastObject;
	[_forwardStack removeLastObject];
	[self notifyChange];
	jump(target.path, target.selection);
	return YES;
}

- (BOOL)canGoBack    { return _backStack.count != 0;    }
- (BOOL)canGoForward { return _forwardStack.count != 0; }

- (void)notifyChange
{
	[NSNotificationCenter.defaultCenter postNotificationName:OakNavigationHistoryDidChangeNotification object:self];
}
@end
