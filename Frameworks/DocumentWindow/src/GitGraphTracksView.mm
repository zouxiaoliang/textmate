#import "GitGraphTracksView.h"

namespace {
constexpr CGFloat laneWidth = 13;
constexpr CGFloat laneInset = 10;

NSColor* LaneColor(NSUInteger index)
{
	NSArray<NSColor*>* colors = @[NSColor.systemBlueColor, NSColor.systemPurpleColor, NSColor.systemTealColor,
		NSColor.systemOrangeColor, NSColor.systemIndigoColor, NSColor.systemPinkColor, NSColor.systemGreenColor];
	return colors[index ? 1+(index-1)%(colors.count-1) : 0];
}

CGFloat LanePosition(NSNumber* lane) { return laneInset + lane.unsignedIntegerValue * laneWidth; }
}

@implementation GitGraphTracksView
- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect
{
	CGFloat middle = NSMidY(self.bounds);
	CGFloat bottom = NSMaxY(self.bounds);
	NSNumber* nodeLane = self.tracks[@"node"];
	auto drawEdge = [&](NSArray* edge, CGFloat start, CGFloat end, BOOL continues){
		CGFloat from = LanePosition(edge[0]);
		CGFloat to = continues ? from : LanePosition(edge[1]);
		[LaneColor([edge[2] unsignedIntegerValue]) setStroke];
		NSBezierPath* line = [NSBezierPath bezierPath];
		line.lineWidth = 1.5;
		[line moveToPoint:NSMakePoint(from, start)];
		if(from == to) [line lineToPoint:NSMakePoint(to, end)];
		else [line curveToPoint:NSMakePoint(to, end) controlPoint1:NSMakePoint(from, start + (end-start)*0.65) controlPoint2:NSMakePoint(to, start + (end-start)*0.35)];
		[line stroke];
	};
	for(NSArray* edge in self.tracks[@"incoming"])
		drawEdge(edge, NSMinY(self.bounds), nodeLane ? middle : bottom, !nodeLane);
	if(!nodeLane) return;
	for(NSArray* edge in self.tracks[@"outgoing"]) drawEdge(edge, middle, bottom, NO);
	CGFloat node = LanePosition(nodeLane);
	CGFloat radius = self.head ? 4.5 : 3;
	[LaneColor([self.tracks[@"color"] unsignedIntegerValue]) setFill];
	[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(node-radius, middle-radius, radius*2, radius*2)] fill];
	if(self.head) {
		[NSColor.controlBackgroundColor setFill];
		[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(node-2, middle-2, 4, 4)] fill];
	}
}
@end
