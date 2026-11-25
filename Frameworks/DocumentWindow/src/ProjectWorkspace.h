#import <Foundation/Foundation.h>

NSData* ProjectJSONDataWithoutComments(NSData* original);

@interface ProjectWorkspace : NSObject
@property (nonatomic, readonly) NSURL* URL;
@property (nonatomic, readonly) NSString* name;
@property (nonatomic, readonly) NSArray<NSDictionary<NSString*, NSString*>*>* folders;

+ (instancetype)workspaceAtURL:(NSURL*)url error:(NSError**)error;
+ (instancetype)createAtURL:(NSURL*)url folderPaths:(NSArray<NSString*>*)paths error:(NSError**)error;
- (BOOL)addFolderPaths:(NSArray<NSString*>*)paths error:(NSError**)error;
- (BOOL)removeFolderAtPath:(NSString*)path error:(NSError**)error;
- (NSString*)folderContainingPath:(NSString*)path;
- (NSString*)availableFolderPreferringPath:(NSString*)path;
@end
