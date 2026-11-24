#import "GitWorkingCopyActions.h"
#import "GitWorkspaceData.h"
#include <sys/stat.h>
#include <unistd.h>

NSDictionary* GitRepositoryCommandWithIndex(NSString* directory, NSArray<NSString*>* arguments, NSString* index, NSString* input);

namespace {
NSArray* WithPaths(NSArray* arguments, NSArray* paths)
{
	return [[arguments arrayByAddingObject:@"--"] arrayByAddingObjectsFromArray:paths];
}

NSString* WriteGit(NSString* root, NSArray* command)
{
	return GitWorkspaceError(GitRepositoryCommand(root, command, YES, 30), @"Git could not finish this operation.");
}

NSString* ResolveTree(NSString* root, NSString* revision)
{
	if(!revision.length) return nil;
	NSDictionary* result = GitRepositoryCommand(root, @[@"rev-parse", @"--verify", @"--end-of-options", [revision stringByAppendingString:@"^{tree}"]]);
	return !GitWorkspaceError(result, @"Unknown revision.") ? [GitWorkspaceText(result) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] : nil;
}

NSArray* GitPaths(NSDictionary* result)
{
	NSString* text = [[NSString alloc] initWithData:result[@"data"] ?: NSData.data encoding:NSUTF8StringEncoding];
	if(!text) return nil;
	NSArray* paths = [text componentsSeparatedByString:[NSString stringWithFormat:@"%C", (unichar)0]];
	return [paths subarrayWithRange:NSMakeRange(0, paths.count-1)];
}

NSString* SavePatterns(NSString* root, NSArray* rows, BOOL exclude, NSString* pattern)
{
	NSString* path = exclude ? GitWorkspacePath(root, @"info/exclude") : [root stringByAppendingPathComponent:@".gitignore"];
	NSDictionary* original = GitWorkspaceReadFile(path);
	if(original[@"error"]) return original[@"error"];
	NSMutableOrderedSet* rules = [NSMutableOrderedSet orderedSet];
	if(pattern != nil) [rules addObjectsFromArray:[pattern componentsSeparatedByString:@"\n"]];
	else for(NSDictionary* row in rows) {
		NSString* line = GitWorkingCopyIgnorePattern(row, GitWorkingCopyExactPath);
		if(!line) return @"Git ignore rules cannot match the selected filename literally.";
		[rules addObject:line];
	}
	[rules removeObject:@""];
	[rules removeObjectsInArray:[original[@"text"] componentsSeparatedByString:@"\n"]];
	if(!rules.count) return nil;
	NSMutableString* text = [original[@"text"] mutableCopy];
	if(text.length && ![text hasSuffix:@"\n"]) [text appendString:@"\n"];
	[text appendFormat:@"%@\n", [rules.array componentsJoinedByString:@"\n"]];
	return GitWorkspaceSaveFile(path, original[@"data"], text);
}

// A path-limited `git stash push` can include unrelated staged files. Compose
// the stash from a private index instead. Snapshot never writes the real index
// or temporarily removes working files.
NSString* MakeStash(NSString* root, NSArray* rows, NSString* message, BOOL snapshot)
{
	NSDictionary* revision = ProjectChangesRevision(root);
	NSString* head = revision[@"head"];
	if(!head.length) return @"Make an initial commit before saving a stash or snapshot.";
	NSDictionary* conflicts = GitRepositoryCommand(root, @[@"ls-files", @"--unmerged", @"-z"]);
	if(NSString* error = GitWorkspaceError(conflicts, @"Could not check for merge conflicts.")) return error;
	if([conflicts[@"data"] length]) return @"Resolve the repository’s merge conflicts before saving a stash or snapshot.";
	NSMutableArray* tracked = [NSMutableArray array], *worktree = [NSMutableArray array], *untracked = [NSMutableArray array];
	for(NSDictionary* row in rows) {
		NSString* path = row[@"path"];
		BOOL newFile = [row[@"untracked"] boolValue];
		if(newFile && GitWorkingCopyIsTracked(row)) return @"Unstage the deletion before saving the replacement file to a stash or snapshot.";
		if(GitWorkingCopyIsTracked(row)) {
			[tracked addObject:path];
			if(![row[@"diskFlags"] hasPrefix:@"D"]) [worktree addObject:path];
		}
		if(newFile) [untracked addObject:path];
	}
	NSString* folder = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"textmate-stash-" stringByAppendingString:NSUUID.UUID.UUIDString]];
	NSFileManager* files = NSFileManager.defaultManager;
	NSError* fileError;
	if(![files createDirectoryAtPath:folder withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:&fileError]) return fileError.localizedDescription;
	NSString* index = [folder stringByAppendingPathComponent:@"index"], *indexInfo = [folder stringByAppendingPathComponent:@"entries"];
	__block NSString* error = nil;
	NSString* (^run)(NSArray*, NSString*) = ^NSString*(NSArray* arguments, NSString* input){
		if(error) return nil;
		NSDictionary* result = GitRepositoryCommandWithIndex(root, arguments, index, input);
		error = GitWorkspaceError(result, @"Could not prepare the selected changes.");
		return error ? nil : [GitWorkspaceText(result) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
	};
	NSDictionary* staged = tracked.count ? GitRepositoryCommand(root, WithPaths(@[@"ls-files", @"--stage", @"-z"], tracked)) : nil;
	if(staged) error = GitWorkspaceError(staged, @"Could not read the selected index entries.");
	run(@[@"read-tree", head], nil);
	if(tracked.count && !error) {
		if(!error && ![staged[@"data"] writeToFile:indexInfo options:0 error:&fileError]) error = fileError.localizedDescription;
		run(WithPaths(@[@"update-index", @"--force-remove"], tracked), nil);
		run(@[@"update-index", @"-z", @"--index-info"], indexInfo);
	}
	NSString* stageTree = run(@[@"write-tree"], nil);
	NSString* stageCommit = stageTree ? run(@[@"-c", @"commit.gpgsign=false", @"commit-tree", stageTree, @"-p", head, @"-m", @"Index for selected changes"], nil) : nil;
	if(worktree.count) run(WithPaths(@[@"add", @"-u"], worktree), nil);
	NSString* workTree = run(@[@"write-tree"], nil);
	NSString* untrackedCommit = nil, *untrackedTree = nil;
	NSArray* untrackedPaths = @[];
	if(untracked.count && !error) {
		run(@[@"read-tree", @"--empty"], nil);
		run(WithPaths(@[@"add", @"-A"], untracked), nil);
		untrackedTree = run(@[@"write-tree"], nil);
		if(untrackedTree) {
			NSDictionary* entries = GitRepositoryCommand(root, @[@"ls-tree", @"-r", @"-z", @"--full-tree", untrackedTree]);
			error = GitWorkspaceError(entries, @"Could not read untracked stash entries.");
			NSMutableArray* paths = [NSMutableArray array];
			NSArray* lines = GitPaths(entries);
			if(!lines && !error) error = @"The selected files include a path that cannot be represented as UTF-8.";
			for(NSString* line in lines) {
				if([line hasPrefix:@"160000 "]) { error = @"Save changes to a nested repository from its own Working Copy."; break; }
				NSRange tab = [line rangeOfString:@"\t"];
				if(tab.location != NSNotFound) [paths addObject:[line substringFromIndex:NSMaxRange(tab)]];
			}
			untrackedPaths = paths;
			if(!error && !untrackedPaths.count && !tracked.count) error = @"No selected changes remain to save. Refresh Working Copy and try again.";
			if(untrackedPaths.count) untrackedCommit = run(@[@"-c", @"commit.gpgsign=false", @"commit-tree", untrackedTree, @"-m", @"Untracked files for selected changes"], nil);
		}
	}
	NSString* title = message.length ? message : snapshot ? @"Snapshot of selected changes" : @"Stash of selected changes";
	if(!error && ![[ProjectChangesRevision(root) objectForKey:@"head"] isEqual:head]) error = @"HEAD changed while preparing the stash. Try again.";
	if(!error) {
		NSMutableArray* commit = [NSMutableArray arrayWithArray:@[@"-c", @"commit.gpgsign=false", @"commit-tree", workTree, @"-p", head, @"-p", stageCommit]];
		if(untrackedCommit) [commit addObjectsFromArray:@[@"-p", untrackedCommit]];
		[commit addObjectsFromArray:@[@"-m", title]];
		if(NSString* stash = run(commit, nil)) error = WriteGit(root, @[@"stash", @"store", @"-m", title, stash]);
		if(!error && !snapshot) {
			// Check the saved trees again before cleaning, and pass Git only the
			// individual untracked paths in the stash, never their parent folders.
			if(untrackedTree) {
				run(@[@"read-tree", @"--empty"], nil);
				run(WithPaths(@[@"add", @"-A"], untracked), nil);
				if(![run(@[@"write-tree"], nil) isEqual:untrackedTree] && !error) error = @"The selected untracked files changed while saving.";
			}
			if(tracked.count && !error) {
				NSDictionary* current = GitRepositoryCommand(root, WithPaths(@[@"ls-files", @"--stage", @"-z"], tracked));
				error = GitWorkspaceError(current, @"Could not reread the selected index entries.");
				if(!error && ![current[@"data"] isEqual:staged[@"data"]]) error = @"The selected index entries changed while saving.";
				run(@[@"read-tree", stageTree], nil);
				if(worktree.count) run(WithPaths(@[@"add", @"-u"], worktree), nil);
				if(![run(@[@"write-tree"], nil) isEqual:workTree] && !error) error = @"The selected working files changed while saving.";
				for(NSDictionary* row in rows) if([row[@"diskFlags"] hasPrefix:@"D"] && GitWorkingCopyPathExists(row[@"absolutePath"])) error = @"A deleted file was recreated while saving.";
			}
			if(!error && ![ProjectChangesRevision(root)[@"head"] isEqual:head]) error = @"HEAD changed while saving.";
			if(!error && untrackedPaths.count) error = WriteGit(root, WithPaths(@[@"clean", @"-f"], untrackedPaths));
			if(!error && tracked.count) error = WriteGit(root, WithPaths(@[@"restore", [@"--source=" stringByAppendingString:head], @"--staged", @"--worktree"], tracked));
			if(error) error = [@"The stash was saved, but some selected files could not be cleared. " stringByAppendingString:error];
		}
	}
	[files removeItemAtPath:folder error:nil];
	return error;
}
}

