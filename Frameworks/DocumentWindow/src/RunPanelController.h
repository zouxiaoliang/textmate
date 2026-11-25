#import <Cocoa/Cocoa.h>

@interface RunPanelController : NSViewController
@property (nonatomic, copy) NSArray<NSDictionary<NSString*, NSString*>*>* (^foldersProvider)(void);
@property (nonatomic, copy) NSString* (^fileProvider)(void);
@property (nonatomic, copy) NSDictionary<NSString*, NSArray<NSDictionary*>*>* (^breakpointsProvider)(void);
@property (nonatomic, copy) void (^updateBreakpoint)(NSString* path, NSUInteger line, NSDictionary* breakpoint);
@property (nonatomic, copy) void (^breakpointResultsDidChange)(void);
@property (nonatomic, copy) void (^showFrame)(NSString* path, NSUInteger line, BOOL executionLine);
@property (nonatomic, copy) void (^clearExecutionLine)(void);
@property (nonatomic, copy) void (^openConfiguration)(NSURL* url);
@property (nonatomic, copy) void (^hideHandler)(void);
@property (nonatomic, copy) void (^showOutputHandler)(void);
@property (nonatomic, copy) NSArray<NSString*>* watchExpressions;
@property (nonatomic, copy) void (^watchExpressionsDidChange)(void);
@property (nonatomic, readonly) NSView* outputView;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) BOOL canStep;
@property (nonatomic, readonly) BOOL canRestart;
- (void)attachDebugToolbarToView:(NSView*)container aboveEditor:(NSView*)editor;
- (void)showOutputInWindow:(NSWindow*)window;
- (void)refresh:(id)sender;
- (void)configure:(id)sender;
- (void)run:(id)sender;
- (void)debug:(id)sender;
- (void)stepOver:(id)sender;
- (void)stepIn:(id)sender;
- (void)stepOut:(id)sender;
- (void)setBreakpoints:(NSArray<NSDictionary*>*)breakpoints forPath:(NSString*)path;
- (void)reloadBreakpoints;
- (BOOL)isBreakpointUnverifiedAtPath:(NSString*)path line:(NSUInteger)line;
- (void)stop:(id)sender;
- (void)restart:(id)sender;
- (void)resetTrust;
- (void)invalidate;
@end
