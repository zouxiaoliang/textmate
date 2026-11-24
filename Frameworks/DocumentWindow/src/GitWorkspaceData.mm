#import "GitWorkspaceData.h"
#import <scm/drivers/api.h>

NSDictionary* GitWorkspaceCommand(NSString* executable, NSString* directory, NSArray<NSString*>* arguments, BOOL mutation, NSTimeInterval timeout, BOOL git);

NSString* const GitWorkspaceArchivePrefix = @"textmate-archive/";

NSString* GitWorkspaceText(NSDictionary* result)
{
	return [[NSString alloc] initWithData:result[@"data"] ?: NSData.data encoding:NSUTF8StringEncoding];
}

NSString* GitWorkspaceError(NSDictionary* result, NSString* fallback)
{
	if(result[@"error"]) return result[@"error"];
	if(![result[@"status"] intValue]) return nil;
	NSString* text = [GitWorkspaceText(result) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	return text.length ? [text substringToIndex:MIN(text.length, 1200)] : fallback;
}

NSString* GitWorkspaceConfig(NSString* root, NSString* key)
{
	NSDictionary* result = GitRepositoryCommand(root, @[@"config", @"--get", key]);
	NSString* text = GitWorkspaceText(result);
	return ![result[@"status"] intValue] && [text hasSuffix:@"\n"] ? [text substringToIndex:text.length-1] : nil;
}

NSString* GitWorkspaceSetConfig(NSString* root, NSString* key, NSString* value)
{
	NSDictionary* result = GitRepositoryCommand(root, value.length ? @[@"config", @"--local", @"--replace-all", key, value] : @[@"config", @"--local", @"--unset-all", key], YES);
	if(!value.length && [result[@"status"] intValue] == 5) return nil;
	return GitWorkspaceError(result, @"Git could not update the repository configuration.");
}

NSString* GitWorkspacePath(NSString* root, NSString* name)
{
	NSDictionary* result = GitRepositoryCommand(root, @[@"rev-parse", @"--git-path", name]);
	NSString* path = GitWorkspaceText(result);
	if([result[@"status"] intValue] || ![path hasSuffix:@"\n"]) return nil;
	path = [path substringToIndex:path.length-1];
	return path.isAbsolutePath ? path : [root stringByAppendingPathComponent:path];
}

NSDictionary* GitWorkspaceReadFile(NSString* path)
{
	if(!path.length) return @{@"error": @"Git could not find this file."};
	NSError* error = nil;
	NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:&error];
	if(!attributes && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)) return @{@"data": NSData.data, @"text": @""};
	if(!attributes) return @{@"error": error.localizedDescription ?: @"The file could not be read."};
	if(![attributes[NSFileType] isEqual:NSFileTypeRegular]) return @{@"error": @"Open this file in the editor to modify it."};
	if([attributes fileSize] > 1024*1024) return @{@"error": @"This file is too large to edit in Settings."};
	NSData* data = [NSData dataWithContentsOfFile:path options:0 error:&error];
	NSString* text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
	return text ? @{@"data": data, @"text": text} : @{@"error": error.localizedDescription ?: @"This file is not UTF-8."};
}

NSString* GitWorkspaceSaveFile(NSString* path, NSData* original, NSString* text)
{
	NSDictionary* current = GitWorkspaceReadFile(path);
	if(current[@"error"]) return current[@"error"];
	if(![current[@"data"] isEqual:original]) return @"This file changed on disk. Reload Settings before saving it.";
	NSData* data = [text dataUsingEncoding:NSUTF8StringEncoding];
	if([data isEqual:original]) return nil;
	NSError* error = nil;
	return [data writeToFile:path options:NSDataWritingAtomic error:&error] ? nil : error.localizedDescription;
}

