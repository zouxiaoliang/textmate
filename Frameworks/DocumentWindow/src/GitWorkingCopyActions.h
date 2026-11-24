#import "GitRepository.h"

typedef NS_ENUM(NSInteger, GitWorkingCopyEdit) {
	GitWorkingCopyUntrack, GitWorkingCopyTrash, GitWorkingCopyMove, GitWorkingCopyUseOurs, GitWorkingCopyUseTheirs,
	GitWorkingCopyMarkResolved, GitWorkingCopyRestoreConflict, GitWorkingCopyRestoreOurs, GitWorkingCopyRestoreTheirs, GitWorkingCopyRestoreAncestor,
	GitWorkingCopyMergeTool, GitWorkingCopyDiscard, GitWorkingCopyStash, GitWorkingCopySnapshot, GitWorkingCopyRestoreRevision,
	GitWorkingCopyIgnore, GitWorkingCopyExclude, GitWorkingCopyAssumeUnchanged, GitWorkingCopyClearAssumeUnchanged,
	GitWorkingCopyTrackLFS, GitWorkingCopyUntrackLFS,
};

typedef NS_ENUM(NSInteger, GitWorkingCopyRead) {
	GitWorkingCopyReadHead, GitWorkingCopyBlame, GitWorkingCopyCompareRevision,
};

typedef NS_ENUM(NSInteger, GitWorkingCopyPattern) { GitWorkingCopyExactPath, GitWorkingCopyFileName, GitWorkingCopyFileType };

BOOL GitWorkingCopyPathExists(NSString* path);
BOOL GitWorkingCopyIsTracked(NSDictionary* row);
NSString* GitWorkingCopyIgnorePattern(NSDictionary* row, GitWorkingCopyPattern kind);
NSArray<NSString*>* GitWorkingCopyAssumedPaths(NSString* root);
NSString* GitWorkingCopyModify(NSString* root, NSArray<NSDictionary*>* rows, GitWorkingCopyEdit action, NSString* argument = nil);
NSDictionary* GitWorkingCopyPreview(NSString* root, NSString* path, GitWorkingCopyRead action, NSString* revision = nil);
NSDictionary* GitWorkingCopyComparePaths(NSString* root, NSArray<NSString*>* paths, NSString* revision);
