#import <Foundation/Foundation.h>
#import "ProjectChanges.h"

typedef NS_ENUM(NSUInteger, GitChangeGroup) {
	GitChangeStaged,
	GitChangeWorking,
	GitChangeConflict,
};

typedef NS_ENUM(NSUInteger, GitRepositoryAction) {
	GitRepositoryStage,
	GitRepositoryUnstage,
	GitRepositoryDiscard,
	GitRepositoryCommit,
	GitRepositoryFetch,
	GitRepositoryPull,
	GitRepositoryPush,
	GitRepositorySwitchBranch,
	GitRepositoryCreateBranch,
	GitRepositoryTrackBranch,
	GitRepositorySaveStash,
	GitRepositoryApplyStash,
	GitRepositoryDropStash,
	GitRepositorySync,
	GitRepositoryMerge,
	GitRepositoryRebase,
	GitRepositoryContinueIntegration,
	GitRepositoryAbortIntegration,
	GitRepositoryEditSelection,
};

typedef NS_ENUM(NSUInteger, GitHistorySearch) {
	GitHistorySearchMessage,
	GitHistorySearchAuthor,
	GitHistorySearchHash,
	GitHistorySearchFile,
};

typedef NS_OPTIONS(NSUInteger, GitPullOptions) {
	GitPullPrune = 1 << 0,
	GitPullFetchSubmodules = 1 << 1,
	GitPullFetchTags = 1 << 2,
};

typedef NS_OPTIONS(NSUInteger, GitPushOptions) {
	GitPushTags = 1 << 0,
	GitPushVerifySubmodules = 1 << 1,
	GitPushSubmodulesOnDemand = 1 << 2,
};

typedef NS_OPTIONS(NSUInteger, GitMergeOptions) {
	GitMergeNoCommit = 1 << 0,
	GitMergeNoFastForward = 1 << 1,
	GitMergeSquash = 1 << 2,
	GitMergeVerifySignatures = 1 << 3,
};

NSDictionary* GitRepositoryCommand(NSString* directory, NSArray<NSString*>* arguments, BOOL mutation = NO, NSTimeInterval timeout = 10);
NSArray<NSDictionary*>* GitRepositoryChanges(NSDictionary* snapshot);
constexpr NSUInteger GitDiffCompleteFileContext = 1000000000UL;
NSDictionary* GitRepositoryChangeDiff(NSDictionary* snapshot, NSDictionary* change, NSDictionary<NSString*, ProjectChangesBuffer*>* buffers, NSUInteger contextLines = 3, BOOL ignoreWhitespace = NO);
NSString* GitRepositoryPerform(NSString* root, GitRepositoryAction action, NSArray<NSString*>* paths, NSString* message = nil);
NSDictionary* GitRepositoryCommitContext(NSString* root, NSString* head);
NSString* GitRepositoryCommitChanges(NSString* root, NSString* message, NSString* amendHead, BOOL signOff);
NSDictionary* GitRepositoryBranches(NSString* root);
NSDictionary* GitRepositoryReferences(NSString* root);
NSDictionary* GitRepositoryStashes(NSString* root, NSUInteger limit, NSString* query = nil);
NSDictionary* GitRepositoryStashDiff(NSString* root, NSString* commit);
NSDictionary* GitRepositoryStashDetails(NSString* root, NSString* commit);
NSString* GitRepositoryOpenStashDiffTool(NSString* root, NSString* commit, NSString* path = nil);
NSString* GitRepositoryOpenRevisionDiffTool(NSString* root, NSString* base, NSString* revision, NSString* path);
NSDictionary* GitRepositoryStashFileDiff(NSString* root, NSString* commit, NSString* path);
NSString* GitRepositoryCreateTrackingBranch(NSString* root, NSString* name, NSString* remoteRef);
NSString* GitRepositoryStashChanges(NSString* root, NSString* message, BOOL includeUntracked);
NSString* GitRepositoryApplySavedStash(NSString* root, NSDictionary* stash, BOOL restoreIndex, BOOL dropAfterApplying);
NSString* GitRepositoryDropSavedStash(NSString* root, NSDictionary* stash);
NSDictionary* GitRepositoryToolbarContext(NSString* root, NSString* branch);
NSString* GitRepositoryIntegrate(NSString* root, GitRepositoryAction action, NSString* ref, GitMergeOptions options = (GitMergeOptions)0);
NSString* GitRepositoryFinishIntegration(NSString* root, NSString* operation, BOOL abort);
NSString* GitRepositoryRemoteAction(NSString* root, GitRepositoryAction action, NSString* remote, NSString* branch, NSString* pullMode, NSString* expectedBranch = nil, GitPullOptions options = (GitPullOptions)0, GitPushOptions pushOptions = (GitPushOptions)0);

NSDictionary* GitRepositoryHistory(NSString* directory, NSUInteger limit);
NSDictionary* GitRepositoryHistoryForRef(NSString* directory, NSString* ref, NSUInteger limit);
NSDictionary* GitRepositorySearchHistory(NSString* directory, NSString* ref, NSUInteger limit, NSString* query, GitHistorySearch scope);
NSDictionary* GitRepositoryCommitDetails(NSString* root, NSDictionary* commit);
NSDictionary* GitRepositoryRangeChanges(NSString* root, NSString* range);
NSDictionary* GitRepositoryCommitDiff(NSString* root, NSDictionary* commit, NSString* path);
NSDictionary* GitRepositoryRevisionTree(NSString* root, NSString* revision, NSString* folder);
NSDictionary* GitRepositoryRevisionFile(NSString* root, NSString* object);
NSString* GitRepositoryApplyHunk(NSDictionary* snapshot, NSDictionary* change, NSString* hunk, GitRepositoryAction action, NSUInteger contextLines = 3);
// Each edge is [source lane, destination lane, color]; the primary chain stays in lane zero.
NSArray<NSDictionary*>* GitGraphLayout(NSArray<NSDictionary*>* commits, NSSet<NSString*>* primaryCommits);
