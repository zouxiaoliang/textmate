#import <Cocoa/Cocoa.h>
#import <OakTabBarView/OakTabBarView.h>
#import <Preferences/Keys.h>

// Host that paints a theme-like dark background so the bar style is visible.
@interface HostView : NSView
@end
@implementation HostView
- (void)drawRect:(NSRect)aRect
{
	[[NSColor colorWithCalibratedWhite:0.11 alpha:1] setFill];
	NSRectFill(self.bounds);
}
- (BOOL)isFlipped { return YES; }
@end

// Minimal data source: three tabs, middle one selected.
@interface TestSource : NSObject <OakTabBarViewDataSource>
@property (nonatomic, readonly) NSArray<NSUUID*>* uuids;
@end
@implementation TestSource
- (instancetype)init
{
	if((self = [super init]))
		_uuids = @[ [NSUUID UUID], [NSUUID UUID], [NSUUID UUID] ];
	return self;
}
- (NSUInteger)numberOfRowsInTabBarView:(OakTabBarView*)aTabBarView { return 3; }
- (NSString*)tabBarView:(OakTabBarView*)aTabBarView titleForIndex:(NSUInteger)anIndex
{
	NSArray<NSString*>* titles = @[ @"main.cc ⌘#1", @"buffer.h ⌘#2", @"t_parser.mm ⌘#3" ];
	return titles[anIndex];
}
- (NSString*)tabBarView:(OakTabBarView*)aTabBarView pathForIndex:(NSUInteger)anIndex { return @"/src/file"; }
- (NSUUID*)tabBarView:(OakTabBarView*)aTabBarView UUIDForIndex:(NSUInteger)anIndex { return _uuids[anIndex]; }
- (BOOL)tabBarView:(OakTabBarView*)aTabBarView isEditedAtIndex:(NSUInteger)anIndex { return NO; }
@end

int main (int argc, char const* argv[])
{
	@autoreleasepool
	{
		NSApplication.sharedApplication; // bootstrap AppKit enough for colors/fonts

		// The bar reads its min/max tab widths from user defaults; a bare test
		// process has none (zero → NaN layout math → nothing draws).
		[NSUserDefaults.standardUserDefaults setInteger:100 forKey:kUserDefaultsTabItemMinWidthKey];
		[NSUserDefaults.standardUserDefaults setInteger:180 forKey:kUserDefaultsTabItemMaxWidthKey];

		// Dark background like a theme (window.backgroundColor would be this).
		NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 820, 200) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
		window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
		HostView* host = [[HostView alloc] initWithFrame:NSMakeRect(0, 0, 820, 200)];
		window.contentView = host;

		TestSource* source = [TestSource new];
		OakTabBarView* bar = [[OakTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 820, 24)];
		bar.dataSource = source;
		bar.leadingContentInset = 78;

		[host addSubview:bar]; // frame stays 820×28 (intrinsic width is NSViewNoIntrinsicMetric)
		// First pass creates the tab views (fittingSize still zero); a second
		// pass after layout gives real fitting widths.
		[bar reloadData];
		[bar layoutSubtreeIfNeeded];
		[bar reloadData];
		[bar layoutSubtreeIfNeeded];
		[bar setSelectedTabIndex:1];
		[bar reloadData];
		[bar layoutSubtreeIfNeeded];

		id items = [bar valueForKey:@"tabItems"];
		NSLog(@"render_tabbar: items=%lu visible=%ld leadingInset=%f min=%@ max=%@", (unsigned long)[items count], (long)bar.countOfVisibleTabs, bar.leadingContentInset, [NSUserDefaults.standardUserDefaults valueForKey:kUserDefaultsTabItemMinWidthKey], [NSUserDefaults.standardUserDefaults valueForKey:kUserDefaultsTabItemMaxWidthKey]);
		for(NSView* v in bar.subviews)
		{
			if([v respondsToSelector:@selector(isSelected)])
			{
				BOOL sel = [[v valueForKey:@"selected"] boolValue];
				NSString* title = [v valueForKeyPath:@"tabItem.title"] ?: @"-";
				NSLog(@"  tab %@ frame=%@ selected=%d title=%@", v.class, NSStringFromRect(v.frame), (int)sel, title);
			}
			else
				NSLog(@"  subview %@ frame=%@ hidden=%d", v.class, NSStringFromRect(v.frame), (int)v.isHidden);
		}
		[host display];

		NSBitmapImageRep* rep = [host bitmapImageRepForCachingDisplayInRect:host.bounds];
		[host cacheDisplayInRect:host.bounds toBitmapImageRep:rep];
		NSData* data = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
		[data writeToFile:@(argv[1] ?: "/tmp/tabbar_render.png") atomically:YES];
		fprintf(stderr, "rendered %ld x %ld\n", (long)rep.pixelsWide, (long)rep.pixelsHigh);
	}
	return 0;
}