BOOL GitWorkingCopyPathExists(NSString* path)
{
	struct stat metadata;
	return path.length && lstat(path.fileSystemRepresentation, &metadata) == 0;
}

BOOL GitWorkingCopyIsTracked(NSDictionary* row)
{
	return ![row[@"untracked"] boolValue] || [row[@"diskFlags"] hasPrefix:@"D"];
}

NSArray<NSString*>* GitWorkingCopyAssumedPaths(NSString* root)
{
	NSDictionary* result = GitRepositoryCommand(root, @[@"ls-files", @"-v", @"-z"]);
	NSMutableArray* paths = [NSMutableArray array];
	if(!GitWorkspaceError(result, @"Could not list marked paths."))
		for(NSString* entry in GitPaths(result)) if([entry hasPrefix:@"h "]) [paths addObject:[entry substringFromIndex:2]];
	return paths;
}

NSString* GitWorkingCopyIgnorePattern(NSDictionary* row, GitWorkingCopyPattern kind)
{
	NSString* path = row[@"path"];
	if(!path.length || [path rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) return nil;
	BOOL directory = [path hasSuffix:@"/"];
	if(kind == GitWorkingCopyFileType) {
		if(directory || !path.pathExtension.length) return nil;
		path = path.pathExtension;
	} else if(kind == GitWorkingCopyFileName) path = path.lastPathComponent;
	NSMutableString* pattern = [NSMutableString stringWithString:kind == GitWorkingCopyExactPath ? @"/" : kind == GitWorkingCopyFileType ? @"*." : @""];
	NSCharacterSet* literals = [NSCharacterSet characterSetWithCharactersInString:@"\\[]*?!# "];
	for(NSUInteger i = 0; i < path.length; ++i) {
		unichar ch = [path characterAtIndex:i];
		if([literals characterIsMember:ch]) [pattern appendString:@"\\"];
		[pattern appendString:[path substringWithRange:NSMakeRange(i, 1)]];
	}
	if(directory && ![pattern hasSuffix:@"/"]) [pattern appendString:@"/"];
	return pattern;
}

NSString* GitWorkingCopyModify(NSString* root, NSArray<NSDictionary*>* rows, GitWorkingCopyEdit action, NSString* argument)
{
	if(!root.length || !rows.count) return @"Select one or more files first.";
	NSArray* paths = [rows valueForKey:@"path"];
	NSFileManager* files = NSFileManager.defaultManager;
	switch(action) {
		case GitWorkingCopyStash: case GitWorkingCopySnapshot: return MakeStash(root, rows, argument, action == GitWorkingCopySnapshot);
		case GitWorkingCopyIgnore: case GitWorkingCopyExclude: return SavePatterns(root, rows, action == GitWorkingCopyExclude, argument);
		case GitWorkingCopyUntrack: return WriteGit(root, WithPaths(@[@"rm", @"--cached"], paths));
		case GitWorkingCopyTrash:
			for(NSDictionary* row in rows) {
				NSError* error;
				if(![files trashItemAtURL:[NSURL fileURLWithPath:row[@"absolutePath"]] resultingItemURL:nil error:&error]) return error.localizedDescription;
			}
			return nil;
		case GitWorkingCopyMove: {
			if(rows.count != 1 || !argument.length) return @"Choose a destination for one item.";
			NSString* destination = argument.stringByResolvingSymlinksInPath;
			NSString* prefix = [root isEqual:@"/"] ? root : [root stringByAppendingString:@"/"];
			if(![destination isEqual:root] && ![destination hasPrefix:prefix]) return @"Choose a folder inside this repository.";
			NSString* target = [destination stringByAppendingPathComponent:[paths.firstObject lastPathComponent]];
			if(GitWorkingCopyPathExists(target)) return @"An item with that name already exists in the destination.";
			if(GitWorkingCopyIsTracked(rows.firstObject)) return WriteGit(root, WithPaths(@[@"mv"], @[paths.firstObject, [target substringFromIndex:prefix.length]]));
			NSError* error;
			return [files moveItemAtPath:rows.firstObject[@"absolutePath"] toPath:target error:&error] ? nil : error.localizedDescription;
		}
		case GitWorkingCopyUseOurs: case GitWorkingCopyUseTheirs: case GitWorkingCopyRestoreOurs: case GitWorkingCopyRestoreTheirs: case GitWorkingCopyRestoreAncestor: {
			BOOL ours = action == GitWorkingCopyUseOurs || action == GitWorkingCopyRestoreOurs;
			BOOL resolve = action == GitWorkingCopyUseOurs || action == GitWorkingCopyUseTheirs;
			BOOL ancestor = action == GitWorkingCopyRestoreAncestor;
			for(NSDictionary* row in rows) {
				NSArray* path = @[row[@"path"]];
				NSDictionary* result = GitRepositoryCommand(root, WithPaths(@[@"ls-files", @"--unmerged", @"-z"], path));
				if(NSString* error = GitWorkspaceError(result, @"Could not read the conflict versions.")) return error;
				BOOL resolved = ![result[@"data"] length];
				if(resolved) {
					if(resolve) return @"The file’s conflict is already resolved. Refresh Working Copy to check its status.";
					result = GitRepositoryCommand(root, WithPaths(@[@"ls-files", @"--resolve-undo", @"-z"], path));
					if(NSString* error = GitWorkspaceError(result, @"Could not read the saved conflict versions.")) return error;
				}
				NSArray* entries = GitPaths(result);
				if(!entries.count) return @"No conflict versions are available for this file.";
				BOOL exists = NO;
				for(NSString* entry in entries) {
					NSRange tab = [entry rangeOfString:@"\t"];
					if(tab.location != NSNotFound && [[entry substringToIndex:tab.location] hasSuffix:ancestor ? @" 1" : ours ? @" 2" : @" 3"]) exists = YES;
				}
				if(ancestor && !exists) return @"This conflict has no common ancestor for the selected file.";
				if(resolved) if(NSString* error = WriteGit(root, WithPaths(@[@"checkout", @"-m"], path))) return error;
				if(exists) {
					NSArray* command = ancestor ? @[@"checkout-index", @"--force", @"--stage=1"] : @[@"checkout", ours ? @"--ours" : @"--theirs"];
					if(NSString* error = WriteGit(root, WithPaths(command, path))) return error;
					if(resolve) if(NSString* error = WriteGit(root, WithPaths(@[@"add", @"-A"], path))) return error;
				} else if(resolve) {
					if(NSString* error = WriteGit(root, WithPaths(@[@"rm", @"-f"], path))) return error;
				} else {
					NSString* absolute = row[@"absolutePath"];
					if(unlink(absolute.fileSystemRepresentation) && errno != ENOENT) return @"Could not restore the deleted version of this file.";
				}
			}
			return nil;
		}
		case GitWorkingCopyMarkResolved: return WriteGit(root, WithPaths(@[@"add", @"-A"], paths));
		case GitWorkingCopyRestoreConflict: return WriteGit(root, WithPaths(@[@"checkout", @"-m"], paths));
		case GitWorkingCopyMergeTool: return GitWorkspaceError(GitRepositoryCommand(root, WithPaths(@[@"mergetool", @"--no-prompt"], paths), YES, 600), @"The configured merge tool could not finish.");
		case GitWorkingCopyDiscard: return WriteGit(root, WithPaths(@[@"restore", @"--source=HEAD", @"--staged", @"--worktree"], paths));
		case GitWorkingCopyRestoreRevision: {
			NSString* tree = ResolveTree(root, argument);
			return tree.length ? WriteGit(root, WithPaths(@[@"restore", [@"--source=" stringByAppendingString:tree], @"--staged", @"--worktree"], paths)) : @"Enter an existing branch, tag, or commit hash.";
		}
		case GitWorkingCopyAssumeUnchanged: case GitWorkingCopyClearAssumeUnchanged:
			return WriteGit(root, WithPaths(@[@"update-index", action == GitWorkingCopyAssumeUnchanged ? @"--assume-unchanged" : @"--no-assume-unchanged"], paths));
		case GitWorkingCopyTrackLFS: case GitWorkingCopyUntrackLFS:
			return WriteGit(root, WithPaths(@[@"lfs", action == GitWorkingCopyTrackLFS ? @"track" : @"untrack", @"--filename"], paths));
	}
	return @"This operation is unavailable.";
}

static NSDictionary* ReadGit(NSString* root, NSArray* arguments)
{
	NSDictionary* result = GitRepositoryCommand(root, arguments);
	if(NSString* error = GitWorkspaceError(result, @"Git could not read this file at the selected revision.")) return @{@"error": error};
	NSData* data = result[@"data"];
	NSString* text = data.length && memchr(data.bytes, 0, data.length) ? nil : GitWorkspaceText(result);
	return @{@"text": text ? (text.length ? text : @"No text differences to display.") : @"Binary file or text in a different encoding"};
}

NSDictionary* GitWorkingCopyComparePaths(NSString* root, NSArray<NSString*>* paths, NSString* revision)
{
	NSString* tree = ResolveTree(root, revision);
	if(!tree.length) return @{@"error": @"Enter an existing branch, tag, or commit hash."};
	return ReadGit(root, WithPaths(@[@"diff", @"--no-ext-diff", @"--no-textconv", @"--no-color", tree], paths));
}

NSDictionary* GitWorkingCopyPreview(NSString* root, NSString* path, GitWorkingCopyRead action, NSString* revision)
{
	switch(action) {
		case GitWorkingCopyReadHead: return ReadGit(root, @[@"cat-file", @"blob", [@"HEAD:" stringByAppendingString:path]]);
		case GitWorkingCopyBlame: return ReadGit(root, WithPaths(@[@"blame", @"--date=short", @"HEAD"], @[path]));
		case GitWorkingCopyCompareRevision: return GitWorkingCopyComparePaths(root, @[path], revision);
	}
	return @{@"error": @"Unsupported comparison."};
}
