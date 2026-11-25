#import "OakChooser.h"

extern NSUInteger const kFileChooserAllSourceIndex;
extern NSUInteger const kFileChooserOpenDocumentsSourceIndex;
extern NSUInteger const kFileChooserUncommittedChangesSourceIndex;

@class OakDocument;

@interface FileChooser : OakChooser
@property (class, readonly) FileChooser* sharedInstance;

- (instancetype)initWithResultsHandler:(void(^)(NSArray<NSDictionary*>* results, BOOL searching))handler;
- (void)endSearch;
- (void)learnSelectionAtPath:(NSString*)path;

@property (nonatomic) NSString* path;
@property (nonatomic) NSUUID* currentDocument;
@property (nonatomic) NSUInteger sourceIndex;
@end
