#import <OakFilterList/OakChooser.h>
#import <document/OakDocument.h>

@interface OakWorkspaceSymbolItem : NSObject
@property (nonatomic) NSAttributedString* name; // Match-highlighted display name
@property (nonatomic) NSString* containerName;
@property (nonatomic) NSString* fileURI;
@property (nonatomic) NSString* filePath;
@property (nonatomic) NSString* displayPath;
@property (nonatomic) NSString* infoString;     // "path:line" shown in the status line
@property (nonatomic) NSUInteger line;          // 0-based
@property (nonatomic) NSUInteger column;        // 0-based
- (id)objectForKey:(id)key;
@end

@interface OakWorkspaceSymbolChooser : OakChooser
- (instancetype)initWithBaseDocument:(OakDocument*)document;
@property (nonatomic) OakDocument* baseDocument;
- (void)refreshItems;
@end