NSURL* GitWorkspaceIssueURL(NSString* templateURL, NSString* prefix, NSString* message)
{
	if(!templateURL.length || !message.length) return nil;
	NSString* pattern = [NSString stringWithFormat:@"%@([0-9]+)", [NSRegularExpression escapedPatternForString:prefix.length ? prefix : @"#"]];
	NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
	NSTextCheckingResult* match = [regex firstMatchInString:message options:0 range:NSMakeRange(0, message.length)];
	if(!match) return nil;
	NSString* identifier = [message substringWithRange:[match rangeAtIndex:1]];
	NSString* urlText = [templateURL containsString:@"{id}"] ? [templateURL stringByReplacingOccurrencesOfString:@"{id}" withString:identifier]
		: [templateURL stringByAppendingFormat:@"%@%@", [templateURL hasSuffix:@"/"] ? @"" : @"/", identifier];
	NSURL* url = [NSURL URLWithString:urlText];
	return [@[@"http", @"https"] containsObject:url.scheme.lowercaseString ?: @""] && url.host.length ? url : nil;
}

NSDictionary<NSString*, NSDictionary*>* GitWorkspaceBranchPreferences(NSString* root)
{
	NSDictionary* result = GitRepositoryCommand(root, @[@"config", @"--local", @"--null", @"--get-regexp", @"^branch\\..*\\.textmate(pinned|skipautoarchive|hidemergedhint|parent)$"]);
	NSMutableDictionary* entries = [NSMutableDictionary dictionary];
	NSString* nul = [NSString stringWithFormat:@"%C", (unichar)0];
	for(NSString* entry in [GitWorkspaceText(result) componentsSeparatedByString:nul]) {
		NSRange line = [entry rangeOfString:@"\n"];
		if(line.location == NSNotFound) continue;
		NSString* key = [entry substringToIndex:line.location];
		NSRange suffix = [key rangeOfString:@".textmate" options:NSBackwardsSearch];
		if(![key hasPrefix:@"branch."] || suffix.location == NSNotFound || suffix.location <= 7) continue;
		NSString* ref = [@"refs/heads/" stringByAppendingString:[key substringWithRange:NSMakeRange(7, suffix.location-7)]];
		NSMutableDictionary* prefs = entries[ref];
		if(!prefs) entries[ref] = prefs = [NSMutableDictionary dictionary];
		NSString* value = [entry substringFromIndex:NSMaxRange(line)];
		NSString* property = [key substringFromIndex:NSMaxRange(suffix)];
		prefs[property] = [property isEqual:@"parent"] ? value : @([@[@"true", @"yes", @"on", @"1"] containsObject:value.lowercaseString]);
	}
	return entries;
}

NSString* GitWorkspaceSetBranchPreference(NSString* root, NSString* ref, NSString* key, NSString* value)
{
	if(![ref hasPrefix:@"refs/heads/"] || GitWorkspaceError(GitRepositoryCommand(root, @[@"show-ref", @"--verify", @"--quiet", ref]), @"Unknown branch.")) return @"The local branch is no longer available.";
	if(![@[@"pinned", @"skipautoarchive", @"hidemergedhint", @"parent"] containsObject:key]) return @"Unknown branch setting.";
	if([key isEqual:@"parent"] && value.length) {
		if(![value hasPrefix:@"refs/heads/"] && ![value hasPrefix:@"refs/remotes/"]) return @"Choose an existing parent branch.";
		if(GitWorkspaceError(GitRepositoryCommand(root, @[@"show-ref", @"--verify", @"--quiet", value]), @"Unknown branch.")) return @"The parent branch is no longer available.";
		NSDictionary* prefs = GitWorkspaceBranchPreferences(root);
		NSMutableSet* chain = [NSMutableSet setWithObject:ref];
		for(NSString* parent = value; parent.length; parent = prefs[parent][@"parent"]) {
			if([chain containsObject:parent]) return @"This parent would create a cycle between branches.";
			[chain addObject:parent];
		}
	}
	return GitWorkspaceSetConfig(root, [NSString stringWithFormat:@"branch.%@.textmate%@", [ref substringFromIndex:11], key], value);
}

