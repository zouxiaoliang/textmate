#import "GitRepository.h"

NSString* GitWorkspaceText(NSDictionary* result);
NSString* GitWorkspaceError(NSDictionary* result, NSString* fallback);
NSString* GitWorkspaceConfig(NSString* root, NSString* key);
NSString* GitWorkspaceSetConfig(NSString* root, NSString* key, NSString* value);
NSString* GitWorkspacePath(NSString* root, NSString* name);
NSDictionary* GitWorkspaceReadFile(NSString* path);
NSString* GitWorkspaceSaveFile(NSString* path, NSData* original, NSString* text);
NSURL* GitWorkspaceIssueURL(NSString* templateURL, NSString* prefix, NSString* message);

NSArray<NSDictionary*>* GitWorkspaceReviewRefs(NSString* root);
NSDictionary<NSString*, NSDictionary*>* GitWorkspaceBranchPreferences(NSString* root);
NSString* GitWorkspaceSetBranchPreference(NSString* root, NSString* ref, NSString* key, NSString* value);
NSString* GitWorkspaceCreateStackedBranch(NSString* root, NSString* name, NSDictionary* parent);
NSString* GitWorkspaceAutoArchiveBranches(NSString* root, NSArray<NSDictionary*>* refs, NSString* baseRef);
NSString* GitWorkspacePushBranch(NSString* root, NSDictionary* branch, NSString* remote, NSString* destination, BOOL publish, NSString* expectedRemoteTip);
NSDictionary* GitWorkspaceReviewBranch(NSString* root, NSDictionary* base, NSDictionary* branch);
NSDictionary* GitWorkspaceComparisonCommits(NSString* root, NSString* range, NSString* tip);
NSString* GitWorkspaceArchiveBranch(NSString* root, NSDictionary* branch, BOOL restore);
extern NSString* const GitWorkspaceArchivePrefix;

NSArray<NSDictionary*>* GitWorkspacePullRequestRemotes(NSString* root);
NSDictionary* GitWorkspacePullRequestCommand(NSString* root, NSDictionary* remote, NSArray<NSString*>* arguments);
NSDictionary* GitWorkspacePullRequestList(NSString* root, NSDictionary* remote, NSString* state);
NSDictionary* GitWorkspacePullRequestDetails(NSString* root, NSDictionary* remote, NSNumber* number);
