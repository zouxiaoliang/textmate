#import "OakChooser.h"
#import <document/OakDocument.h>

@interface SymbolChooser : OakChooser
@property (class, readonly) SymbolChooser* sharedInstance;

@property (nonatomic) OakDocument* TMDocument;
@property (nonatomic) NSString* selectionString;
// Optional LSP documentSymbol entries (flattened): each dictionary has
// "name" (NSString), "line"/"column" (0-based) and "depth" (nesting level).
// When set it takes precedence over the bundle’s scope-derived symbols.
@property (nonatomic) NSArray<NSDictionary*>* lspSymbols;
- (void)updateItems:(id)sender;
@end