NSArray<NSDictionary*>* GitWorkspaceReviewRefs(NSString* root)
{
	NSDictionary* result = GitRepositoryCommand(root, @[@"for-each-ref", @"--format=%(refname)%09%(objectname)%09%(committerdate:unix)%09%(upstream:short)%09%(upstream:track)%09%(worktreepath)%09%(HEAD)%09%(symref)%09%(upstream)%09%(upstream:remotename)%09%(upstream:remoteref)%09%(authorname)", @"refs/heads/", @"refs/remotes/"]);
	NSDictionary* prefs = GitWorkspaceBranchPreferences(root);
	NSMutableArray* refs = [NSMutableArray array];
	for(NSString* line in [GitWorkspaceText(result) componentsSeparatedByString:@"\n"]) {
		NSArray* fields = [line componentsSeparatedByString:@"\t"];
		if(fields.count < 12 || [fields[7] length]) continue;
		NSString* ref = fields[0];
		BOOL local = [ref hasPrefix:@"refs/heads/"];
		NSString* name = [ref substringFromIndex:local ? 11 : 13];
		[refs addObject:@{ @"ref": ref, @"name": name, @"id": fields[1], @"date": @([fields[2] longLongValue]), @"upstream": fields[3],
			@"trackingError": @([fields[4] isEqual:@"[gone]"]), @"local": @(local), @"archived": @(local && [name hasPrefix:GitWorkspaceArchivePrefix]),
			@"checkedOut": @([fields[5] length] != 0), @"head": @([fields[6] isEqual:@"*"]), @"author": fields[11], @"prefs": prefs[ref] ?: @{},
			@"upstreamRef": fields[8], @"upstreamRemote": fields[9], @"upstreamTarget": fields[10] }];
	}
	return refs;
}

