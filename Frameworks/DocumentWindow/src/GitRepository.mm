#import "GitRepository.h"
#import "GitWorkspaceData.h"
#include <algorithm>
#include <vector>
#include <unistd.h>

static NSDictionary* RevisionMetadata(NSString* root, NSString* hash);
NSDictionary* GitRepositoryCommandWithIndex(NSString* directory, NSArray<NSString*>* arguments, NSString* index, NSString* input);

namespace {
NSString* GitText(NSDictionary* result)
{
	NSData* data = result[@"data"];
	return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

NSString* GitFailure(NSDictionary* result, NSString* fallback)
{
	if(result[@"error"]) return result[@"error"];
	return [result[@"status"] intValue] ? fallback : nil;
}

NSString* ConvertGitMoji(NSString* message)
{
	static NSArray<NSArray*>* const codes = @[
		@[@"🎨", @"art"], @[@"⚡️", @"zap"], @[@"🔥", @"fire"], @[@"🐛", @"bug"], @[@"🚑️", @"ambulance"],
		@[@"✨", @"sparkles"], @[@"📝", @"memo"], @[@"🚀", @"rocket"], @[@"💄", @"lipstick"], @[@"🎉", @"tada"],
		@[@"✅", @"white_check_mark"], @[@"🔒️", @"lock"], @[@"🔐", @"closed_lock_with_key"], @[@"🔖", @"bookmark"], @[@"🚨", @"rotating_light"],
		@[@"🚧", @"construction"], @[@"💚", @"green_heart"], @[@"⬇️", @"arrow_down"], @[@"⬆️", @"arrow_up"], @[@"📌", @"pushpin"],
		@[@"👷", @"construction_worker"], @[@"📈", @"chart_with_upwards_trend"], @[@"♻️", @"recycle"], @[@"➕", @"heavy_plus_sign"], @[@"➖", @"heavy_minus_sign"],
		@[@"🔧", @"wrench"], @[@"🔨", @"hammer"], @[@"🌐", @"globe_with_meridians"], @[@"✏️", @"pencil2"], @[@"💩", @"poop"],
		@[@"⏪️", @"rewind"], @[@"🔀", @"twisted_rightwards_arrows"], @[@"📦️", @"package"], @[@"👽️", @"alien"], @[@"🚚", @"truck"],
		@[@"📄", @"page_facing_up"], @[@"💥", @"boom"], @[@"🍱", @"bento"], @[@"♿️", @"wheelchair"], @[@"💡", @"bulb"],
		@[@"🍻", @"beers"], @[@"💬", @"speech_balloon"], @[@"🗃️", @"card_file_box"], @[@"🔊", @"loud_sound"], @[@"🔇", @"mute"],
		@[@"👥", @"busts_in_silhouette"], @[@"🚸", @"children_crossing"], @[@"🏗️", @"building_construction"], @[@"📱", @"iphone"], @[@"🤡", @"clown_face"],
		@[@"🥚", @"egg"], @[@"🙈", @"see_no_evil"], @[@"📸", @"camera_flash"], @[@"⚗️", @"alembic"], @[@"🔍️", @"mag"],
		@[@"🏷️", @"label"], @[@"🌱", @"seedling"], @[@"🚩", @"triangular_flag_on_post"], @[@"🥅", @"goal_net"], @[@"💫", @"dizzy"],
		@[@"🗑️", @"wastebasket"], @[@"🛂", @"passport_control"], @[@"🩹", @"adhesive_bandage"], @[@"🧐", @"monocle_face"], @[@"⚰️", @"coffin"],
		@[@"🧪", @"test_tube"], @[@"👔", @"necktie"], @[@"🩺", @"stethoscope"], @[@"🧱", @"bricks"], @[@"🧑‍💻", @"technologist"],
		@[@"💸", @"money_with_wings"], @[@"🧵", @"thread"], @[@"🦺", @"safety_vest"], @[@"✈️", @"airplane"]
	];
	for(NSArray* pair in codes) {
		NSString* glyph = pair[0];
		NSString* code = [NSString stringWithFormat:@":%@:", pair[1]];
		message = [message stringByReplacingOccurrencesOfString:glyph withString:code];
		if([glyph hasSuffix:@"\uFE0F"]) message = [message stringByReplacingOccurrencesOfString:[glyph substringToIndex:glyph.length-1] withString:code];
	}
	return message;
}

NSString* RunMutation(NSString* root, NSArray<NSString*>* arguments, NSString* fallback, NSTimeInterval timeout = 30)
{
	NSDictionary* result = GitRepositoryCommand(root, arguments, YES, timeout);
	if(result[@"error"]) return result[@"error"];
	if(![result[@"status"] intValue]) return nil;
	NSString* error = [GitText(result) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	return error.length > 2000 ? [error substringToIndex:2000] : error.length ? error : fallback;
}

NSArray<NSString*>* NulFields(NSData* data)
{
	NSMutableArray* fields = [NSMutableArray array];
	char const* bytes = static_cast<char const*>(data.bytes);
	NSUInteger start = 0;
	for(NSUInteger offset = 0; offset < data.length; ++offset) {
		if(bytes[offset] != '\0') continue;
		NSString* field = [[NSString alloc] initWithBytes:bytes+start length:offset-start encoding:NSUTF8StringEncoding];
		[fields addObject:field ?: @""];
		start = offset+1;
	}
	return fields;
}

BOOL IsConflict(NSString* flags)
{
	return [flags containsString:@"U"] || [flags isEqual:@"AA"] || [flags isEqual:@"DD"];
}

NSDictionary* Change(NSDictionary* file, GitChangeGroup group, NSString* code, BOOL writable)
{
	NSMutableDictionary* change = [file mutableCopy];
	change[@"group"] = @(group);
	change[@"code"] = code;
	change[@"writable"] = @(writable);
	return change;
}

NSDictionary* PatchResult(NSDictionary* result)
{
	if(NSString* error = GitFailure(result, @"Git could not read this diff. Refresh and try again.")) return @{ @"error": error };
	NSString* text = GitText(result);
	if(!text) return @{ @"error": @"This diff contains text that is not encoded as UTF-8." };
	return @{ @"text": text.length ? text : @"No text differences to display." };
}

NSArray<NSString*>* CommitArguments(NSDictionary* commit, NSArray<NSString*>* options, NSArray<NSString*>* paths)
{
	NSString* parent = [commit[@"parents"] firstObject];
	NSArray* operation = parent ? @[@"diff"] : @[@"diff-tree", @"--root", @"--no-commit-id", @"-r"];
	NSArray* revisions = parent ? @[parent, commit[@"id"], @"--"] : @[commit[@"id"], @"--"];
	return [[[operation arrayByAddingObjectsFromArray:options] arrayByAddingObjectsFromArray:revisions] arrayByAddingObjectsFromArray:paths];
}

struct Lane
{
	NSString* commit = nil;
	NSUInteger color = 0;
};

NSUInteger FindLane(std::vector<Lane> const& lanes, NSString* commit, NSUInteger start)
{
	for(NSUInteger index = start; index < lanes.size(); ++index)
		if([lanes[index].commit isEqualToString:commit]) return index;
	return NSNotFound;
}

NSUInteger ReserveLane(std::vector<Lane>& lanes, NSUInteger start)
{
	for(NSUInteger index = start; index < lanes.size(); ++index)
		if(!lanes[index].commit) return index;
	lanes.emplace_back();
	return lanes.size()-1;
}

NSSet<NSString*>* PrimaryHistoryCommits(NSString* root, NSString* ref, NSString* head, NSUInteger limit, BOOL filtered)
{
	NSString* tip = ref;
	if(![ref hasPrefix:@"refs/"]) {
		tip = head;
		NSDictionary* result = GitRepositoryCommand(root, @[@"rev-parse", @"--verify", @"--quiet", @"@{upstream}^{commit}"]);
		NSString* upstream = !GitFailure(result, nil) ? [GitText(result) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] : nil;
		if(upstream.length && ![upstream isEqual:head]) {
			// Include local commits on the same first-parent chain. A merge through a
			// later parent is not a continuation of the tracked branch.
			NSString* range = [NSString stringWithFormat:@"%@..%@", upstream, head ?: upstream];
			NSDictionary* local = GitRepositoryCommand(root, @[@"log", @"--first-parent", @"--format=%P", @"-z", range, @"--"]);
			NSString* boundary = [[NulFields(local[@"data"]) lastObject] componentsSeparatedByString:@" "].firstObject;
			if(![boundary isEqual:upstream]) tip = upstream;
		}
	}
	if(!tip.length) return NSSet.set;
	NSMutableArray* arguments = [NSMutableArray arrayWithArray:@[@"rev-list", @"--first-parent"]];
	// With an unfiltered topological order, nothing from deeper in this chain can appear on the page.
	if(!filtered) [arguments addObject:[NSString stringWithFormat:@"--max-count=%lu", (unsigned long)limit]];
	[arguments addObjectsFromArray:@[tip, @"--"]];
	NSDictionary* result = GitRepositoryCommand(root, arguments);
	NSString* hashes = [GitText(result) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
	return !GitFailure(result, @"Could not read the primary branch.") && hashes.length ? [NSSet setWithArray:[hashes componentsSeparatedByString:@"\n"]] : NSSet.set;
}
}

NSArray<NSDictionary*>* GitRepositoryChanges(NSDictionary* snapshot)
{
	NSMutableArray* staged = [NSMutableArray array];
	NSMutableArray* working = [NSMutableArray array];
	NSMutableArray* conflicts = [NSMutableArray array];
	for(NSDictionary* file in snapshot[@"files"]) {
		NSString* flags = file[@"diskFlags"];
		BOOL unsaved = [file[@"unsaved"] boolValue];
		if(IsConflict(flags)) {
			[conflicts addObject:Change(file, GitChangeConflict, @"U", !unsaved)];
			continue;
		}
		if([flags isEqual:@"??"]) {
			[working addObject:Change(file, GitChangeWorking, @"?", !unsaved)];
			continue;
		}
		if(flags.length != 2) continue;
		NSString* index = [flags substringToIndex:1];
		NSString* worktree = [flags substringFromIndex:1];
		if(![index isEqual:@" "]) [staged addObject:Change(file, GitChangeStaged, index, YES)];
		if([file[@"untracked"] boolValue])
			[working addObject:Change(file, GitChangeWorking, @"?", !unsaved)];
		else if(unsaved || ![worktree isEqual:@" "])
			[working addObject:Change(file, GitChangeWorking, [worktree isEqual:@" "] ? @"M" : worktree, !unsaved)];
	}
	return [[staged arrayByAddingObjectsFromArray:working] arrayByAddingObjectsFromArray:conflicts];
}

NSDictionary* GitRepositoryChangeDiff(NSDictionary* snapshot, NSDictionary* change, NSDictionary<NSString*, ProjectChangesBuffer*>* buffers, NSUInteger contextLines, BOOL ignoreWhitespace)
{
	if([change[@"directory"] boolValue]) {
		return @{ @"text": [change[@"unsaved"] boolValue] ? @"Save the edited files in this folder before staging it."
			: @"Stage this folder to add its untracked files to Git." };
	}
	GitChangeGroup group = (GitChangeGroup)[change[@"group"] unsignedIntegerValue];
	if(group != GitChangeStaged && [change[@"unsaved"] boolValue]) {
		if(group == GitChangeConflict) return ProjectChangesDiff(snapshot, change, buffers, contextLines, ignoreWhitespace);
		return ProjectChangesIndexToBufferDiff(snapshot, change, buffers, contextLines, ignoreWhitespace);
	}
	if([change[@"code"] isEqual:@"?"]) return ProjectChangesIndexToBufferDiff(snapshot, change, @{}, contextLines, ignoreWhitespace);
	NSMutableArray* arguments = [NSMutableArray arrayWithArray:@[@"diff", @"--no-ext-diff", @"--no-textconv", @"--no-color", @"--no-renames", [NSString stringWithFormat:@"--unified=%lu", (unsigned long)MIN(contextLines, GitDiffCompleteFileContext)]]];
	if(group == GitChangeStaged) [arguments addObject:@"--cached"];
	if(ignoreWhitespace) [arguments addObject:@"--ignore-all-space"];
	[arguments addObjectsFromArray:@[@"--", change[@"path"]]];
	NSDictionary* result = GitRepositoryCommand(snapshot[@"root"], arguments);
	if(ignoreWhitespace && ![result[@"data"] length] && !GitFailure(result, @"Git could not read this diff."))
		return @{ @"text": @"No differences to display with whitespace ignored." };
	return PatchResult(result);
}

NSString* GitRepositoryPerform(NSString* root, GitRepositoryAction action, NSArray<NSString*>* paths, NSString* message)
{
	NSArray* arguments;
	NSTimeInterval timeout = 30;
	if(action <= GitRepositoryDiscard) {
		if(!paths.count) return @"Select a file first.";
		if(action == GitRepositoryStage) arguments = @[@"add", @"-A"];
		else if(action == GitRepositoryDiscard) arguments = @[@"restore", @"--worktree"];
		else {
			NSDictionary* revision = ProjectChangesRevision(root);
			if(revision[@"error"]) return revision[@"error"];
			arguments = [revision[@"head"] length] ? @[@"restore", @"--staged"] : @[@"rm", @"--cached", @"--force"];
		}
		arguments = [[arguments arrayByAddingObject:@"--"] arrayByAddingObjectsFromArray:paths];
	} else if(action == GitRepositoryCommit) {
		return GitRepositoryCommitChanges(root, message, nil, NO);
	} else if(action == GitRepositorySwitchBranch || action == GitRepositoryCreateBranch) {
		if(!message.length) return @"Enter a branch name.";
		arguments = action == GitRepositorySwitchBranch ? @[@"switch", @"--no-guess", @"--", message] : @[@"switch", @"--create", message];
	} else {
		timeout = 90;
		if(action == GitRepositoryFetch) arguments = @[@"fetch", @"--all"];
		else if(action == GitRepositoryPull) arguments = @[@"pull", @"--ff-only"];
		else if(action == GitRepositoryPush) arguments = @[@"push"];
		else return @"This Git action needs more information.";
	}
	return RunMutation(root, arguments, @"Git could not complete the operation.", timeout);
}

NSDictionary* GitRepositoryCommitContext(NSString* root, NSString* head)
{
	NSMutableDictionary* context = [NSMutableDictionary dictionary];
	NSString* identity = GitText(GitRepositoryCommand(root, @[@"var", @"GIT_COMMITTER_IDENT"]));
	NSRange start = [identity rangeOfString:@" <" options:NSBackwardsSearch];
	NSRange end = [identity rangeOfString:@">" options:NSBackwardsSearch];
	if(identity && start.location != NSNotFound && end.location != NSNotFound && NSMaxRange(start) <= end.location) {
		context[@"name"] = [identity substringToIndex:start.location];
		context[@"email"] = [identity substringWithRange:NSMakeRange(NSMaxRange(start), end.location-NSMaxRange(start))];
	}
	if(head.length) {
		NSDictionary* result = GitRepositoryCommand(root, @[@"log", @"-1", @"--format=%B", head, @"--"]);
		if(!result[@"error"] && ![result[@"status"] intValue]) {
			NSString* message = [GitText(result) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
			if(message.length) context[@"lastMessage"] = message;
		}
	}
	if(NSString* prompt = GitWorkspaceConfig(root, @"textmate.commitPrompt")) context[@"prompt"] = prompt;
	if(NSString* url = GitWorkspaceConfig(root, @"textmate.issueTrackerURL")) {
		context[@"issueURL"] = url;
		context[@"issuePrefix"] = GitWorkspaceConfig(root, @"textmate.issueNumberPrefix") ?: @"#";
	}
	NSString* path = [GitWorkspaceText(GitRepositoryCommand(root, @[@"config", @"--path", @"--get", @"commit.template"])) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
	if(path.length) {
		if(!path.isAbsolutePath) path = [root stringByAppendingPathComponent:path];
		if(NSString* text = GitWorkspaceReadFile(path)[@"text"]) if(text.length) context[@"template"] = text;
	}
	return context;
}

NSString* GitRepositoryCommitChanges(NSString* root, NSString* message, NSString* amendHead, BOOL signOff)
{
	BOOL hasMessage = [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length != 0;
	NSMutableArray* args = [NSMutableArray arrayWithObject:@"commit"];
	if(amendHead.length) {
		NSDictionary* revision = ProjectChangesRevision(root);
		if(revision[@"error"]) return revision[@"error"];
		if(![revision[@"head"] isEqualToString:amendHead]) return @"The last commit changed. Review it before amending.";
		[args addObject:@"--amend"];
	}
	if(hasMessage) {
		NSString* convert = [GitWorkspaceText(GitRepositoryCommand(root, @[@"config", @"--bool", @"--get", @"textmate.convertGitMoji"])) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
		[args addObjectsFromArray:@[@"--message", [convert isEqual:@"true"] ? ConvertGitMoji(message) : message]];
	}
	else if(amendHead.length) [args addObject:@"--no-edit"];
	else return @"Enter a commit message.";
	if(signOff) [args addObject:@"--signoff"];
	NSDictionary* result = GitRepositoryCommand(root, args, YES, 30);
	if(result[@"error"]) return result[@"error"];
	if(![result[@"status"] intValue]) return nil;
	NSString* error = [GitText(result) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	return error.length > 2000 ? [error substringToIndex:2000] : error.length ? error : @"Git could not commit the staged changes.";
}

NSDictionary* GitRepositoryBranches(NSString* root)
{
	NSDictionary* result = GitRepositoryCommand(root, @[@"for-each-ref", @"--format=%(refname:lstrip=2)", @"refs/heads"]);
	if(NSString* error = GitFailure(result, @"Git could not read the local branches.")) return @{ @"error": error };
	NSString* names = [GitText(result) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
	return @{ @"branches": names.length ? [names componentsSeparatedByString:@"\n"] : @[] };
}

NSDictionary* GitRepositoryHistory(NSString* directory, NSUInteger limit)
{
	return GitRepositoryHistoryForRef(directory, nil, limit);
}

NSDictionary* GitRepositoryReferences(NSString* root)
{
	NSDictionary* refs = GitRepositoryCommand(root, @[@"for-each-ref", @"--format=%(refname)%09%(symref)", @"refs/heads", @"refs/tags", @"refs/remotes"]);
	if(NSString* error = GitFailure(refs, @"Git could not read the repository’s references.")) return @{ @"error": error };
	NSMutableArray* names = [NSMutableArray array];
	NSString* text = GitText(refs);
	for(NSString* line in [text componentsSeparatedByString:@"\n"]) {
		NSArray* fields = [line componentsSeparatedByString:@"\t"];
		if(fields.count == 2 && [fields[0] length] && ![fields[1] length]) [names addObject:fields[0]];
	}
	NSDictionary* merged = GitRepositoryCommand(root, @[@"for-each-ref", @"--merged=HEAD", @"--format=%(refname)", @"refs/heads"]);
	NSArray* mergedNames = [merged[@"status"] intValue] == 0 ? [GitText(merged) componentsSeparatedByString:@"\n"] : @[];
	NSDictionary* stashes = GitRepositoryCommand(root, @[@"stash", @"list", @"--format=%gd"]);
	NSUInteger stashCount = 0;
	if([stashes[@"status"] intValue] == 0)
		for(NSString* line in [GitText(stashes) componentsSeparatedByString:@"\n"]) if(line.length) ++stashCount;
	return @{ @"refs": names, @"merged": mergedNames ?: @[], @"stashCount": @(stashCount) };
}

NSDictionary* GitRepositoryStashes(NSString* root, NSUInteger limit, NSString* query)
{
	NSDictionary* revision = ProjectChangesRevision(root);
	if(revision[@"error"]) return @{ @"error": revision[@"error"] };
	root = revision[@"root"];
	NSMutableArray* arguments = [NSMutableArray arrayWithArray:@[@"stash", @"list", @"-z", @"--format=%H%x00%gd%x00%gs%x00%an%x00%aI"]];
	if(!query.length) [arguments addObject:[NSString stringWithFormat:@"--max-count=%lu", (unsigned long)(limit+1)]];
	NSDictionary* result = GitRepositoryCommand(root, arguments);
	if(NSString* error = GitFailure(result, @"Git could not read the stash list.")) return @{ @"error": error };
	NSArray* fields = NulFields(result[@"data"]);
	NSMutableArray* stashes = [NSMutableArray array];
	BOOL more = NO;
	for(NSUInteger offset = 0; offset+4 < fields.count; offset += 5) {
		NSString* subject = fields[offset+2];
		if(query.length && ![subject localizedStandardContainsString:query]) continue;
		if(stashes.count == limit) { more = YES; break; }
		[stashes addObject:@{ @"id": fields[offset], @"refs": fields[offset+1], @"subject": subject, @"author": fields[offset+3], @"date": fields[offset+4] }];
	}
	return @{ @"root": root, @"commits": stashes, @"more": @(more) };
}

NSDictionary* GitRepositoryStashDiff(NSString* root, NSString* commit)
{
	return PatchResult(GitRepositoryCommand(root, @[@"stash", @"show", @"--patch", @"--include-untracked", @"--no-ext-diff", @"--no-textconv", @"--no-color", commit]));
}

static NSArray<NSString*>* RevisionChangesOptions()
{
	return @[@"--raw", @"--numstat", @"--no-renames", @"--no-ext-diff", @"--no-textconv", @"-z"];
}

static NSDictionary* RevisionChanges(NSDictionary* result, NSString* fallback)
{
	if(NSString* error = GitFailure(result, fallback)) return @{@"error": error};
	NSArray<NSString*>* fields = NulFields(result[@"data"]);
	NSMutableArray* files = [NSMutableArray array];
	NSUInteger offset = 0;
	// With renames disabled, Git emits two NUL fields per raw record, followed by one per numstat record.
	for(; offset+1 < fields.count && [fields[offset] hasPrefix:@":"]; offset += 2) {
		NSRange separator = [fields[offset] rangeOfString:@" " options:NSBackwardsSearch];
		if(separator.location != NSNotFound && fields[offset+1].length)
			[files addObject:@{@"code": [fields[offset] substringFromIndex:NSMaxRange(separator)], @"path": fields[offset+1]}];
	}
	NSUInteger additions = 0, deletions = 0;
	for(; offset < fields.count; ++offset) {
		NSArray<NSString*>* stats = [fields[offset] componentsSeparatedByString:@"\t"];
		if(stats.count < 3 || [stats[0] isEqual:@"-"]) continue; // Binary files have no line counts.
		additions += [stats[0] longLongValue];
		deletions += [stats[1] longLongValue];
	}
	return @{@"files": files, @"additions": @(additions), @"deletions": @(deletions)};
}

NSDictionary* GitRepositoryRangeChanges(NSString* root, NSString* range)
{
	NSArray* arguments = [[@[@"diff"] arrayByAddingObjectsFromArray:RevisionChangesOptions()] arrayByAddingObjectsFromArray:@[range, @"--"]];
	return RevisionChanges(GitRepositoryCommand(root, arguments), @"Git could not compare these branches.");
}

NSDictionary* GitRepositoryStashDetails(NSString* root, NSString* commit)
{
	NSArray* arguments = [[@[@"stash", @"show", @"--include-untracked"] arrayByAddingObjectsFromArray:RevisionChangesOptions()] arrayByAddingObject:commit];
	NSDictionary* changes = RevisionChanges(GitRepositoryCommand(root, arguments), @"Git could not read this stash’s files.");
	if(changes[@"error"]) return changes;
	NSMutableDictionary* details = [RevisionMetadata(root, commit) mutableCopy];
	[details addEntriesFromDictionary:changes];
	return details;
}

NSString* GitRepositoryOpenRevisionDiffTool(NSString* root, NSString* base, NSString* revision, NSString* path)
{
	NSString* tool = GitWorkspaceConfig(root, @"diff.guitool");
	if(!tool.length) tool = GitWorkspaceConfig(root, @"diff.tool");
	if(!tool.length) return @"Set diff.guitool or diff.tool in Git to use an external diff tool.";
	if(!base.length) {
		NSDictionary* empty = GitRepositoryCommand(root, @[@"hash-object", @"-w", @"-t", @"tree", @"--stdin"], YES);
		if(NSString* error = GitWorkspaceError(empty, @"Git could not prepare the empty tree.")) return error;
		base = [GitText(empty) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
	}
	if(!base.length || !revision.length) return @"Git could not find both sides of the comparison.";
	NSMutableArray* args = [@[@"difftool", @"--no-prompt", @"--trust-exit-code", [@"--tool=" stringByAppendingString:tool]] mutableCopy];
	if(!path) [args addObjectsFromArray:@[@"--dir-diff", @"--no-symlinks"]];
	[args addObjectsFromArray:@[base, revision, @"--"]];
	if(path) [args addObject:path];
	return RunMutation(root, args, @"The configured diff tool could not finish.", 600);
}

NSString* GitRepositoryOpenStashDiffTool(NSString* root, NSString* commit, NSString* path)
{
	NSDictionary* metadata = RevisionMetadata(root, commit);
	NSArray<NSString*>* parents = metadata[@"parents"];
	if(parents.count < 2) return @"Git could not find the saved stash.";
	NSString* saved = commit, *error = nil;
	if(parents.count > 2) {
		// Combine the tracked and untracked snapshots in a private index so the
		// diff can include the entire stash without changing the checkout.
		NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"textmate-stash-diff-" stringByAppendingString:NSUUID.UUID.UUIDString]];
		NSFileManager* files = NSFileManager.defaultManager;
		NSError* fileError;
		if(![files createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:&fileError]) return fileError.localizedDescription;
		NSString* index = [directory stringByAppendingPathComponent:@"index"];
		NSDictionary* read = GitRepositoryCommandWithIndex(root, @[@"read-tree", commit, parents[2]], index, nil);
		error = GitWorkspaceError(read, @"Git could not prepare the stash for comparison.");
		if(!error) {
			NSDictionary* write = GitRepositoryCommandWithIndex(root, @[@"write-tree"], index, nil);
			error = GitWorkspaceError(write, @"Git could not prepare the stash for comparison.");
			saved = [GitText(write) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
		}
		[files removeItemAtPath:directory error:nil];
	}
	if(error || !saved.length) return error ?: @"Git could not prepare the stash for comparison.";
	return GitRepositoryOpenRevisionDiffTool(root, parents[0], saved, path);
}

NSDictionary* GitRepositoryStashFileDiff(NSString* root, NSString* commit, NSString* path)
{
	NSString* untracked = [commit stringByAppendingString:@"^3"];
	NSString* blob = [untracked stringByAppendingFormat:@":%@", path];
	NSDictionary* probe = GitRepositoryCommand(root, @[@"cat-file", @"-e", blob]);
	if(probe[@"error"]) return @{@"error": probe[@"error"]};
	BOOL onlyUntracked = [probe[@"status"] intValue] == 0;
	if(onlyUntracked) return PatchResult(GitRepositoryCommand(root, @[@"diff-tree", @"--root", @"--no-commit-id", @"-r", @"-p", @"--no-ext-diff", @"--no-textconv", @"--no-color", untracked, @"--", path]));
	return GitRepositoryCommitDiff(root, @{@"id": commit, @"parents": @[[commit stringByAppendingString:@"^1"]]}, path);
}

NSDictionary* GitRepositoryRevisionTree(NSString* root, NSString* revision, NSString* folder)
{
	NSString* tree = folder.length ? [revision stringByAppendingFormat:@":%@", folder] : revision;
	NSDictionary* result = GitRepositoryCommand(root, @[@"ls-tree", @"-z", tree]);
	if(NSString* error = GitFailure(result, @"Git could not read this tree.")) return @{@"error": error};
	NSMutableArray* entries = [NSMutableArray array];
	for(NSString* field in NulFields(result[@"data"])) {
		NSRange tab = [field rangeOfString:@"\t"];
		if(tab.location == NSNotFound) continue;
		NSArray* meta = [[field substringToIndex:tab.location] componentsSeparatedByString:@" "];
		if(meta.count != 3) continue;
		NSString* name = [field substringFromIndex:NSMaxRange(tab)];
		NSString* path = folder.length ? [folder stringByAppendingFormat:@"/%@", name] : name;
		[entries addObject:@{@"name": name, @"path": path, @"object": meta[2], @"kind": meta[1]}];
	}
	return @{@"entries": entries};
}

NSDictionary* GitRepositoryRevisionFile(NSString* root, NSString* object)
{
	NSDictionary* result = GitRepositoryCommand(root, @[@"cat-file", @"blob", object]);
	if(NSString* error = GitFailure(result, @"Git could not read this file.")) return @{@"error": error};
	NSData* data = result[@"data"];
	if(data.length && memchr(data.bytes, 0, data.length)) return @{@"text": @"Binary file"};
	return GitWorkspaceText(result) ? @{@"text": GitWorkspaceText(result)} : @{@"text": @"Binary file or text in a different encoding"};
}

NSString* GitRepositoryApplyHunk(NSDictionary* snapshot, NSDictionary* change, NSString* hunk, GitRepositoryAction action, NSUInteger contextLines)
{
	BOOL staged = [change[@"group"] unsignedIntegerValue] == GitChangeStaged;
	if(![change[@"code"] isEqual:@"M"] || [change[@"unsaved"] boolValue] || (staged ? action != GitRepositoryUnstage : action != GitRepositoryStage && action != GitRepositoryDiscard)) return @"Select a hunk in a saved, modified file.";
	NSString* root = snapshot[@"root"];
	NSDictionary* diff = GitRepositoryChangeDiff(snapshot, change, nil, contextLines);
	if(diff[@"error"]) return diff[@"error"];
	NSString* text = diff[@"text"];
	NSRange first = [text rangeOfString:@"\n@@ "];
	if(!text.length || first.location == NSNotFound || ![text hasPrefix:@"diff --git "] || [[text substringFromIndex:first.location] containsString:@"\ndiff --git "]) return @"This diff cannot be applied one hunk at a time.";
	NSArray* parts = [text componentsSeparatedByString:@"\n@@ "];
	BOOL matched = NO;
	for(NSUInteger i = 1; i < parts.count; ++i) if([[@"@@ " stringByAppendingString:parts[i]] isEqual:[hunk hasSuffix:@"\n"] ? [hunk substringToIndex:hunk.length-1] : hunk] || [[@"@@ " stringByAppendingString:parts[i]] isEqual:hunk]) { matched = YES; break; }
	if(!matched) return @"This hunk changed. Refresh the diff and try again.";
	NSString* patch = [NSString stringWithFormat:@"%@\n%@%@", parts[0], hunk, [hunk hasSuffix:@"\n"] ? @"" : @"\n"];
	// Omit whole-file mode changes from a partial patch.
	NSMutableArray* lines = [[patch componentsSeparatedByString:@"\n"] mutableCopy];
	for(NSInteger i = 1; i < lines.count && ![lines[i] hasPrefix:@"@@ "]; ++i)
		if([lines[i] hasPrefix:@"old mode "] || [lines[i] hasPrefix:@"new mode "]) [lines removeObjectAtIndex:i--];
	NSData* data = [[lines componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
	NSString* temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"textmate-hunk-" stringByAppendingString:NSUUID.UUID.UUIDString]];
	if(![data writeToFile:temporary options:NSDataWritingWithoutOverwriting error:nil]) return @"Could not prepare the selected hunk.";
	NSMutableArray* args = [NSMutableArray arrayWithObject:@"apply"];
	if(action != GitRepositoryDiscard) [args addObject:@"--cached"];
	if(action != GitRepositoryStage) [args addObject:@"--reverse"];
	[args addObjectsFromArray:@[@"--", temporary]];
	NSString* error = RunMutation(root, args, @"Git could not apply the selected hunk.");
	[NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
	return error;
}

NSString* GitRepositoryCreateTrackingBranch(NSString* root, NSString* name, NSString* remoteRef)
{
	if(!name.length) return @"Enter a branch name.";
	if(![remoteRef hasPrefix:@"refs/remotes/"]) return @"Select a remote branch first.";
	return RunMutation(root, @[@"switch", @"--track", @"--create", name, @"--", remoteRef], @"Git could not create the tracking branch.");
}

NSString* GitRepositoryStashChanges(NSString* root, NSString* message, BOOL includeUntracked)
{
	// Stash builds its own pathspecs when cleaning up saved untracked files.
	NSMutableArray* args = [NSMutableArray arrayWithArray:@[@"--no-literal-pathspecs", @"stash", @"push"]];
	if(includeUntracked) [args addObject:@"--include-untracked"];
	if(message.length) [args addObjectsFromArray:@[@"--message", message]];
	return RunMutation(root, args, @"Git could not save the stash.");
}

static BOOL StashStillMatches(NSString* root, NSDictionary* stash)
{
	NSString* selector = stash[@"refs"];
	if(![selector hasPrefix:@"stash@{"] || ![selector hasSuffix:@"}"] || ![stash[@"id"] length]) return NO;
	NSDictionary* result = GitRepositoryCommand(root, @[@"rev-parse", @"--verify", @"--end-of-options", selector]);
	return !GitFailure(result, @"Unavailable stash") && [stash[@"id"] isEqual:[GitText(result) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]];
}

NSString* GitRepositoryDropSavedStash(NSString* root, NSDictionary* stash)
{
	if(!StashStillMatches(root, stash)) return @"The stash list changed. Refresh and select the stash again.";
	return RunMutation(root, @[@"stash", @"drop", @"--", stash[@"refs"]], @"Git could not delete the stash.");
}

NSString* GitRepositoryApplySavedStash(NSString* root, NSDictionary* stash, BOOL restoreIndex, BOOL dropAfterApplying)
{
	if(!StashStillMatches(root, stash)) return @"The stash list changed. Refresh and select the stash again.";
	if(restoreIndex) {
		// Some Git versions reset the index before merging the stash. A failed
		// merge can then leave unrelated changes unstaged.
		NSDictionary* staged = GitRepositoryCommand(root, @[@"diff", @"--cached", @"--no-ext-diff", @"--quiet"]);
		if(!staged[@"error"] && [staged[@"status"] intValue] == 1) return @"Commit or unstage the existing staged changes before restoring the stash’s staged changes.";
		if(NSString* error = GitFailure(staged, @"Could not check the index before applying the stash.")) return error;
	}
	NSMutableArray* args = [NSMutableArray arrayWithArray:@[@"stash", @"apply"]];
	if(restoreIndex) [args addObject:@"--index"];
	[args addObjectsFromArray:@[@"--", stash[@"id"]]];
	NSString* error = RunMutation(root, args, @"Git could not apply the stash.");
	if(error || !dropAfterApplying) return error;
	if(NSString* dropError = GitRepositoryDropSavedStash(root, stash))
		return [@"The changes were applied, but the stash was kept. " stringByAppendingString:dropError];
	return nil;
}

NSDictionary* GitRepositoryHistoryForRef(NSString* directory, NSString* ref, NSUInteger limit)
{
	return GitRepositorySearchHistory(directory, ref, limit, nil, GitHistorySearchMessage);
}

NSDictionary* GitRepositoryToolbarContext(NSString* root, NSString* branch)
{
	NSDictionary* names = GitRepositoryCommand(root, @[@"remote"]);
	NSMutableDictionary* context = [NSMutableDictionary dictionary];
	if(NSString* error = GitFailure(names, @"Git could not read configured remotes.")) return @{ @"error": error };
	NSString* text = [GitText(names) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
	context[@"remotes"] = text.length ? [text componentsSeparatedByString:@"\n"] : @[];
	if([context[@"remotes"] count]) {
		NSDictionary* refs = GitRepositoryCommand(root, @[@"for-each-ref", @"--format=%(refname:lstrip=2)%09%(symref)", @"refs/remotes"]);
		NSMutableArray* branches = [NSMutableArray array];
		for(NSString* line in [GitText(refs) componentsSeparatedByString:@"\n"]) {
			NSArray* fields = [line componentsSeparatedByString:@"\t"];
			if(fields.count == 2 && [fields[0] length] && ![fields[1] length]) [branches addObject:fields[0]];
		}
		context[@"remoteBranches"] = branches;
	}
	NSArray* markers = [[GitText(GitRepositoryCommand(root, @[@"rev-parse", @"--path-format=absolute", @"--git-path", @"rebase-merge", @"--git-path", @"rebase-apply", @"--git-path", @"MERGE_HEAD", @"--git-path", @"CHERRY_PICK_HEAD", @"--git-path", @"REVERT_HEAD"])) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsSeparatedByString:@"\n"];
	if(markers.count == 5) {
		NSFileManager* files = NSFileManager.defaultManager;
		if([files fileExistsAtPath:markers[0]] || [files fileExistsAtPath:[markers[1] stringByAppendingPathComponent:@"rebasing"]]) context[@"integration"] = @"rebase";
		else if([files fileExistsAtPath:markers[2]]) context[@"integration"] = @"merge";
		else if([files fileExistsAtPath:markers[3]]) context[@"integration"] = @"cherry-pick";
		else if([files fileExistsAtPath:markers[4]]) context[@"integration"] = @"revert";
	}
	if(branch.length && ![branch isEqual:@"Detached HEAD"]) {
		NSDictionary* upstream = GitRepositoryCommand(root, @[@"for-each-ref", @"--format=%(upstream:remotename)%09%(upstream:remoteref)", [@"refs/heads/" stringByAppendingString:branch]]);
		NSArray* fields = [[GitText(upstream) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsSeparatedByString:@"\t"];
		if(fields.count == 2 && [fields[0] length] && [fields[1] hasPrefix:@"refs/heads/"]) {
			context[@"remote"] = fields[0];
			context[@"branch"] = [fields[1] substringFromIndex:11];
		}
	}
	return context;
}

NSString* GitRepositoryIntegrate(NSString* root, GitRepositoryAction action, NSString* ref, GitMergeOptions options)
{
	if(![ref hasPrefix:@"refs/heads/"] && ![ref hasPrefix:@"refs/remotes/"] && ![ref hasPrefix:@"refs/tags/"]) return @"Select a branch or tag first.";
	if(action == GitRepositoryMerge) {
		NSMutableArray* args = [NSMutableArray arrayWithArray:@[@"merge", @"--no-edit", @"--no-autostash"]];
		if(options & GitMergeSquash) [args addObject:@"--squash"];
		else if(options & (GitMergeNoCommit | GitMergeNoFastForward)) [args addObject:@"--no-ff"];
		if(options & (GitMergeSquash | GitMergeNoCommit)) [args addObject:@"--no-commit"];
		if(options & GitMergeVerifySignatures) [args addObject:@"--verify-signatures"];
		[args addObjectsFromArray:@[@"--", ref]];
		return RunMutation(root, args, @"Git could not merge this branch.");
	}
	if(action == GitRepositoryRebase) return RunMutation(root, @[@"rebase", @"--no-autostash", @"--", ref], @"Git could not rebase this branch.");
	return @"Unsupported integration action.";
}

NSString* GitRepositoryFinishIntegration(NSString* root, NSString* operation, BOOL abort)
{
	if(![@[@"merge", @"rebase", @"cherry-pick", @"revert"] containsObject:operation ?: @""]) return @"No Git integration is in progress.";
	return RunMutation(root, @[@"-c", @"core.editor=true", operation, abort ? @"--abort" : @"--continue"], @"Git could not finish this operation.");
}

NSString* GitRepositoryRemoteAction(NSString* root, GitRepositoryAction action, NSString* remote, NSString* branch, NSString* pullMode, NSString* expectedBranch, GitPullOptions options, GitPushOptions pushOptions)
{
	if(action == GitRepositoryFetch) {
		NSMutableArray* args = [NSMutableArray arrayWithObject:@"fetch"];
		if(options & GitPullPrune) [args addObject:@"--prune"];
		if(options & GitPullFetchSubmodules) [args addObject:@"--recurse-submodules=yes"];
		if(options & GitPullFetchTags) [args addObject:@"--tags"];
		[args addObjectsFromArray:remote.length ? @[@"--", remote] : @[@"--all"]];
		return RunMutation(root, args, @"Git could not fetch updates.", 90);
	}
	if(!remote.length || !branch.length) return @"Select a remote and branch first.";
	NSString* (^currentRef)(void) = ^NSString*{
		return [GitText(GitRepositoryCommand(root, @[@"symbolic-ref", @"--quiet", @"HEAD"])) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
	};
	NSString* source = currentRef();
	if(![source hasPrefix:@"refs/heads/"] || (expectedBranch && ![source isEqual:[@"refs/heads/" stringByAppendingString:expectedBranch]]))
		return @"The checked out branch changed. Refresh and try again.";
	NSString* ref = [@"refs/heads/" stringByAppendingString:branch];
	if(GitFailure(GitRepositoryCommand(root, @[@"check-ref-format", ref]), @"Invalid branch name")) return @"Enter a valid branch name.";
	if(action == GitRepositoryPull || action == GitRepositorySync) {
		NSArray* strategy = [pullMode isEqual:@"rebase"] ? @[@"--rebase", @"--no-autostash"] : [pullMode isEqual:@"merge"] ? @[@"--no-rebase", @"--ff", @"--no-autostash", @"--no-edit"] : @[@"--no-rebase", @"--ff-only"];
		NSMutableArray* args = [NSMutableArray arrayWithObject:@"pull"];
		[args addObjectsFromArray:strategy];
		if(options & GitPullFetchSubmodules) [args addObject:@"--recurse-submodules=yes"];
		if(options & GitPullFetchTags) [args addObject:@"--tags"];
		[args addObjectsFromArray:@[@"--", remote, ref]];
		NSString* error = RunMutation(root, args, @"Git could not pull this branch.", 90);
		// A pull with an explicit branch can only prune that branch's refspec.
		if(!error && (options & GitPullPrune)) {
			error = RunMutation(root, @[@"remote", @"prune", @"--", remote], @"Git could not prune obsolete remote branches.", 90);
			if(error) error = [@"Pull succeeded, but pruning failed. " stringByAppendingString:error];
		}
		if(error || action == GitRepositoryPull) return error;
	}
	if(action == GitRepositoryPush || action == GitRepositorySync) {
		if(action == GitRepositorySync && ![source isEqual:currentRef()]) return @"Pull succeeded, but the checked out branch changed before push.";
		NSMutableArray* args = [NSMutableArray arrayWithObject:@"push"];
		if(pushOptions & GitPushTags) [args addObject:@"--tags"];
		if(pushOptions & GitPushVerifySubmodules) [args addObject:@"--recurse-submodules=check"];
		else if(pushOptions & GitPushSubmodulesOnDemand) [args addObject:@"--recurse-submodules=on-demand"];
		[args addObjectsFromArray:@[@"--", remote, [NSString stringWithFormat:@"%@:%@", source, ref]]];
		NSString* error = RunMutation(root, args, @"Git could not push this branch.", 90);
		return error && action == GitRepositorySync ? [@"Pull succeeded, but push failed. " stringByAppendingString:error] : error;
	}
	return @"Unsupported remote action.";
}

NSDictionary* GitRepositorySearchHistory(NSString* directory, NSString* ref, NSUInteger limit, NSString* query, GitHistorySearch scope)
{
	NSDictionary* revision = ProjectChangesRevision(directory);
	if(revision[@"error"]) return revision;
	NSString* root = revision[@"root"];
	NSMutableArray* arguments = [NSMutableArray arrayWithArray:@[@"log", @"--topo-order", @"--decorate=short", @"-z",
		[NSString stringWithFormat:@"--max-count=%lu", (unsigned long)(limit+1)], @"--format=%H%x00%P%x00%an%x00%aI%x00%s%x00%D"]];
	if(query.length && (scope == GitHistorySearchMessage || scope == GitHistorySearchAuthor)) {
		[arguments addObjectsFromArray:@[@"--fixed-strings", @"--regexp-ignore-case", [(scope == GitHistorySearchAuthor ? @"--author=" : @"--grep=") stringByAppendingString:query]]];
	}
	if(query.length && scope == GitHistorySearchHash) {
		NSDictionary* empty = @{ @"root": root, @"commits": @[], @"more": @NO };
		if(query.length < 4 || [query rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location != NSNotFound) return empty;
		NSDictionary* resolved = GitRepositoryCommand(root, @[@"rev-parse", @"--verify", @"--end-of-options", [query stringByAppendingString:@"^{commit}"]]);
		if(GitFailure(resolved, @"Commit not found")) return empty;
		NSString* hash = [GitText(resolved) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
		if([ref hasPrefix:@"refs/"]) {
			if(GitFailure(GitRepositoryCommand(root, @[@"merge-base", @"--is-ancestor", hash, ref]), @"Commit outside this history")) return empty;
		} else {
			NSDictionary* containingRefs = GitRepositoryCommand(root, @[@"for-each-ref", @"--count=1", @"--format=%(refname)", [@"--contains=" stringByAppendingString:hash]]);
			if(![GitText(containingRefs) length] && GitFailure(GitRepositoryCommand(root, @[@"merge-base", @"--is-ancestor", hash, @"HEAD"]), @"Commit outside this history")) return empty;
		}
		[arguments addObjectsFromArray:@[@"--no-walk", hash]];
	} else if([ref hasPrefix:@"refs/"]) [arguments addObject:ref];
	else {
		[arguments addObjectsFromArray:@[@"--exclude=refs/stash", [@"--exclude=refs/heads/" stringByAppendingFormat:@"%@*", GitWorkspaceArchivePrefix], @"--all"]];
		if([revision[@"head"] length]) [arguments addObject:revision[@"head"]];
	}
	[arguments addObject:@"--"];
	if(query.length && scope == GitHistorySearchFile) [arguments addObject:query];
	NSDictionary* result = GitRepositoryCommand(root, arguments);
	if(NSString* error = GitFailure(result, @"Git could not read the commit history.")) return @{ @"error": error };
	NSArray<NSString*>* fields = NulFields(result[@"data"]);
	NSMutableArray* commits = [NSMutableArray array];
	for(NSUInteger offset = 0; offset+5 < fields.count && commits.count < limit; offset += 6) {
		NSArray* parents = fields[offset+1].length ? [fields[offset+1] componentsSeparatedByString:@" "] : @[];
		[commits addObject:@{ @"id": fields[offset], @"parents": parents, @"author": fields[offset+2], @"date": fields[offset+3],
			@"subject": fields[offset+4], @"refs": fields[offset+5], @"head": @([fields[offset] isEqual:revision[@"head"]]) }];
	}
	BOOL more = fields.count/6 > commits.count;
	NSUInteger total = commits.count;
	if(more && !query.length) {
		NSMutableArray* count = [NSMutableArray arrayWithArray:@[@"rev-list", @"--count"]];
		if([ref hasPrefix:@"refs/"]) [count addObject:ref];
		else {
			[count addObjectsFromArray:@[@"--exclude=refs/stash", [@"--exclude=refs/heads/" stringByAppendingFormat:@"%@*", GitWorkspaceArchivePrefix], @"--all"]];
			if([revision[@"head"] length]) [count addObject:revision[@"head"]];
		}
		[count addObject:@"--"];
		NSUInteger found = [GitText(GitRepositoryCommand(root, count)) longLongValue];
		if(found > total) total = found;
	}
	NSSet* primary = commits.count ? PrimaryHistoryCommits(root, ref, revision[@"head"], limit, query.length > 0) : NSSet.set;
	return @{ @"root": root, @"commits": commits, @"more": @(more), @"total": @(total), @"primaryCommits": primary };
}

NSDictionary* GitRepositoryCommitDetails(NSString* root, NSDictionary* commit)
{
	NSDictionary* changes = RevisionChanges(GitRepositoryCommand(root, CommitArguments(commit, RevisionChangesOptions(), @[])), @"Git could not read this commit’s files.");
	if(changes[@"error"]) return changes;
	NSMutableDictionary* details = [RevisionMetadata(root, commit[@"id"]) mutableCopy];
	[details addEntriesFromDictionary:changes];
	return details;
}

static NSDictionary* RevisionMetadata(NSString* root, NSString* hash)
{
	NSDictionary* result = GitRepositoryCommand(root, @[@"show", @"--no-patch", @"--format=%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI%x00%T%x00%P%x00%D%x00%B%x00", hash, @"--"]);
	NSArray* fields = NulFields(result[@"data"]);
	if(fields.count < 10) return @{@"id": hash, @"message": @""};
	return @{@"id": hash, @"author": fields[0], @"email": fields[1], @"date": fields[2], @"committer": fields[3], @"committerEmail": fields[4], @"committerDate": fields[5],
		@"tree": fields[6], @"parents": [fields[7] length] ? [fields[7] componentsSeparatedByString:@" "] : @[], @"refs": fields[8], @"message": [fields[9] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]};
}

NSDictionary* GitRepositoryCommitDiff(NSString* root, NSDictionary* commit, NSString* path)
{
	return PatchResult(GitRepositoryCommand(root, CommitArguments(commit, @[@"--patch", @"--no-renames", @"--no-ext-diff", @"--no-textconv", @"--no-color"], path ? @[path] : @[])));
}

NSArray<NSDictionary*>* GitGraphLayout(NSArray<NSDictionary*>* commits, NSSet<NSString*>* primaryCommits)
{
	NSUInteger sideStart = primaryCommits.count ? 1 : 0;
	std::vector<Lane> lanes(sideStart); // Lane zero stays available even if a topic appears before the primary tip.
	NSUInteger nextColor = sideStart;
	NSMutableArray<NSString*>* visiblePrimary = [NSMutableArray array];
	for(NSDictionary* commit in commits) if([primaryCommits containsObject:commit[@"id"]]) [visiblePrimary addObject:commit[@"id"]];
	NSUInteger primaryIndex = 0;
	NSMutableArray* rows = [NSMutableArray arrayWithCapacity:commits.count];
	for(NSDictionary* commit in commits) {
		NSString* identifier = commit[@"id"];
		BOOL primary = [primaryCommits containsObject:identifier];
		NSUInteger node = primary ? 0 : FindLane(lanes, identifier, sideStart);
		if(node == NSNotFound) {
			node = ReserveLane(lanes, sideStart);
			lanes[node].color = nextColor++;
		}
		NSUInteger color = lanes[node].color;
		NSMutableArray* incoming = [NSMutableArray array];
		NSMutableArray* outgoing = [NSMutableArray array];
		for(NSUInteger index = 0; index < lanes.size(); ++index) {
			if(!lanes[index].commit) continue;
			BOOL endsHere = [lanes[index].commit isEqual:identifier];
			[incoming addObject:@[@(index), @(endsHere ? node : index), @(lanes[index].color)]];
			if(endsHere) lanes[index].commit = nil;
			else [outgoing addObject:@[@(index), @(index), @(lanes[index].color)]];
		}
		if(primary) ++primaryIndex;
		BOOL firstParent = YES;
		for(NSString* parent in commit[@"parents"]) {
			NSUInteger target;
			if(primary && firstParent) {
				target = 0;
				// A search may hide first parents between two visible primary commits.
				lanes[target] = {primaryIndex < visiblePrimary.count ? visiblePrimary[primaryIndex] : parent, color};
			} else {
				// Keep side lanes separate until they reach the commit where they meet the primary history.
				target = [primaryCommits containsObject:parent] ? NSNotFound : FindLane(lanes, parent, sideStart);
				if(target == NSNotFound) {
				target = firstParent ? node : ReserveLane(lanes, node+1);
				lanes[target] = {parent, firstParent ? color : nextColor++};
				}
			}
			[outgoing addObject:@[@(node), @(target), @(lanes[target].color)]];
			firstParent = NO;
		}
		[rows addObject:@{ @"node": @(node), @"color": @(color), @"incoming": incoming, @"outgoing": outgoing, @"tracks": @(lanes.size()) }];
		while(lanes.size() > sideStart && !lanes.back().commit) lanes.pop_back();
	}
	return rows;
}
