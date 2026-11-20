#import <Cocoa/Cocoa.h>

@class OakDocument;

@interface OutlineViewController : NSViewController
@property (nonatomic) OakDocument* document;
@property (nonatomic, getter = isPanelVisible) BOOL panelVisible; // when NO the panel idles: no reloads, no LSP queries
@property (nonatomic, copy) NSString* selectionString;            // caret position as “line:column”, used to follow the current symbol
@property (nonatomic, weak) id target;
@property (nonatomic) SEL action;                                  // sent on selection change; query -selectedSelectionString

- (NSString*)selectedSelectionString;                             // nil when nothing (visible) is selected
@end