NSString* GitWorkspaceCreateStackedBranch(NSString* root, NSString* name, NSDictionary* parent)
{
	NSString* ref = parent[@"ref"], *tip = parent[@"id"];
	if(!name.length || ![ref hasPrefix:@"refs/heads/"] || !tip.length) return @"Choose a local parent branch and enter a new branch name.";
	NSString* latest = [GitWorkspaceText(GitRepositoryCommand(root, @[@"rev-parse", @"--verify", @"--end-of-options", ref])) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
	if(![latest isEqual:tip]) return @"The parent branch changed. Refresh before creating a stacked branch.";
	if(NSString* error = GitWorkspaceError(GitRepositoryCommand(root, @[@"branch", @"--", name, tip], YES), @"Git could not create the branch.")) return error;
	NSString* branch = [@"refs/heads/" stringByAppendingString:name];
	if(NSString* error = GitWorkspaceSetBranchPreference(root, branch, @"parent", ref)) return [@"Created the branch but could not set its parent. " stringByAppendingString:error];
	return nil;
}

NSString* GitWorkspacePushBranch(NSString* root, NSDictionary* branch, NSString* remote, NSString* destination, BOOL publish, NSString* expectedRemoteTip)
{
	NSString* ref = branch[@"ref"], *tip = branch[@"id"];
	if(![ref hasPrefix:@"refs/heads/"] || !tip.length || !remote.length || ![destination hasPrefix:@"refs/heads/"] || (publish && expectedRemoteTip)) return @"Choose a local branch and a remote branch name.";
	if(NSString* error = GitWorkspaceError(GitRepositoryCommand(root, @[@"check-ref-format", destination]), @"Enter a valid destination branch name.")) return error;
	if(GitWorkspaceError(GitRepositoryCommand(root, @[@"remote", @"get-url", @"--push", @"--", remote]), @"Unknown push remote.")) return @"The selected remote is no longer configured.";
	NSString* latest = [GitWorkspaceText(GitRepositoryCommand(root, @[@"rev-parse", @"--verify", @"--end-of-options", ref])) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
	if(![latest isEqual:tip]) return @"The local branch changed. Refresh and review it before pushing.";
	// Pin publication to the branch name for upstream configuration; all other pushes use the reviewed commit.
	NSMutableArray* args = [@[@"push", @"--porcelain", @"--no-follow-tags"] mutableCopy];
	if(publish) [args addObject:@"--set-upstream"];
	if(expectedRemoteTip) [args addObject:[NSString stringWithFormat:@"--force-with-lease=%@:%@", destination, expectedRemoteTip]];
	[args addObjectsFromArray:@[@"--", remote, [NSString stringWithFormat:@"%@:%@", publish ? ref : tip, destination]]];
	return GitWorkspaceError(GitRepositoryCommand(root, args, YES, 90), @"Git could not push the selected branch.");
}

NSDictionary* GitWorkspaceReviewBranch(NSString* root, NSDictionary* base, NSDictionary* branch)
{
	NSString* left = base[@"id"], *right = branch[@"id"];
	NSString* range = [NSString stringWithFormat:@"%@...%@", left, right];
	NSMutableDictionary* info = [branch mutableCopy];
	NSDictionary* counts = GitRepositoryCommand(root, @[@"rev-list", @"--left-right", @"--count", range, @"--"]);
	NSArray* fields = [GitWorkspaceText(counts) componentsSeparatedByString:@"\t"];
	if(fields.count != 2 || counts[@"error"] || [counts[@"status"] intValue]) { info[@"state"] = @"Unavailable"; return info; }
	info[@"behind"] = @([fields[0] integerValue]);
	info[@"ahead"] = @([fields[1] integerValue]);
	if(![info[@"ahead"] unsignedIntegerValue]) { info[@"state"] = @"Merged"; return info; }
	if(![info[@"behind"] unsignedIntegerValue]) { info[@"state"] = @"Mergeable"; return info; }
	NSDictionary* merge = GitRepositoryCommand(root, @[@"merge-tree", @"--write-tree", @"--name-only", @"--no-messages", @"-z", left, right]);
	if(merge[@"error"] || !merge[@"status"] || [merge[@"status"] intValue] > 1) { info[@"state"] = @"Unavailable"; return info; }
	info[@"state"] = [merge[@"status"] intValue] ? @"Conflicts" : @"Mergeable";
	if([info[@"state"] isEqual:@"Conflicts"]) {
		NSMutableArray* paths = [NSMutableArray array];
		NSArray* output = [GitWorkspaceText(merge) componentsSeparatedByString:[NSString stringWithFormat:@"%C", (unichar)0]];
		for(NSUInteger i = 1; i < output.count && [output[i] length]; ++i) [paths addObject:output[i]];
		info[@"conflicts"] = paths;
	}
	return info;
}

NSString* GitWorkspaceArchiveBranch(NSString* root, NSDictionary* branch, BOOL restore)
{
	NSString* name = branch[@"name"];
	if(![branch[@"local"] boolValue] || !name.length || [name hasPrefix:GitWorkspaceArchivePrefix] != restore) return @"Select a local branch first.";
	NSDictionary* latest = nil;
	for(NSDictionary* ref in GitWorkspaceReviewRefs(root)) if([ref[@"ref"] isEqual:branch[@"ref"]]) { latest = ref; break; }
	if(![latest[@"id"] isEqual:branch[@"id"]]) return @"The branch changed. Refresh before archiving or restoring it.";
	if([latest[@"checkedOut"] boolValue]) return @"Switch away from this branch in its worktree before archiving it.";
	NSString* other = restore ? [name substringFromIndex:GitWorkspaceArchivePrefix.length] : [GitWorkspaceArchivePrefix stringByAppendingString:name];
	if(NSString* error = GitWorkspaceError(GitRepositoryCommand(root, @[@"branch", @"-m", @"--", name, other], YES), @"Git could not move this branch.")) return error;
	if(restore && [GitWorkspaceConfig(root, @"textmate.autoArchiveMergedInto") length])
		return GitWorkspaceSetBranchPreference(root, [@"refs/heads/" stringByAppendingString:other], @"skipautoarchive", @"true");
	return nil;
}

NSString* GitWorkspaceAutoArchiveBranches(NSString* root, NSArray<NSDictionary*>* refs, NSString* baseRef)
{
	if(![baseRef hasPrefix:@"refs/heads/"]) return nil;
	NSDictionary* result = GitRepositoryCommand(root, @[@"for-each-ref", [@"--merged=" stringByAppendingString:baseRef], @"--format=%(refname)", @"refs/heads/"]);
	if(NSString* error = GitWorkspaceError(result, @"Git could not find fully merged branches.")) return error;
	NSSet* merged = [NSSet setWithArray:[GitWorkspaceText(result) componentsSeparatedByString:@"\n"] ?: @[]];
	NSMutableSet* protectedRefs = [NSMutableSet setWithArray:@[baseRef, @"refs/heads/main", @"refs/heads/master", @"refs/heads/develop"]];
	for(NSDictionary* branch in refs) if(NSString* parent = branch[@"prefs"][@"parent"]) [protectedRefs addObject:parent];
	for(NSString* key in @[@"gitflow.branch.master", @"gitflow.branch.develop"]) {
		if(NSString* name = GitWorkspaceConfig(root, key)) [protectedRefs addObject:[@"refs/heads/" stringByAppendingString:name]];
	}
	for(NSDictionary* branch in refs) {
		NSString* ref = branch[@"ref"];
		NSDictionary* prefs = branch[@"prefs"];
		if(![merged containsObject:ref] || [protectedRefs containsObject:ref] || [branch[@"checkedOut"] boolValue] || [branch[@"archived"] boolValue] || [prefs[@"pinned"] boolValue] || [prefs[@"skipautoarchive"] boolValue]) continue;
		if(NSString* error = GitWorkspaceArchiveBranch(root, branch, NO)) return error;
	}
	return nil;
}

NSDictionary* GitWorkspaceComparisonCommits(NSString* root, NSString* range, NSString* tip)
{
	NSString* format = @"--format=%H%x09%P%x09%an%x09%as%x09%s";
	NSDictionary* result = GitRepositoryCommand(root, @[@"log", @"--max-count=200", @"--topo-order", format, range, @"--"]);
	if(NSString* error = GitWorkspaceError(result, @"Git could not read these commits.")) return @{@"error": error};
	NSString* text = GitWorkspaceText(result);
	// For an already merged branch, show the tip so its last change can still be inspected.
	if(!text.length && tip.length) text = GitWorkspaceText(GitRepositoryCommand(root, @[@"log", @"-1", format, tip, @"--"]));
	NSMutableArray* commits = [NSMutableArray array];
	for(NSString* line in [text componentsSeparatedByString:@"\n"]) {
		NSArray* fields = [line componentsSeparatedByString:@"\t"];
		if(fields.count < 5) continue;
		NSString* subject = [[fields subarrayWithRange:NSMakeRange(4, fields.count-4)] componentsJoinedByString:@"\t"];
		[commits addObject:@{@"id": fields[0], @"parents": [fields[1] length] ? [fields[1] componentsSeparatedByString:@" "] : @[], @"author": fields[2], @"date": fields[3], @"subject": subject}];
	}
	return @{@"commits": commits};
}

NSArray<NSDictionary*>* GitWorkspacePullRequestRemotes(NSString* root)
{
	NSMutableArray* remotes = [NSMutableArray array];
	for(NSString* name in [GitWorkspaceText(GitRepositoryCommand(root, @[@"remote"])) componentsSeparatedByString:@"\n"]) {
		if(!name.length) continue;
		NSString* url = [GitWorkspaceText(GitRepositoryCommand(root, @[@"remote", @"get-url", @"--", name])) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
		if(!url.length) continue;
		NSURLComponents* location = [NSURLComponents componentsWithString:url];
		if(!location.host.length) {
			NSRange colon = [url rangeOfString:@":"];
			if(colon.location != NSNotFound && colon.location > 0 && ![[url substringToIndex:colon.location] containsString:@"/"])
				location = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"ssh://%@/%@", [url substringToIndex:colon.location], [url substringFromIndex:NSMaxRange(colon)]]];
		}
		NSString* host = location.host.lowercaseString;
		if([host isEqual:@"ssh.github.com"]) host = @"github.com";
		NSString* configured = GitWorkspaceConfig(root, [NSString stringWithFormat:@"remote.%@.textmateGitHubHost", name]);
		if(configured.length) host = configured.lowercaseString;
		if(![host isEqual:@"github.com"] && !configured.length) continue;
		NSString* path = [location.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
		if([path hasSuffix:@".git"]) path = [path substringToIndex:path.length-4];
		NSArray* parts = [path componentsSeparatedByString:@"/"];
		NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."] invertedSet];
		if(parts.count != 2 || ![parts[0] length] || ![parts[1] length] || !host.length || [host rangeOfCharacterFromSet:invalid].location != NSNotFound || [path rangeOfCharacterFromSet:invalid options:0 range:NSMakeRange(0, [parts[0] length])].location != NSNotFound || [parts[1] rangeOfCharacterFromSet:invalid].location != NSNotFound) continue;
		[remotes addObject:@{@"name": name, @"host": host, @"repo": [NSString stringWithFormat:@"%@/%@", host, path], @"url": [NSString stringWithFormat:@"https://%@/%@", host, path]}];
	}
	return remotes;
}

NSDictionary* GitWorkspacePullRequestCommand(NSString* root, NSDictionary* remote, NSArray<NSString*>* arguments)
{
	if(![remote[@"repo"] length]) return @{@"error": @"Add or select a GitHub remote."};
	std::string path = scm::find_executable("gh", "TM_GH");
	NSString* executable = path.empty() || path == NULL_STR ? nil : @(path.c_str());
	if(!executable) for(NSString* candidate in @[@"/opt/homebrew/bin/gh", @"/usr/local/bin/gh"])
		if([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) { executable = candidate; break; }
	if(!executable) return @{@"error": @"Install GitHub CLI (gh) and sign in with gh auth login to use Pull Requests."};
	return GitWorkspaceCommand(executable, root, [[@[@"pr"] arrayByAddingObjectsFromArray:arguments] arrayByAddingObjectsFromArray:@[@"--repo", remote[@"repo"]]], YES, 45, NO);
}

static NSDictionary* PullRequestJSON(NSString* root, NSDictionary* remote, NSArray* args, Class type)
{
	NSDictionary* result = GitWorkspacePullRequestCommand(root, remote, args);
	if(NSString* error = GitWorkspaceError(result, @"GitHub could not load pull requests.")) return @{@"error": error};
	NSData* data = result[@"data"];
	id value = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
	return [value isKindOfClass:type] ? @{@"value": value} : @{@"error": @"GitHub CLI returned an unreadable response."};
}

NSDictionary* GitWorkspacePullRequestList(NSString* root, NSDictionary* remote, NSString* state)
{
	return PullRequestJSON(root, remote, @[@"list", @"--state", state, @"--limit", @"200", @"--json", @"number,title,state,isDraft,author,headRefName,headRefOid,baseRefName,url"], NSArray.class);
}

NSDictionary* GitWorkspacePullRequestDetails(NSString* root, NSDictionary* remote, NSNumber* number)
{
	return PullRequestJSON(root, remote, @[@"view", number.stringValue, @"--json", @"number,title,state,isDraft,author,headRefName,headRefOid,baseRefName,body,createdAt,comments,reviews,commits,files,url,mergeStateStatus,reviewDecision"], NSDictionary.class);
}
