#import "OakTextView.h"
#import <oak/debug.h>

@class OakDocument;

@interface OakDocumentView : NSView
@property (nonatomic, readonly) OakTextView* textView;
@property (nonatomic) OakDocument* document;
@property (nonatomic) BOOL hideStatusBar;
@property (nonatomic) BOOL showsLineNumbers;
- (IBAction)toggleLineNumbers:(id)sender;

- (void)addAuxiliaryView:(NSView*)aView atEdge:(NSRectEdge)anEdge;
- (void)removeAuxiliaryView:(NSView*)aView;

- (IBAction)showSymbolChooser:(id)sender;
- (IBAction)lspRestartServer:(id)sender;
- (IBAction)lspReindexWorkspace:(id)sender;
- (IBAction)lspNextDiagnostic:(id)sender;
- (IBAction)lspPrevDiagnostic:(id)sender;

- (void)updateCursorLine:(NSUInteger)line;
- (void)invalidateCodeActionProbe;
@end
