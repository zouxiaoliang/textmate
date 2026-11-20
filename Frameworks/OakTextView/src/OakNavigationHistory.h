#ifndef OAK_NAVIGATION_HISTORY_H_YD3KQW8T
#define OAK_NAVIGATION_HISTORY_H_YD3KQW8T

#import <document/OakDocument.h>
#import <text/types.h>

extern NSNotificationName const OakNavigationHistoryDidChangeNotification;

// One visited location: the file it was in and the selection to restore.
@interface OakNavigationEntry : NSObject
@property (nonatomic, readonly) NSString* path;
@property (nonatomic, readonly) text::range_t selection;
- (instancetype)initWithPath:(NSString*)path selection:(text::range_t)selection;
- (BOOL)isEqualToEntry:(OakNavigationEntry*)entry;
@end

// Back/forward stack for navigation jumps (LSP definition/references,
// symbol outline, …). Entries are keyed by path so jumps can reach
// documents that are not open yet. All methods must be called on the
// main thread.
@interface OakNavigationHistory : NSObject
+ (instancetype)sharedInstance;

// Push the current location onto the back stack before performing a new
// navigation jump. Drops the forward stack.
- (void)recordLocationForDocument:(OakDocument*)document selection:(text::range_t)selection;

// Pop one entry off the back stack (pushing the current location onto the
// forward stack) and hand it to jump. Returns NO (and does not call jump)
// when the back stack is empty.
- (BOOL)goBackFromDocument:(OakDocument*)document selection:(text::range_t)selection jump:(void(^)(NSString* path, text::range_t selection))jump;

// Symmetric to goBackFromDocument:selection:jump:.
- (BOOL)goForwardFromDocument:(OakDocument*)document selection:(text::range_t)selection jump:(void(^)(NSString* path, text::range_t selection))jump;

- (BOOL)canGoBack;
- (BOOL)canGoForward;
@end

#endif /* end of include guard: OAK_NAVIGATION_HISTORY_H_YD3KQW8T */
