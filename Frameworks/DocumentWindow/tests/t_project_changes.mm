#import "../src/ProjectChanges.h"
#import "../src/GitRepository.h"
#import "../src/GitWorkspaceData.h"
#import "../src/GitWorkingCopyActions.h"
#import "../src/GitDiffView.h"
#import "../src/GitRevisionView.h"
#include <unistd.h>

static void changes_test_git(NSString* directory, NSArray<NSString*>* arguments)
{
	NSTask* task = [[NSTask alloc] init];
	task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/git"];
	task.arguments = [@[@"-C", directory, @"-c", @"user.name=TextMate Tests", @"-c", @"user.email=tests@example.invalid", @"-c", @"commit.gpgsign=false", @"-c", @"core.hooksPath=/dev/null"] arrayByAddingObjectsFromArray:arguments];
	task.standardInput = [NSFileHandle fileHandleWithNullDevice];
	task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
	task.standardError = [NSFileHandle fileHandleWithNullDevice];
	OAK_ASSERT([task launchAndReturnError:nil]);
	[task waitUntilExit];
	OAK_ASSERT(task.terminationStatus == 0);
}
static void changes_test_write(NSString* directory, NSString* path, NSString* text)
{
	OAK_ASSERT([text writeToFile:[directory stringByAppendingPathComponent:path] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
}
static NSDictionary* changes_test_file(NSDictionary* snapshot, NSString* path)
{
	for(NSDictionary* file in snapshot[@"files"]) if([file[@"path"] isEqual:path]) return file;
	return nil;
}

void test_changeset_aligns_different_statuses_and_expands_all ()
{
	NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	NSFileManager* files = NSFileManager.defaultManager;
	OAK_ASSERT([files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(root, @[@"init", @"-qb", @"main"]);
	changes_test_write(root, @"config.go", @"original\n");
	changes_test_git(root, @[@"add", @"--all"]);
	changes_test_git(root, @[@"commit", @"-qm", @"Base"]);
	changes_test_write(root, @"config.go", @"updated\n");
	changes_test_write(root, @"config_test.go", @"test\nsecond line\n");
	OAK_ASSERT([[NSData dataWithBytes:"\0\1\2" length:3] writeToFile:[root stringByAppendingPathComponent:@"sample.bin"] atomically:YES]);
	changes_test_git(root, @[@"add", @"--all"]);
	changes_test_git(root, @[@"commit", @"-qm", @"Update configuration", @"-m",
		@"Commit messages should wrap at the same width when patches show or hide the scroll bar in the revision details pane."]);
	NSDictionary* commit = [GitRepositoryHistory(root, 1)[@"commits"] firstObject];
	NSDictionary* range = GitRepositoryRangeChanges(root, @"HEAD^..HEAD");
	OAK_ASSERT([range[@"files"] count] == 3 && [range[@"additions"] intValue] == 3 && [range[@"deletions"] intValue] == 1);
	__block NSWindow* window;
	__block GitRevisionView* revision;
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 590, 360) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
		window.releasedWhenClosed = NO;
		window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
		revision = [[GitRevisionView alloc] initWithFrame:window.contentView.bounds];
		window.contentView = revision;
		[revision showRevision:commit repository:root stash:NO];
	});
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
	__block BOOL loaded = NO;
	do {
		dispatch_sync(dispatch_get_main_queue(), ^{ loaded = [[revision valueForKey:@"outline"] numberOfRows] == 4; });
		if(!loaded) [NSThread sleepForTimeInterval:0.01];
	} while(!loaded && deadline.timeIntervalSinceNow > 0);
	OAK_ASSERT(loaded);
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSOutlineView* outline = [revision valueForKey:@"outline"];
		NSScrollView* scroll = outline.enclosingScrollView;
		scroll.scrollerStyle = NSScrollerStyleLegacy;
		[revision layoutSubtreeIfNeeded];
		CGFloat collapsedHeight = NSMaxY([outline rectOfRow:3]);
		CGFloat headerHeight = NSHeight(revision.bounds)-NSHeight(scroll.frame);
		[window setContentSize:NSMakeSize(NSWidth(revision.bounds), headerHeight+collapsedHeight+5)];
		[revision layoutSubtreeIfNeeded];
		id added = [outline itemAtRow:1], modified = [outline itemAtRow:2];
		OAK_ASSERT([[added objectForKey:@"path"] isEqual:@"config_test.go"] && [[modified objectForKey:@"path"] isEqual:@"config.go"]);
		NSStackView* addedRow = (NSStackView*)[outline viewAtColumn:0 row:1 makeIfNecessary:YES];
		NSStackView* modifiedRow = (NSStackView*)[outline viewAtColumn:0 row:2 makeIfNecessary:YES];
		[outline layoutSubtreeIfNeeded];
		NSView* addedPath = addedRow.arrangedSubviews.lastObject;
		NSView* modifiedPath = modifiedRow.arrangedSubviews.lastObject;
		OAK_ASSERT(addedPath && modifiedPath && NSMinX([addedPath convertRect:addedPath.bounds toView:outline]) == NSMinX([modifiedPath convertRect:modifiedPath.bounds toView:outline]));
		OAK_ASSERT([[[revision valueForKey:@"summary"] stringValue] isEqual:@"Showing 3 changed files with 3 additions and 1 deletion"]);
		NSButton* expand = [revision valueForKey:@"expand"];
		NSTextField* message = [revision valueForKey:@"message"];
		[outline rowViewAtRow:0 makeIfNecessary:YES];
		[revision layoutSubtreeIfNeeded];
		CGFloat messageWidth = NSWidth(message.frame);
		CGFloat messageHeight = NSHeight(message.frame);
		OAK_ASSERT(!expand.isBordered && [expand.title isEqual:@"Expand All"]);
		[outline expandItem:added];
		OAK_ASSERT(outline.numberOfRows == 5 && [expand.title isEqual:@"Expand All"]);
		[expand performClick:nil];
		OAK_ASSERT(outline.numberOfRows == 7 && [expand.title isEqual:@"Collapse All"]);
		[revision layoutSubtreeIfNeeded];
		OAK_ASSERT(NSWidth(message.frame) == messageWidth && NSHeight(message.frame) == messageHeight);
		[expand performClick:nil];
		OAK_ASSERT(outline.numberOfRows == 4 && [expand.title isEqual:@"Expand All"]);
		[revision layoutSubtreeIfNeeded];
		OAK_ASSERT(NSWidth(message.frame) == messageWidth && NSHeight(message.frame) == messageHeight);
		[window close];
		window = nil;
		revision = nil;
	});
	OAK_ASSERT([files removeItemAtPath:root error:nil]);
}

void test_large_changeset_keeps_message_spacing_and_scroll_position ()
{
	NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	NSFileManager* files = NSFileManager.defaultManager;
	OAK_ASSERT([files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(root, @[@"init", @"-qb", @"main"]);
	for(NSUInteger index = 0; index < 53; ++index) {
		NSString* path = [NSString stringWithFormat:@"file-%02lu.cpp", (unsigned long)index];
		NSString* content = [@"int value = 1;\n" stringByPaddingToLength:1500 withString:@"int value = 1;\n" startingAtIndex:0];
		if(index == 0) content = [[@"// 中文 " stringByPaddingToLength:370 withString:@"LongIdentifierWithoutSpaces" startingAtIndex:0] stringByAppendingFormat:@"\n%@", content];
		changes_test_write(root, path, content);
	}
	changes_test_git(root, @[@"add", @"--all"]);
	changes_test_git(root, @[@"commit", @"-qm", @"53 changed files", @"-m",
		[@"A long commit description that wraps in the revision pane.\n" stringByPaddingToLength:1600 withString:@"A long commit description that wraps in the revision pane.\n" startingAtIndex:0]]);
	NSDictionary* commit = [GitRepositoryHistory(root, 1)[@"commits"] firstObject];
	__block NSWindow* window;
	__block GitRevisionView* revision;
	dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 365, 640) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
		window.releasedWhenClosed = NO;
		revision = [[GitRevisionView alloc] initWithFrame:window.contentView.bounds];
		window.contentView = revision;
		[revision showRevision:commit repository:root stash:NO completion:^{ dispatch_semaphore_signal(loaded); }];
	});
	OAK_ASSERT(dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0);
	__block CGFloat y, messageHeight, gap;
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSOutlineView* outline = [revision valueForKey:@"outline"];
		NSScrollView* scroll = outline.enclosingScrollView;
		NSButton* expand = [revision valueForKey:@"expand"];
		NSTextField* message = [revision valueForKey:@"message"];
		[revision layoutSubtreeIfNeeded];
		[outline rowViewAtRow:0 makeIfNecessary:YES];
		[revision layoutSubtreeIfNeeded];
		[outline scrollPoint:NSMakePoint(0, NSMaxY([outline rectOfRow:0])-240)];
		[revision layoutSubtreeIfNeeded];
		y = scroll.contentView.bounds.origin.y;
		messageHeight = NSHeight(message.frame);
		gap = NSMinY([expand convertRect:expand.bounds toView:outline])-NSMaxY([message convertRect:message.bounds toView:outline]);
		[expand sendAction:expand.action to:expand.target];
		[revision layoutSubtreeIfNeeded];
		OAK_ASSERT(outline.numberOfRows == 107);
		OAK_ASSERT(NSHeight(message.frame) == messageHeight && scroll.contentView.bounds.origin.y == y);
	});

	// Check again after Git has returned a real patch and the visible row has grown.
	__block BOOL rendered = NO;
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
	do {
		dispatch_sync(dispatch_get_main_queue(), ^{
			[revision layoutSubtreeIfNeeded];
			NSOutlineView* outline = [revision valueForKey:@"outline"];
			NSView* cell = [outline viewAtColumn:0 row:2 makeIfNecessary:NO];
			rendered = [cell.subviews.firstObject isKindOfClass:GitDiffView.class];
		});
		if(!rendered) [NSThread sleepForTimeInterval:0.01];
	} while(!rendered && deadline.timeIntervalSinceNow > 0);
	OAK_ASSERT(rendered);
	__block CGFloat unwrappedHeight;
	__block NSString* originalText;
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSOutlineView* outline = [revision valueForKey:@"outline"];
		NSScrollView* scroll = outline.enclosingScrollView;
		NSButton* expand = [revision valueForKey:@"expand"];
		NSTextField* message = [revision valueForKey:@"message"];
		NSDictionary* offscreenPatch = [outline itemAtRow:106];
		OAK_ASSERT(!offscreenPatch[@"loading"] && !offscreenPatch[@"patch"]);
		OAK_ASSERT(NSHeight(message.frame) == messageHeight && scroll.contentView.bounds.origin.y == y);
		OAK_ASSERT(gap == NSMinY([expand convertRect:expand.bounds toView:outline])-NSMaxY([message convertRect:message.bounds toView:outline]));
		unwrappedHeight = NSHeight([outline rectOfRow:2]);
		originalText = [[[outline viewAtColumn:0 row:2 makeIfNecessary:NO].subviews.firstObject valueForKey:@"textView"] string];
		[expand sendAction:expand.action to:expand.target];
		[revision layoutSubtreeIfNeeded];
		OAK_ASSERT(outline.numberOfRows == 54);
		OAK_ASSERT(NSHeight(message.frame) == messageHeight && scroll.contentView.bounds.origin.y == y);
		OAK_ASSERT(gap == NSMinY([expand convertRect:expand.bounds toView:outline])-NSMaxY([message convertRect:message.bounds toView:outline]));
		revision.softWrap = YES;
		[expand sendAction:expand.action to:expand.target];
	});
	CGFloat (^waitForHeight)(BOOL(^)(CGFloat)) = ^CGFloat(BOOL(^condition)(CGFloat)){
		NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
		do {
			__block CGFloat height = 0;
			dispatch_sync(dispatch_get_main_queue(), ^{
				[revision layoutSubtreeIfNeeded];
				NSOutlineView* outline = [revision valueForKey:@"outline"];
				GitDiffView* diff = (GitDiffView*)[outline viewAtColumn:0 row:2 makeIfNecessary:NO].subviews.firstObject;
				if(![diff isKindOfClass:GitDiffView.class] || diff.softWrap != revision.softWrap) return;
				NSTextView* text = [diff valueForKey:@"textView"];
				OAK_ASSERT([text.string isEqual:originalText]);
				OAK_ASSERT(text.enclosingScrollView.hasHorizontalScroller == !revision.softWrap);
				height = NSHeight([outline rectOfRow:2]);
				if(revision.softWrap && condition(height)) {
					[text.layoutManager ensureLayoutForTextContainer:text.textContainer];
					NSRect used = [text.layoutManager usedRectForTextContainer:text.textContainer];
					OAK_ASSERT(NSWidth(used) <= NSWidth(text.enclosingScrollView.contentView.bounds));
					OAK_ASSERT(NSMaxY(used) <= height);
				}
			});
			if(height && condition(height)) return height;
			[NSThread sleepForTimeInterval:0.01];
		} while(deadline.timeIntervalSinceNow > 0);
		return 0;
	};
	CGFloat narrowHeight = waitForHeight(^BOOL(CGFloat height){ return height > unwrappedHeight; });
	OAK_ASSERT(narrowHeight > unwrappedHeight);
	dispatch_sync(dispatch_get_main_queue(), ^{ [window setContentSize:NSMakeSize(610, 640)]; });
	OAK_ASSERT(waitForHeight(^BOOL(CGFloat height){ return height < narrowHeight && height > unwrappedHeight; }) > 0);
	dispatch_sync(dispatch_get_main_queue(), ^{ revision.softWrap = NO; });
	OAK_ASSERT(waitForHeight(^BOOL(CGFloat height){ return height == unwrappedHeight; }) == unwrappedHeight);
	dispatch_sync(dispatch_get_main_queue(), ^{
		[window close];
		window = nil;
		revision = nil;
	});
	OAK_ASSERT([files removeItemAtPath:root error:nil]);
}

void test_working_copy_stash_and_snapshot_preserve_selection_and_index ()
{
	NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	NSFileManager* files = NSFileManager.defaultManager;
	OAK_ASSERT([files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(root, @[@"init", @"-qb", @"main"]);
	changes_test_git(root, @[@"config", @"user.name", @"TextMate Tests"]);
	changes_test_git(root, @[@"config", @"user.email", @"tests@example.invalid"]);
	for(NSString* path in @[@"partial", @"unrelated", @"deleted"]) changes_test_write(root, path, @"original\n");
	changes_test_write(root, @".gitignore", @"*.ignored\n");
	changes_test_git(root, @[@"add", @"-A"]);
	changes_test_git(root, @[@"commit", @"-qm", @"Base"]);
	for(NSString* path in @[@"partial", @"unrelated"]) changes_test_write(root, path, @"staged\n");
	changes_test_git(root, @[@"add", @"-A"]);
	changes_test_write(root, @"partial", @"unstaged\n");
	OAK_ASSERT([files removeItemAtPath:[root stringByAppendingPathComponent:@"deleted"] error:nil]);
	OAK_ASSERT([files createDirectoryAtPath:[root stringByAppendingPathComponent:@"drafts"] withIntermediateDirectories:NO attributes:nil error:nil]);
	changes_test_write(root, @"drafts/draft.txt", @"draft\n");
	changes_test_write(root, @"drafts/cache.ignored", @"keep on disk\n");
	NSString* (^gitText)(NSArray*) = ^NSString*(NSArray* args){ return GitWorkspaceText(GitRepositoryCommand(root, args)); };
	NSDictionary* snapshot = ProjectChangesSnapshot(root, @{}, YES);
	NSArray* selected = @[changes_test_file(snapshot, @"partial"), changes_test_file(snapshot, @"deleted"), changes_test_file(snapshot, @"drafts/")];
	NSArray* status = @[@"status", @"--porcelain", @"--untracked-files=all"];
	NSString* originalStatus = gitText(status);
	NSString* originalIndex = gitText(@[@"ls-files", @"--stage"]);
	OAK_ASSERT(GitWorkingCopyModify(root, @[selected[0]], GitWorkingCopyUntrack) != nil);
	OAK_ASSERT([gitText(@[@"ls-files", @"--stage"]) isEqual:originalIndex]);
	OAK_ASSERT(!GitWorkingCopyModify(root, selected, GitWorkingCopySnapshot, @"Snapshot"));
	OAK_ASSERT([gitText(status) isEqual:originalStatus] && [gitText(@[@"ls-files", @"--stage"]) isEqual:originalIndex]);
	OAK_ASSERT(!GitWorkingCopyModify(root, selected, GitWorkingCopyStash, @"Stash selected"));
	OAK_ASSERT([gitText(status) isEqual:@"M  unrelated\n"]);
	OAK_ASSERT(GitWorkingCopyPathExists([root stringByAppendingPathComponent:@"drafts/cache.ignored"]));
	NSDictionary* stash = [GitRepositoryStashes(root, 10)[@"commits"] firstObject];
	NSDictionary* details = GitRepositoryStashDetails(root, stash[@"id"]);
	NSSet* paths = [NSSet setWithArray:[details[@"files"] valueForKey:@"path"]];
	OAK_ASSERT(([paths isEqual:[NSSet setWithArray:@[@"partial", @"deleted", @"drafts/draft.txt"]]]));
	OAK_ASSERT([details[@"additions"] intValue] == 2 && [details[@"deletions"] intValue] == 2);
	changes_test_git(root, @[@"config", @"--local", @"diff.guitool", @"stash-test"]);
	changes_test_git(root, @[@"config", @"--local", @"difftool.stash-test.cmd",
		@"test \"$(cat \"$LOCAL/partial\")\" = original && test \"$(cat \"$REMOTE/partial\")\" = unstaged && test ! -e \"$REMOTE/deleted\" && test \"$(cat \"$REMOTE/drafts/draft.txt\")\" = draft && test ! -e \"$REMOTE/unrelated\""]);
	OAK_ASSERT(!GitRepositoryOpenStashDiffTool(root, stash[@"id"]));
	OAK_ASSERT([gitText(status) isEqual:@"M  unrelated\n"]);
	OAK_ASSERT(GitRepositoryApplySavedStash(root, stash, YES, NO) != nil);
	OAK_ASSERT([gitText(status) isEqual:@"M  unrelated\n"]);
	changes_test_git(root, @[@"restore", @"--staged", @"--", @"unrelated"]);
	OAK_ASSERT(!GitRepositoryApplySavedStash(root, stash, YES, NO));
	changes_test_git(root, @[@"add", @"--", @"unrelated"]);
	OAK_ASSERT([gitText(status) isEqual:originalStatus] && [gitText(@[@"ls-files", @"--stage"]) isEqual:originalIndex]);
	OAK_ASSERT([[NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"partial"] encoding:NSUTF8StringEncoding error:nil] isEqual:@"unstaged\n"]);
	OAK_ASSERT([files removeItemAtPath:root error:nil]);
}

void test_working_copy_restores_resolved_conflict_and_uses_literal_excludes ()
{
	NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	NSFileManager* files = NSFileManager.defaultManager;
	OAK_ASSERT([files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(root, @[@"init", @"-qb", @"main"]);
	changes_test_write(root, @"conflict", @"base\n");
	changes_test_git(root, @[@"add", @"conflict"]);
	changes_test_git(root, @[@"commit", @"-qm", @"Base"]);
	changes_test_git(root, @[@"switch", @"-qc", @"other"]);
	changes_test_write(root, @"conflict", @"theirs\n");
	changes_test_git(root, @[@"commit", @"-qam", @"Theirs"]);
	changes_test_git(root, @[@"switch", @"-q", @"main"]);
	changes_test_write(root, @"conflict", @"ours\n");
	changes_test_git(root, @[@"commit", @"-qam", @"Ours"]);
	OAK_ASSERT([GitRepositoryCommand(root, @[@"-c", @"user.name=TextMate Tests", @"-c", @"user.email=tests@example.invalid", @"merge", @"--no-edit", @"other"], YES)[@"status"] intValue] == 1);
	NSArray* conflict = @[changes_test_file(ProjectChangesSnapshot(root, @{}), @"conflict")];
	OAK_ASSERT(!GitWorkingCopyModify(root, conflict, GitWorkingCopyUseTheirs));
	OAK_ASSERT([GitRepositoryCommand(root, @[@"ls-files", @"--unmerged"])[@"data"] length] == 0);
	OAK_ASSERT(!GitWorkingCopyModify(root, conflict, GitWorkingCopyRestoreAncestor));
	OAK_ASSERT([GitRepositoryCommand(root, @[@"ls-files", @"--unmerged"])[@"data"] length] > 0);
	OAK_ASSERT([GitWorkspaceReadFile([root stringByAppendingPathComponent:@"conflict"])[@"text"] isEqual:@"base\n"]);
	NSString* literal = @"[draft]* #.txt";
	changes_test_write(root, literal, @"ignored\n");
	changes_test_write(root, @"d #.txt", @"still untracked\n");
	OAK_ASSERT(!GitWorkingCopyModify(root, @[@{@"path": literal}], GitWorkingCopyExclude));
	NSDictionary* snapshot = ProjectChangesSnapshot(root, @{});
	OAK_ASSERT(!changes_test_file(snapshot, literal) && changes_test_file(snapshot, @"d #.txt"));
	OAK_ASSERT([files removeItemAtPath:root error:nil]);
}

void test_git_workspace_branch_review_and_archive_preserve_revisions ()
{
	NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(root, @[@"init", @"-qb", @"main"]);
	changes_test_write(root, @"README.md", @"original\n");
	changes_test_git(root, @[@"add", @"README.md"]);
	changes_test_git(root, @[@"commit", @"-qm", @"Base"]);
	changes_test_git(root, @[@"branch", @"merged"]);
	changes_test_git(root, @[@"switch", @"-qc", @"topic/demo"]);
	changes_test_write(root, @"README.md", @"topic\n");
	changes_test_git(root, @[@"commit", @"-qam", @"Topic change"]);
	changes_test_git(root, @[@"switch", @"-q", @"main"]);
	changes_test_write(root, @"README.md", @"different main change\n");
	changes_test_git(root, @[@"commit", @"-qam", @"Base change"]);
	NSDictionary* (^ref)(NSString*) = ^NSDictionary*(NSString* name){
		for(NSDictionary* entry in GitWorkspaceReviewRefs(root)) if([entry[@"name"] isEqual:name]) return entry;
		return nil;
	};
	NSDictionary* base = ref(@"main"), *topic = ref(@"topic/demo");
	OAK_ASSERT([GitWorkspaceReviewBranch(root, base, ref(@"merged"))[@"state"] isEqual:@"Merged"]);
	NSDictionary* comparison = GitWorkspaceReviewBranch(root, base, topic);
	OAK_ASSERT([comparison[@"ahead"] intValue] == 1 && [comparison[@"behind"] intValue] == 1);
	NSDictionary* capability = GitRepositoryCommand(root, @[@"merge-tree", @"--write-tree", base[@"id"], base[@"id"]]);
	if(!capability[@"error"] && [capability[@"status"] intValue] == 0) {
		OAK_ASSERT([comparison[@"state"] isEqual:@"Conflicts"] && [comparison[@"conflicts"] containsObject:@"README.md"]);
	}
	OAK_ASSERT(!GitWorkspaceArchiveBranch(root, topic, NO));
	NSDictionary* archive = ref(@"textmate-archive/topic/demo");
	OAK_ASSERT(!ref(@"topic/demo") && [archive[@"id"] isEqual:topic[@"id"]]);
	OAK_ASSERT(!GitWorkspaceArchiveBranch(root, archive, YES) && [ref(@"topic/demo")[@"id"] isEqual:topic[@"id"]]);
	OAK_ASSERT(GitWorkspaceArchiveBranch(root, base, NO) != nil);
	changes_test_git(root, @[@"branch", @"Auto/Move"]);
	changes_test_git(root, @[@"branch", @"Auto/Skip"]);
	OAK_ASSERT(!GitWorkspaceSetBranchPreference(root, ref(@"Auto/Skip")[@"ref"], @"skipautoarchive", @"true"));
	OAK_ASSERT(!GitWorkspaceSetBranchPreference(root, ref(@"merged")[@"ref"], @"pinned", @"true"));
	OAK_ASSERT(!GitWorkspaceCreateStackedBranch(root, @"topic/child", ref(@"topic/demo")));
	NSDictionary* child = ref(@"topic/child");
	OAK_ASSERT([child[@"id"] isEqual:topic[@"id"]] && [child[@"prefs"][@"parent"] isEqual:topic[@"ref"]]);
	OAK_ASSERT(GitWorkspaceSetBranchPreference(root, topic[@"ref"], @"parent", child[@"ref"]) != nil);
	OAK_ASSERT(!GitWorkspaceSetConfig(root, @"textmate.autoArchiveMergedInto", base[@"ref"]));
	OAK_ASSERT(!GitWorkspaceAutoArchiveBranches(root, GitWorkspaceReviewRefs(root), base[@"ref"]));
	OAK_ASSERT(!ref(@"Auto/Move") && ref(@"Auto/Skip") && ref(@"merged") && ref(@"topic/demo"));
	OAK_ASSERT(!GitWorkspaceArchiveBranch(root, ref(@"textmate-archive/Auto/Move"), YES));
	OAK_ASSERT([ref(@"Auto/Move")[@"prefs"][@"skipautoarchive"] boolValue]);
	OAK_ASSERT([ProjectChangesRevision(root)[@"head"] isEqual:base[@"id"]]);
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:root error:nil]);
}

void test_git_workspace_branch_publish_and_force_push_lease_use_reviewed_branch ()
{
	NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(root, @[@"init", @"-qb", @"main"]);
	changes_test_git(root, @[@"commit", @"--allow-empty", @"-qm", @"Original"]);
	changes_test_git(root, @[@"branch", @"Topic/Push"]);
	changes_test_git(root, @[@"commit", @"--allow-empty", @"-qm", @"Other writer"]);
	NSString* remote = [root stringByAppendingPathComponent:@"remote.git"];
	changes_test_git(root, @[@"init", @"-q", @"--bare", remote]);
	changes_test_git(root, @[@"remote", @"add", @"origin", remote]);
	NSString* target = @"refs/heads/Topic/Push";
	NSDictionary* reviewed;
	for(NSDictionary* branch in GitWorkspaceReviewRefs(root)) if([branch[@"ref"] isEqual:target]) { reviewed = branch; break; }
	OAK_ASSERT(reviewed && !GitWorkspacePushBranch(root, reviewed, @"origin", target, YES, nil));
	OAK_ASSERT([GitWorkspaceConfig(root, @"branch.Topic/Push.remote") isEqual:@"origin"] && [GitWorkspaceConfig(root, @"branch.Topic/Push.merge") isEqual:target]);
	changes_test_git(root, @[@"push", @"-q", @"origin", @"main"]);
	NSString* originalTip = reviewed[@"id"], *otherTip = ProjectChangesRevision(root)[@"head"];
	changes_test_git(remote, @[@"update-ref", target, otherTip]);
	OAK_ASSERT(GitWorkspacePushBranch(root, reviewed, @"origin", target, NO, originalTip) != nil);
	OAK_ASSERT([GitWorkspaceText(GitRepositoryCommand(remote, @[@"rev-parse", target])) hasPrefix:otherTip]);
	OAK_ASSERT(!GitWorkspacePushBranch(root, reviewed, @"origin", target, NO, otherTip));
	OAK_ASSERT([GitWorkspaceText(GitRepositoryCommand(remote, @[@"rev-parse", target])) hasPrefix:originalTip]);
	OAK_ASSERT([ProjectChangesRevision(root)[@"head"] isEqual:otherTip]);
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:root error:nil]);
}

void test_git_workspace_hunk_actions_keep_other_chunks ()
{
	NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(root, @[@"init", @"-qb", @"main"]);
	NSMutableArray* lines = [NSMutableArray array];
	for(unsigned i = 1; i < 35; ++i) [lines addObject:[NSString stringWithFormat:@"Line %u", i]];
	NSString* file = @"a file.txt";
	changes_test_write(root, file, [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"]);
	changes_test_git(root, @[@"add", @"--", file]);
	changes_test_git(root, @[@"commit", @"-qm", @"Base"]);
	lines[1] = @"First chunk";
	lines[30] = @"Second chunk";
	changes_test_write(root, file, [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"]);
	NSDictionary* snapshot = ProjectChangesSnapshot(root, @{});
	NSDictionary* change = GitRepositoryChanges(snapshot).firstObject;
	NSArray* hunks = GitDiffHunks(GitRepositoryChangeDiff(snapshot, change, nil)[@"text"]);
	OAK_ASSERT(hunks.count == 2);
	OAK_ASSERT(!GitRepositoryApplyHunk(snapshot, change, hunks[0], GitRepositoryStage));
	NSString* staged = GitWorkspaceText(GitRepositoryCommand(root, @[@"diff", @"--cached"]));
	OAK_ASSERT([staged containsString:@"+First chunk"] && ![staged containsString:@"Second chunk"]);
	OAK_ASSERT(GitRepositoryApplyHunk(snapshot, change, hunks[0], GitRepositoryStage) != nil);
	snapshot = ProjectChangesSnapshot(root, @{});
	NSDictionary* stagedChange = GitRepositoryChanges(snapshot).firstObject;
	NSArray* stagedHunks = GitDiffHunks(GitRepositoryChangeDiff(snapshot, stagedChange, nil)[@"text"]);
	OAK_ASSERT(stagedHunks.count == 1 && !GitRepositoryApplyHunk(snapshot, stagedChange, stagedHunks.firstObject, GitRepositoryUnstage));
	OAK_ASSERT(GitWorkspaceText(GitRepositoryCommand(root, @[@"diff", @"--cached"])).length == 0);
	OAK_ASSERT(!GitRepositoryApplyHunk(snapshot, change, hunks[1], GitRepositoryDiscard));
	NSString* remaining = GitWorkspaceText(GitRepositoryCommand(root, @[@"diff"]));
	OAK_ASSERT([remaining containsString:@"+First chunk"] && ![remaining containsString:@"Second chunk"]);
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:root error:nil]);
}

void test_git_workspace_settings_files_and_pull_request_remotes ()
{
	NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(root, @[@"init", @"-qb", @"main"]);
	NSString* ignore = [root stringByAppendingPathComponent:@".gitignore"];
	NSDictionary* before = GitWorkspaceReadFile(ignore);
	OAK_ASSERT([before[@"data"] length] == 0 && !before[@"error"]);
	OAK_ASSERT(!GitWorkspaceSaveFile(ignore, before[@"data"], @"*.temp\n"));
	OAK_ASSERT(GitWorkspaceSaveFile(ignore, before[@"data"], @"*.cache\n") != nil);
	OAK_ASSERT([GitWorkspaceReadFile(ignore)[@"text"] isEqual:@"*.temp\n"]);
	OAK_ASSERT(!GitWorkspaceSaveFile(GitWorkspacePath(root, @"info/exclude"), GitWorkspaceReadFile(GitWorkspacePath(root, @"info/exclude"))[@"data"], @"private/\n"));
	changes_test_write(root, @"cache.temp", @"Temporary\n");
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:@"private"] withIntermediateDirectories:NO attributes:nil error:nil]);
	changes_test_write(root, @"private/draft.txt", @"Local draft\n");
	NSString* status = GitWorkspaceText(GitRepositoryCommand(root, @[@"status", @"--porcelain", @"--ignored", @"--untracked-files=all"]));
	OAK_ASSERT([status containsString:@"!! cache.temp\n"] && [status containsString:@"!! private/draft.txt\n"]);
	OAK_ASSERT(!GitWorkspaceSetConfig(root, @"commit.template", @"template.txt"));
	changes_test_write(root, @"template.txt", @"Title\n\nWhat changed?\n");
	OAK_ASSERT([GitRepositoryCommitContext(root, nil)[@"template"] containsString:@"What changed?"]);
	changes_test_git(root, @[@"remote", @"add", @"origin", @"git@github.com:example/fixture.git"]);
	changes_test_git(root, @[@"remote", @"add", @"file", @"/tmp/example/fixture"]);
	NSArray* remotes = GitWorkspacePullRequestRemotes(root);
	OAK_ASSERT(remotes.count == 1 && [remotes.firstObject[@"repo"] isEqual:@"github.com/example/fixture"]);
	OAK_ASSERT([GitWorkspaceIssueURL(@"https://example.invalid/issues/{id}", @"TM-", @"Fix TM-42").absoluteString isEqual:@"https://example.invalid/issues/42"]);
	OAK_ASSERT(!GitWorkspaceSetConfig(root, @"user.name", @"Workspace Tests") && !GitWorkspaceSetConfig(root, @"user.email", @"tests@example.invalid"));
	OAK_ASSERT(!GitWorkspaceSetConfig(root, @"commit.gpgsign", @"false") && !GitWorkspaceSetConfig(root, @"core.hooksPath", @"/dev/null"));
	OAK_ASSERT(!GitWorkspaceSetConfig(root, @"textmate.convertGitMoji", @"true"));
	changes_test_git(root, @[@"add", @".gitignore"]);
	OAK_ASSERT(!GitRepositoryCommitChanges(root, @"🐛 Ignore generated files", nil, NO));
	OAK_ASSERT([GitWorkspaceText(GitRepositoryCommand(root, @[@"log", @"-1", @"--format=%s"])) isEqual:@":bug: Ignore generated files\n"]);
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:root error:nil]);
}

void test_project_changes_git_baseline_and_special_files ()
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"TextMate Changes " stringByAppendingString:NSUUID.UUID.UUIDString]];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(directory, @[@"init", @"--quiet"]);
	NSMutableArray* lines = [NSMutableArray array];
	for(int i = 1; i <= 35; ++i) [lines addObject:[NSString stringWithFormat:@"line %d", i]];
	NSString* original = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
	NSString* special = @"--file with spaces 😀\nand newline.txt";
	changes_test_write(directory, @"modified.txt", original);
	changes_test_write(directory, @"deleted.txt", @"removed\n");
	changes_test_write(directory, @"binary.dat", @"original\n");
	changes_test_write(directory, special, @"original 😀\n");
	OAK_ASSERT(symlink("old-target", [directory stringByAppendingPathComponent:@"link"].fileSystemRepresentation) == 0);
	changes_test_git(directory, @[@"add", @"--all"]);
	changes_test_git(directory, @[@"commit", @"--quiet", @"-m", @"Fixture"]);
	lines[1] = @"staged edit";
	changes_test_write(directory, @"modified.txt", [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"]);
	changes_test_git(directory, @[@"add", @"--", @"modified.txt"]);
	lines[30] = @"unstaged edit";
	changes_test_write(directory, @"modified.txt", [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"]);
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:@"deleted.txt"] error:nil]);
	changes_test_write(directory, @"new.txt", @"brand new\n");
	changes_test_write(directory, special, @"updated 😀\n");
	OAK_ASSERT(unlink([directory stringByAppendingPathComponent:@"link"].fileSystemRepresentation) == 0);
	OAK_ASSERT(symlink("new-target", [directory stringByAppendingPathComponent:@"link"].fileSystemRepresentation) == 0);
	char binary[] = {'a', 0, 'b'};
	OAK_ASSERT([[NSData dataWithBytes:binary length:sizeof(binary)] writeToFile:[directory stringByAppendingPathComponent:@"binary.dat"] atomically:YES]);
	NSDictionary* snapshot = ProjectChangesSnapshot(directory, @{});
	OAK_ASSERT(!snapshot[@"error"] && [snapshot[@"files"] count] == 6);
	OAK_ASSERT([snapshot[@"head"] length] == 40);
	NSDictionary* diff = ProjectChangesDiff(snapshot, changes_test_file(snapshot, @"modified.txt"), @{});
	OAK_ASSERT(!diff[@"error"] && [diff[@"hunks"] count] == 2);
	OAK_ASSERT([diff[@"text"] containsString:@"+staged edit"] && [diff[@"text"] containsString:@"+unstaged edit"]);
	OAK_ASSERT([diff[@"added"] integerValue] == 2 && [diff[@"removed"] integerValue] == 2);
	for(NSDictionary* hunk in diff[@"hunks"]) {
		NSUInteger offset = [hunk[@"offset"] unsignedIntegerValue];
		OAK_ASSERT([[diff[@"text"] substringFromIndex:offset] hasPrefix:@"@@"]);
	}
	diff = ProjectChangesDiff(snapshot, changes_test_file(snapshot, @"new.txt"), @{});
	OAK_ASSERT([diff[@"text"] containsString:@"+brand new"]);
	diff = ProjectChangesDiff(snapshot, changes_test_file(snapshot, @"deleted.txt"), @{});
	OAK_ASSERT([diff[@"text"] containsString:@"-removed"] && [diff[@"added"] integerValue] == 0);
	diff = ProjectChangesDiff(snapshot, changes_test_file(snapshot, @"binary.dat"), @{});
	OAK_ASSERT([diff[@"error"] containsString:@"Binary"]);
	diff = ProjectChangesDiff(snapshot, changes_test_file(snapshot, special), @{});
	OAK_ASSERT([diff[@"text"] containsString:@"+updated 😀"]);
	diff = ProjectChangesDiff(snapshot, changes_test_file(snapshot, @"link"), @{});
	OAK_ASSERT([diff[@"text"] containsString:@"+new-target"] && [diff[@"text"] containsString:@"-old-target"]);
	// Repository reads do not change staging or rewrite the working tree.
	NSDictionary* again = ProjectChangesSnapshot(directory, @{});
	OAK_ASSERT([changes_test_file(again, @"modified.txt")[@"flags"] isEqual:@"MM"]);
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
}

void test_project_changes_without_commit_and_outside_repository ()
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
	OAK_ASSERT((ProjectChangesSnapshot(directory, @{})[@"error"] != nil));
	changes_test_git(directory, @[@"init", @"--quiet"]);
	changes_test_write(directory, @"first.txt", @"first change\n");
	NSDictionary* snapshot = ProjectChangesSnapshot(directory, @{});
	OAK_ASSERT(!snapshot[@"error"] && [snapshot[@"head"] length] == 0);
	NSDictionary* diff = ProjectChangesDiff(snapshot, changes_test_file(snapshot, @"first.txt"), @{});
	OAK_ASSERT([diff[@"text"] containsString:@"+first change"]);
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
}

static NSDictionary* source_control_test_change(NSDictionary* snapshot, NSString* path, GitChangeGroup group)
{
	for(NSDictionary* row in GitRepositoryChanges(snapshot))
		if([row[@"path"] isEqual:path] && [row[@"group"] unsignedIntegerValue] == group) return row;
	return nil;
}

void test_source_control_groups_untracked_directories ()
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	NSString* folder = @"source/generated files/";
	NSString* first = [folder stringByAppendingString:@"first.txt"];
	NSString* nested = [folder stringByAppendingString:@"nested/second.txt"];
	NSString* tracked = @"source/keep.txt";
	NSString* loose = @"source/loose.txt";
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:[directory stringByAppendingPathComponent:[nested stringByDeletingLastPathComponent]] withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(directory, @[@"init", @"-q", @"-b", @"main"]);
	changes_test_write(directory, tracked, @"original\n");
	changes_test_git(directory, @[@"add", @"--", tracked]);
	changes_test_git(directory, @[@"commit", @"-qm", @"Initial"]);
	changes_test_write(directory, tracked, @"edited\n");
	changes_test_write(directory, first, @"first\n");
	changes_test_write(directory, nested, @"second\n");
	changes_test_write(directory, loose, @"loose\n");
	NSDictionary* snapshot = ProjectChangesSnapshot(directory, @{}, YES);
	NSDictionary* row = source_control_test_change(snapshot, folder, GitChangeWorking);
	OAK_ASSERT(!snapshot[@"error"] && GitRepositoryChanges(snapshot).count == 3);
	OAK_ASSERT([row[@"directory"] boolValue] && [row[@"code"] isEqual:@"?"] && [row[@"writable"] boolValue]);
	OAK_ASSERT(source_control_test_change(snapshot, tracked, GitChangeWorking) != nil);
	OAK_ASSERT(source_control_test_change(snapshot, loose, GitChangeWorking) != nil);
	OAK_ASSERT(!GitRepositoryChangeDiff(snapshot, row, @{})[@"error"]);
	OAK_ASSERT(changes_test_file(ProjectChangesSnapshot(directory, @{}), nested) != nil);

	NSDictionary* buffers = @{ [directory stringByAppendingPathComponent:nested]: [[ProjectChangesBuffer alloc] init] };
	snapshot = ProjectChangesSnapshot(directory, buffers, YES);
	row = source_control_test_change(snapshot, folder, GitChangeWorking);
	OAK_ASSERT([row[@"unsaved"] boolValue] && ![row[@"writable"] boolValue]);
	OAK_ASSERT(source_control_test_change(snapshot, nested, GitChangeWorking) == nil);

	NSString* error = GitRepositoryPerform(directory, GitRepositoryStage, @[folder]);
	OAK_ASSERT(error == nil);
	snapshot = ProjectChangesSnapshot(directory, @{}, YES);
	OAK_ASSERT(source_control_test_change(snapshot, folder, GitChangeWorking) == nil);
	OAK_ASSERT([source_control_test_change(snapshot, first, GitChangeStaged)[@"code"] isEqual:@"A"]);
	OAK_ASSERT([source_control_test_change(snapshot, nested, GitChangeStaged)[@"code"] isEqual:@"A"]);
	OAK_ASSERT(source_control_test_change(snapshot, loose, GitChangeStaged) == nil);
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
}

void test_source_control_staging_and_commit_uses_the_index ()
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"TextMate Git\n" stringByAppendingString:NSUUID.UUID.UUIDString]];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(directory, @[@"init", @"-q", @"-b", @"main"]);
	changes_test_git(directory, @[@"config", @"user.name", @"TextMate Tests"]);
	changes_test_git(directory, @[@"config", @"user.email", @"tests@example.invalid"]);
	changes_test_git(directory, @[@"config", @"commit.gpgsign", @"false"]);
	changes_test_git(directory, @[@"config", @"core.hooksPath", @"/dev/null"]);
	NSString* literal = @":(glob)*.txt";
	changes_test_write(directory, literal, @"initial\n");
	changes_test_write(directory, @"other.txt", @"untracked\n");
	NSDictionary* emptyHistory = GitRepositoryHistory(directory, 10);
	OAK_ASSERT(!emptyHistory[@"error"] && [emptyHistory[@"commits"] count] == 0);
	NSString* error = GitRepositoryPerform(directory, GitRepositoryStage, @[literal]);
	OAK_ASSERT(error == nil);
	NSDictionary* snapshot = ProjectChangesSnapshot(directory, @{});
	OAK_ASSERT(!snapshot[@"error"] && [snapshot[@"head"] length] == 0);
	OAK_ASSERT(source_control_test_change(snapshot, literal, GitChangeStaged) != nil);
	OAK_ASSERT(source_control_test_change(snapshot, @"other.txt", GitChangeStaged) == nil);
	error = GitRepositoryPerform(directory, GitRepositoryUnstage, @[literal]);
	OAK_ASSERT(error == nil);
	snapshot = ProjectChangesSnapshot(directory, @{});
	OAK_ASSERT(source_control_test_change(snapshot, literal, GitChangeStaged) == nil);
	OAK_ASSERT([source_control_test_change(snapshot, literal, GitChangeWorking)[@"code"] isEqual:@"?"]);
	error = GitRepositoryPerform(directory, GitRepositoryStage, @[literal]);
	OAK_ASSERT(error == nil);
	error = GitRepositoryPerform(directory, GitRepositoryCommit, @[], @"Initial commit\n\nFrom the staged files");
	OAK_ASSERT(error == nil);
	changes_test_write(directory, literal, @"index text\n");
	error = GitRepositoryPerform(directory, GitRepositoryStage, @[literal]);
	OAK_ASSERT(error == nil);
	changes_test_write(directory, literal, @"working text\n");
	snapshot = ProjectChangesSnapshot(directory, @{});
	NSDictionary* staged = source_control_test_change(snapshot, literal, GitChangeStaged);
	NSDictionary* working = source_control_test_change(snapshot, literal, GitChangeWorking);
	OAK_ASSERT(staged != nil && working != nil);
	if(staged && working) {
		NSString* stagedPatch = GitRepositoryChangeDiff(snapshot, staged, @{})[@"text"];
		NSString* workingPatch = GitRepositoryChangeDiff(snapshot, working, @{})[@"text"];
		OAK_ASSERT([stagedPatch containsString:@"-initial"] && [stagedPatch containsString:@"+index text"] && ![stagedPatch containsString:@"working text"]);
		OAK_ASSERT([workingPatch containsString:@"-index text"] && [workingPatch containsString:@"+working text"]);
	}
	error = GitRepositoryPerform(directory, GitRepositoryDiscard, @[literal]);
	OAK_ASSERT(error == nil);
	snapshot = ProjectChangesSnapshot(directory, @{});
	OAK_ASSERT(source_control_test_change(snapshot, literal, GitChangeWorking) == nil);
	OAK_ASSERT(source_control_test_change(snapshot, literal, GitChangeStaged) != nil);
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:literal] error:nil]);
	error = GitRepositoryPerform(directory, GitRepositoryStage, @[literal]);
	OAK_ASSERT(error == nil);
	changes_test_write(directory, literal, @"recreated\n");
	snapshot = ProjectChangesSnapshot(directory, @{});
	OAK_ASSERT([source_control_test_change(snapshot, literal, GitChangeStaged)[@"code"] isEqual:@"D"]);
	OAK_ASSERT([source_control_test_change(snapshot, literal, GitChangeWorking)[@"code"] isEqual:@"?"]);
	error = GitRepositoryPerform(directory, GitRepositoryCreateBranch, @[], @"topic/local");
	OAK_ASSERT(error == nil);
	OAK_ASSERT([ProjectChangesSnapshot(directory, @{})[@"branch"] isEqual:@"topic/local"]);
	OAK_ASSERT([GitRepositoryBranches(directory)[@"branches"] isEqual:(@[@"main", @"topic/local"])]);
	error = GitRepositoryPerform(directory, GitRepositorySwitchBranch, @[], @"main");
	OAK_ASSERT(error == nil);
	OAK_ASSERT([ProjectChangesSnapshot(directory, @{})[@"branch"] isEqual:@"main"]);
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
}

void test_source_control_commit_description_sign_off_and_amend ()
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(directory, @[@"init", @"-q"]);
	changes_test_git(directory, @[@"config", @"user.name", @"Source Control Tests"]);
	changes_test_git(directory, @[@"config", @"user.email", @"source-control@example.invalid"]);
	changes_test_git(directory, @[@"config", @"commit.gpgsign", @"false"]);
	changes_test_git(directory, @[@"config", @"core.hooksPath", @"/dev/null"]);
	NSDictionary* context = GitRepositoryCommitContext(directory, nil);
	OAK_ASSERT([context[@"name"] isEqual:@"Source Control Tests"] && [context[@"email"] isEqual:@"source-control@example.invalid"]);
	OAK_ASSERT(context[@"lastMessage"] == nil);
	changes_test_write(directory, @"file.txt", @"first\n");
	changes_test_git(directory, @[@"add", @"file.txt"]);
	OAK_ASSERT(!GitRepositoryCommitChanges(directory, @"Add file\n\nDetailed description", nil, YES));
	NSString* original = ProjectChangesRevision(directory)[@"head"];
	NSString* message = GitRepositoryCommitContext(directory, original)[@"lastMessage"];
	OAK_ASSERT([message isEqual:@"Add file\n\nDetailed description\n\nSigned-off-by: Source Control Tests <source-control@example.invalid>"]);
	changes_test_write(directory, @"file.txt", @"staged update\n");
	changes_test_git(directory, @[@"add", @"file.txt"]);
	changes_test_write(directory, @"file.txt", @"working update\n");
	OAK_ASSERT(!GitRepositoryCommitChanges(directory, @"", original, NO));
	NSString* amended = ProjectChangesRevision(directory)[@"head"];
	OAK_ASSERT(amended.length && ![amended isEqual:original]);
	OAK_ASSERT([GitRepositoryCommitContext(directory, amended)[@"lastMessage"] isEqual:message]);
	OAK_ASSERT([GitRepositoryHistory(directory, 4)[@"commits"] count] == 1);
	NSDictionary* snapshot = ProjectChangesSnapshot(directory, @{});
	OAK_ASSERT(source_control_test_change(snapshot, @"file.txt", GitChangeStaged) == nil);
	OAK_ASSERT(source_control_test_change(snapshot, @"file.txt", GitChangeWorking) != nil);
	OAK_ASSERT(GitRepositoryCommitChanges(directory, @"Stale draft", original, NO) != nil);
	OAK_ASSERT([ProjectChangesRevision(directory)[@"head"] isEqual:amended]);
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
}

void test_git_graph_merge_lanes_and_commit_file_patches ()
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(directory, @[@"init", @"-q", @"-b", @"main"]);
	NSString* special = @"branch\nfile.txt";
	changes_test_write(directory, @"root.txt", @"start\n");
	changes_test_git(directory, @[@"add", @"--all"]);
	changes_test_git(directory, @[@"commit", @"-qm", @"Initial"]);
	changes_test_git(directory, @[@"switch", @"-qc", @"feature"]);
	changes_test_write(directory, special, @"feature line\n");
	changes_test_git(directory, @[@"add", @"--all"]);
	changes_test_git(directory, @[@"commit", @"-qm", @"Feature\n\nCommit body"]);
	changes_test_git(directory, @[@"switch", @"-q", @"main"]);
	changes_test_write(directory, @"root.txt", @"main line\n");
	changes_test_git(directory, @[@"commit", @"-qam", @"Main work"]);
	changes_test_git(directory, @[@"merge", @"--no-ff", @"-qm", @"Merge feature", @"feature"]);
	changes_test_git(directory, @[@"tag", @"v1"]);
	NSDictionary* page = GitRepositoryHistory(directory, 2);
	OAK_ASSERT(!page[@"error"] && [page[@"commits"] count] == 2 && [page[@"more"] boolValue]);
	NSDictionary* history = GitRepositoryHistory(directory, 10);
	NSArray<NSDictionary*>* commits = history[@"commits"];
	OAK_ASSERT(commits.count == 4 && ![history[@"more"] boolValue]);
	if(commits.count == 4) {
		NSDictionary* merge = commits.firstObject;
		OAK_ASSERT([merge[@"head"] boolValue] && [merge[@"parents"] count] == 2 && [merge[@"refs"] containsString:@"tag: v1"]);
		NSArray<NSDictionary*>* tracks = GitGraphLayout(commits, history[@"primaryCommits"]);
		NSArray* outgoing = tracks.firstObject[@"outgoing"];
		OAK_ASSERT(outgoing.count == 2 && [tracks.firstObject[@"tracks"] integerValue] == 2);
		OAK_ASSERT([outgoing containsObject:(@[@0, @0, @0])]);
		for(NSUInteger index = 0; index < commits.count; ++index) {
			BOOL feature = [commits[index][@"subject"] isEqual:@"Feature"];
			OAK_ASSERT(([tracks[index][@"node"] unsignedIntegerValue] != 0) == feature);
		}
		OAK_ASSERT([tracks.lastObject[@"incoming"] containsObject:(@[@1, @0, @1])]);
		OAK_ASSERT([tracks.lastObject[@"outgoing"] count] == 0);
		NSDictionary* details = GitRepositoryCommitDetails(history[@"root"], merge);
		OAK_ASSERT([details[@"files"] isEqual:(@[@{ @"code": @"A", @"path": special }])]);
		OAK_ASSERT([details[@"additions"] intValue] == 1 && [details[@"deletions"] intValue] == 0);
		OAK_ASSERT([GitRepositoryCommitDiff(history[@"root"], merge, special)[@"text"] containsString:@"+feature line"]);
		OAK_ASSERT([GitRepositoryCommitDiff(history[@"root"], commits.lastObject, @"root.txt")[@"text"] containsString:@"+start"]);
		OAK_ASSERT([GitRepositoryCommitDiff(history[@"root"], merge, nil)[@"text"] containsString:@"+feature line"]);
	}
	changes_test_git(directory, @[@"update-ref", @"refs/remotes/origin/main", @"HEAD"]);
	changes_test_git(directory, @[@"symbolic-ref", @"refs/remotes/origin/HEAD", @"refs/remotes/origin/main"]);
	NSArray* refs = GitRepositoryReferences(directory)[@"refs"];
	OAK_ASSERT([refs containsObject:@"refs/heads/feature"] && [refs containsObject:@"refs/tags/v1"]);
	OAK_ASSERT([refs containsObject:@"refs/remotes/origin/main"] && ![refs containsObject:@"refs/remotes/origin/HEAD"]);
	NSArray* feature = GitRepositoryHistoryForRef(directory, @"refs/heads/feature", 10)[@"commits"];
	OAK_ASSERT(feature.count == 2 && [feature.firstObject[@"subject"] isEqual:@"Feature"]);
	NSArray* matching = GitRepositorySearchHistory(directory, nil, 1, @"commit body", GitHistorySearchMessage)[@"commits"];
	OAK_ASSERT(matching.count == 1 && [matching.firstObject[@"subject"] isEqual:@"Feature"]);
	OAK_ASSERT([GitRepositorySearchHistory(directory, @"refs/heads/feature", 10, @"textmate tests", GitHistorySearchAuthor)[@"commits"] count] == 2);
	OAK_ASSERT([GitRepositorySearchHistory(directory, @"refs/heads/feature", 10, @".*", GitHistorySearchMessage)[@"commits"] count] == 0);
	NSString* featureHash = feature.firstObject[@"id"];
	matching = GitRepositorySearchHistory(directory, @"refs/heads/feature", 10, [featureHash substringToIndex:12], GitHistorySearchHash)[@"commits"];
	OAK_ASSERT(matching.count == 1 && [matching.firstObject[@"id"] isEqual:featureHash]);
	matching = GitRepositorySearchHistory(directory, @"refs/heads/feature", 10, special, GitHistorySearchFile)[@"commits"];
	OAK_ASSERT(matching.count == 1 && [matching.firstObject[@"id"] isEqual:featureHash]);
	changes_test_write(directory, @"root.txt", @"stashed content\n");
	changes_test_write(directory, @"stash-only.txt", @"untracked stash content\n");
	changes_test_git(directory, @[@"stash", @"push", @"-qu", @"-m", @"Preview fixture"]);
	NSArray* stashes = GitRepositoryStashes(directory, 5)[@"commits"];
	OAK_ASSERT(stashes.count == 1 && [stashes.firstObject[@"subject"] containsString:@"Preview fixture"]);
	if(stashes.count) {
		NSString* diff = GitRepositoryStashDiff(directory, stashes.firstObject[@"id"])[@"text"];
		OAK_ASSERT([diff containsString:@"+stashed content"] && [diff containsString:@"+untracked stash content"]);
	}
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
}

void test_git_graph_uses_the_current_tracking_branch_as_the_primary_lane ()
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(directory, @[@"init", @"-qb", @"main"]);
	changes_test_git(directory, @[@"commit", @"--allow-empty", @"-qm", @"Base"]);
	changes_test_git(directory, @[@"commit", @"--allow-empty", @"-qm", @"Main only"]);
	changes_test_git(directory, @[@"switch", @"-qc", @"work", @"HEAD^1"]);
	changes_test_git(directory, @[@"commit", @"--allow-empty", @"-qm", @"Tracked tip"]);
	changes_test_git(directory, @[@"remote", @"add", @"origin", @"."]);
	changes_test_git(directory, @[@"update-ref", @"refs/remotes/origin/work", @"HEAD"]);
	changes_test_git(directory, @[@"branch", @"--set-upstream-to=origin/work"]);
	changes_test_git(directory, @[@"commit", @"--allow-empty", @"-qm", @"Local only"]);
	NSString* local = ProjectChangesRevision(directory)[@"head"];
	OAK_ASSERT([GitRepositoryHistory(directory, 20)[@"primaryCommits"] containsObject:local]);
	changes_test_git(directory, @[@"switch", @"-qc", @"remote-fixture", @"origin/work"]);
	changes_test_git(directory, @[@"commit", @"--allow-empty", @"-qm", @"Remote only"]);
	NSString* remote = ProjectChangesRevision(directory)[@"head"];
	changes_test_git(directory, @[@"update-ref", @"refs/remotes/origin/work", @"HEAD"]);
	changes_test_git(directory, @[@"switch", @"-q", @"work"]);
	changes_test_git(directory, @[@"merge", @"--no-ff", @"-qm", @"Merge upstream as second parent", @"origin/work"]);
	NSDictionary* history = GitRepositoryHistory(directory, 20);
	NSSet* primary = history[@"primaryCommits"];
	OAK_ASSERT([primary containsObject:remote] && ![primary containsObject:local]);
	NSArray* commits = history[@"commits"];
	OAK_ASSERT(commits.count == 6);
	NSArray* tracks = GitGraphLayout(commits, primary);
	for(NSUInteger index = 0; index < commits.count; ++index) {
		NSDictionary* commit = commits[index];
		BOOL onUpstream = [@[@"Remote only", @"Tracked tip", @"Base"] containsObject:commit[@"subject"]];
		OAK_ASSERT(([tracks[index][@"node"] unsignedIntegerValue] == 0) == onUpstream);
	}
	NSDictionary* page = GitRepositoryHistory(directory, 1);
	NSArray* firstPage = GitGraphLayout(page[@"commits"], page[@"primaryCommits"]);
	OAK_ASSERT([firstPage.firstObject[@"node"] isEqual:tracks.firstObject[@"node"]]);
	NSDictionary* scoped = GitRepositoryHistoryForRef(directory, @"refs/heads/main", 20);
	OAK_ASSERT([scoped[@"primaryCommits"] containsObject:[scoped[@"commits"] firstObject][@"id"]]);
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
}

void test_git_workspace_stash_apply_pop_and_delete ()
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(directory, @[@"init", @"-qb", @"main"]);
	changes_test_git(directory, @[@"config", @"user.name", @"TextMate Tests"]);
	changes_test_git(directory, @[@"config", @"user.email", @"tests@example.invalid"]);
	changes_test_write(directory, @"file.txt", @"base\n");
	changes_test_git(directory, @[@"add", @"file.txt"]);
	changes_test_git(directory, @[@"commit", @"-qm", @"Base"]);
	changes_test_write(directory, @"file.txt", @"staged\n");
	changes_test_git(directory, @[@"add", @"file.txt"]);
	changes_test_write(directory, @"file.txt", @"staged\nworking\n");
	changes_test_write(directory, @"untracked.txt", @"new file\n");
	OAK_ASSERT(!GitRepositoryStashChanges(directory, @"Keep both layers", YES));
	NSArray<NSDictionary*>* stashes = GitRepositoryStashes(directory, 5)[@"commits"];
	NSDictionary* clean = ProjectChangesSnapshot(directory, @{});
	OAK_ASSERT(stashes.count == 1 && !clean[@"error"] && [clean[@"files"] count] == 0);
	NSDictionary* stash = stashes.firstObject;
	OAK_ASSERT(!GitRepositoryApplySavedStash(directory, stash, YES, NO));
	NSDictionary* snapshot = ProjectChangesSnapshot(directory, @{});
	OAK_ASSERT([changes_test_file(snapshot, @"file.txt")[@"flags"] isEqual:@"MM"] && [changes_test_file(snapshot, @"untracked.txt")[@"untracked"] boolValue]);
	OAK_ASSERT([GitRepositoryStashes(directory, 5)[@"commits"] count] == 1);
	OAK_ASSERT(!GitRepositoryStashChanges(directory, @"Saved again", YES));
	OAK_ASSERT(GitRepositoryDropSavedStash(directory, stash) != nil);
	stashes = GitRepositoryStashes(directory, 5)[@"commits"];
	OAK_ASSERT(stashes.count == 2);
	OAK_ASSERT(!GitRepositoryApplySavedStash(directory, stashes.firstObject, YES, YES));
	OAK_ASSERT([GitRepositoryStashes(directory, 5)[@"commits"] count] == 1);
	OAK_ASSERT(!GitRepositoryDropSavedStash(directory, stash));
	OAK_ASSERT([GitRepositoryStashes(directory, 5)[@"commits"] count] == 0);
	OAK_ASSERT([changes_test_file(ProjectChangesSnapshot(directory, @{}), @"file.txt")[@"flags"] isEqual:@"MM"]);
	OAK_ASSERT(!GitRepositoryStashChanges(directory, @"Conflict fixture", YES));
	stash = [GitRepositoryStashes(directory, 5)[@"commits"] firstObject];
	changes_test_write(directory, @"file.txt", @"different committed change\n");
	changes_test_git(directory, @[@"commit", @"-qam", @"Conflicting update"]);
	OAK_ASSERT(GitRepositoryApplySavedStash(directory, stash, NO, YES) != nil);
	OAK_ASSERT([[GitRepositoryStashes(directory, 5)[@"commits"] firstObject][@"id"] isEqual:stash[@"id"]]);
	OAK_ASSERT(source_control_test_change(ProjectChangesSnapshot(directory, @{}), @"file.txt", GitChangeConflict));
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
}

void test_source_control_sync_with_a_local_remote ()
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
	NSString* remote = [directory stringByAppendingPathComponent:@"remote.git"];
	NSString* local = [directory stringByAppendingPathComponent:@"local"];
	NSString* peer = [directory stringByAppendingPathComponent:@"peer"];
	changes_test_git(directory, @[@"init", @"-q", @"--bare", @"-b", @"main", remote]);
	changes_test_git(directory, @[@"init", @"-q", @"-b", @"main", local]);
	changes_test_write(local, @"shared.txt", @"base\n");
	changes_test_git(local, @[@"add", @"--all"]);
	changes_test_git(local, @[@"commit", @"-qm", @"Base"]);
	changes_test_git(local, @[@"config", @"push.default", @"simple"]);
	changes_test_git(local, @[@"remote", @"add", @"origin", remote]);
	changes_test_git(local, @[@"push", @"-qu", @"origin", @"main"]);
	changes_test_git(directory, @[@"clone", @"-q", remote, peer]);
	changes_test_write(peer, @"shared.txt", @"peer\n");
	changes_test_git(peer, @[@"commit", @"-qam", @"Peer update"]);
	changes_test_git(peer, @[@"push", @"-q", @"origin", @"main"]);
	NSString* error = GitRepositoryPerform(local, GitRepositoryFetch, @[]);
	OAK_ASSERT(error == nil);
	OAK_ASSERT([ProjectChangesSnapshot(local, @{})[@"tracking"] containsString:@"behind 1"]);
	error = GitRepositoryPerform(local, GitRepositoryPull, @[]);
	OAK_ASSERT(error == nil);
	OAK_ASSERT([ProjectChangesSnapshot(local, @{})[@"head"] isEqual:ProjectChangesSnapshot(peer, @{})[@"head"]]);
	changes_test_write(local, @"shared.txt", @"local\n");
	changes_test_git(local, @[@"commit", @"-qam", @"Local update"]);
	error = GitRepositoryPerform(local, GitRepositoryPush, @[]);
	OAK_ASSERT(error == nil);
	changes_test_git(peer, @[@"pull", @"-q", @"--ff-only"]);
	OAK_ASSERT([ProjectChangesSnapshot(local, @{})[@"head"] isEqual:ProjectChangesSnapshot(peer, @{})[@"head"]]);
	changes_test_git(peer, @[@"switch", @"-qc", @"topic/ui"]);
	changes_test_write(peer, @"shared.txt", @"topic branch\n");
	changes_test_git(peer, @[@"commit", @"-qam", @"Topic update"]);
	changes_test_git(peer, @[@"push", @"-qu", @"origin", @"topic/ui"]);
	OAK_ASSERT(!GitRepositoryPerform(local, GitRepositoryFetch, @[]));
	OAK_ASSERT(!GitRepositoryCreateTrackingBranch(local, @"topic/ui", @"refs/remotes/origin/topic/ui"));
	NSDictionary* checkedOut = ProjectChangesSnapshot(local, @{});
	OAK_ASSERT([checkedOut[@"branch"] isEqual:@"topic/ui"] && [checkedOut[@"tracking"] isEqual:@"origin/topic/ui"]);
	OAK_ASSERT([checkedOut[@"head"] isEqual:ProjectChangesSnapshot(peer, @{})[@"head"]]);
	NSDictionary* context = GitRepositoryToolbarContext(local, @"topic/ui");
	OAK_ASSERT([context[@"remote"] isEqual:@"origin"] && [context[@"branch"] isEqual:@"topic/ui"]);
	changes_test_write(peer, @"shared.txt", @"remote update\n");
	changes_test_git(peer, @[@"commit", @"-qam", @"Remote update"]);
	changes_test_git(peer, @[@"push", @"-q"]);
	changes_test_git(peer, @[@"push", @"-q", @"origin", @"HEAD:refs/heads/obsolete"]);
	changes_test_git(local, @[@"fetch", @"-q", @"origin"]);
	changes_test_git(peer, @[@"push", @"-q", @"origin", @"--delete", @"obsolete"]);
	changes_test_git(peer, @[@"switch", @"-qc", @"tag-only"]);
	changes_test_git(peer, @[@"commit", @"--allow-empty", @"-qm", @"Tag outside the selected branch"]);
	changes_test_git(peer, @[@"tag", @"v-pull-options"]);
	changes_test_git(peer, @[@"push", @"-q", @"origin", @"v-pull-options"]);
	changes_test_git(peer, @[@"switch", @"-q", @"topic/ui"]);
	OAK_ASSERT(!GitRepositoryRemoteAction(local, GitRepositoryPull, @"origin", @"topic/ui", @"ff", @"topic/ui",
		(GitPullOptions)(GitPullPrune | GitPullFetchSubmodules | GitPullFetchTags)));
	OAK_ASSERT([ProjectChangesSnapshot(local, @{})[@"head"] isEqual:ProjectChangesSnapshot(peer, @{})[@"head"]]);
	OAK_ASSERT([GitRepositoryCommand(local, @[@"show-ref", @"--verify", @"--quiet", @"refs/remotes/origin/obsolete"])[@"status"] intValue] == 1);
	OAK_ASSERT([GitRepositoryCommand(local, @[@"show-ref", @"--verify", @"--quiet", @"refs/tags/v-pull-options"])[@"status"] intValue] == 0);
	changes_test_git(peer, @[@"tag", @"v-fetch-options", @"tag-only"]);
	changes_test_git(peer, @[@"push", @"-q", @"origin", @"v-fetch-options"]);
	NSString* beforeFetch = ProjectChangesRevision(local)[@"head"];
	OAK_ASSERT(!GitRepositoryRemoteAction(local, GitRepositoryFetch, nil, nil, nil, nil, GitPullFetchTags));
	OAK_ASSERT([GitRepositoryCommand(local, @[@"show-ref", @"--verify", @"--quiet", @"refs/tags/v-fetch-options"])[@"status"] intValue] == 0);
	OAK_ASSERT([ProjectChangesRevision(local)[@"head"] isEqual:beforeFetch]);
	OAK_ASSERT(!GitRepositoryRemoteAction(local, GitRepositorySync, @"origin", @"topic/ui", @"ff"));
	OAK_ASSERT([ProjectChangesSnapshot(local, @{})[@"head"] isEqual:ProjectChangesSnapshot(peer, @{})[@"head"]]);
	changes_test_write(local, @"shared.txt", @"local update\n");
	changes_test_git(local, @[@"commit", @"-qam", @"Local update"]);
	changes_test_git(local, @[@"tag", @"v-push-options"]);
	OAK_ASSERT(!GitRepositoryRemoteAction(local, GitRepositorySync, @"origin", @"topic/ui", @"ff", nil, (GitPullOptions)0, GitPushTags));
	OAK_ASSERT([GitRepositoryCommand(remote, @[@"show-ref", @"--verify", @"--quiet", @"refs/tags/v-push-options"])[@"status"] intValue] == 0);
	changes_test_git(peer, @[@"pull", @"-q", @"--ff-only"]);
	OAK_ASSERT([ProjectChangesSnapshot(local, @{})[@"head"] isEqual:ProjectChangesSnapshot(peer, @{})[@"head"]]);
	changes_test_write(local, @"shared.txt", @"local conflict\n");
	changes_test_git(local, @[@"commit", @"-qam", @"Local conflict"]);
	changes_test_write(peer, @"shared.txt", @"remote conflict\n");
	changes_test_git(peer, @[@"commit", @"-qam", @"Remote conflict"]);
	changes_test_git(peer, @[@"push", @"-q"]);
	OAK_ASSERT(GitRepositoryRemoteAction(local, GitRepositorySync, @"origin", @"topic/ui", @"merge") != nil);
	OAK_ASSERT([GitRepositoryToolbarContext(local, @"topic/ui")[@"integration"] isEqual:@"merge"]);
	changes_test_git(peer, @[@"fetch", @"-q", @"origin"]);
	NSArray* remoteHistory = GitRepositoryHistoryForRef(peer, @"refs/remotes/origin/topic/ui", 1)[@"commits"];
	OAK_ASSERT([remoteHistory.firstObject[@"id"] isEqual:ProjectChangesRevision(peer)[@"head"]]);
	OAK_ASSERT(!GitRepositoryFinishIntegration(local, @"merge", YES));
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
}

void test_git_toolbar_merge_and_rebase_conflict_recovery ()
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
	changes_test_git(directory, @[@"init", @"-qb", @"main"]);
	changes_test_git(directory, @[@"config", @"user.name", @"TextMate Tests"]);
	changes_test_git(directory, @[@"config", @"user.email", @"tests@example.invalid"]);
	changes_test_git(directory, @[@"config", @"commit.gpgsign", @"false"]);
	changes_test_write(directory, @"file.txt", @"base\n");
	changes_test_git(directory, @[@"add", @"file.txt"]);
	changes_test_git(directory, @[@"commit", @"-qm", @"Base"]);
	changes_test_git(directory, @[@"switch", @"-qc", @"topic"]);
	changes_test_write(directory, @"file.txt", @"topic\n");
	changes_test_git(directory, @[@"commit", @"-qam", @"Topic"]);
	changes_test_git(directory, @[@"switch", @"-q", @"main"]);
	changes_test_write(directory, @"file.txt", @"main\n");
	changes_test_git(directory, @[@"commit", @"-qam", @"Main"]);
	NSString* head = ProjectChangesRevision(directory)[@"head"];
	OAK_ASSERT(GitRepositoryIntegrate(directory, GitRepositoryMerge, @"refs/heads/topic") != nil);
	OAK_ASSERT([GitRepositoryToolbarContext(directory, @"main")[@"integration"] isEqual:@"merge"]);
	OAK_ASSERT(!GitRepositoryFinishIntegration(directory, @"merge", YES));
	OAK_ASSERT([ProjectChangesRevision(directory)[@"head"] isEqual:head]);
	OAK_ASSERT(GitRepositoryIntegrate(directory, GitRepositoryRebase, @"refs/heads/topic") != nil);
	OAK_ASSERT([GitRepositoryToolbarContext(directory, @"Detached HEAD")[@"integration"] isEqual:@"rebase"]);
	changes_test_write(directory, @"file.txt", @"resolved\n");
	changes_test_git(directory, @[@"add", @"file.txt"]);
	OAK_ASSERT(!GitRepositoryFinishIntegration(directory, @"rebase", NO));
	NSArray* commits = GitRepositoryHistoryForRef(directory, @"refs/heads/main", 10)[@"commits"];
	OAK_ASSERT(commits.count == 3 && [commits.firstObject[@"subject"] isEqual:@"Main"] && [commits[1][@"subject"] isEqual:@"Topic"]);
	changes_test_git(directory, @[@"switch", @"-qc", @"review"]);
	changes_test_write(directory, @"file.txt", @"changes to review\n");
	changes_test_git(directory, @[@"commit", @"-qam", @"Review"]);
	changes_test_git(directory, @[@"switch", @"-q", @"main"]);
	head = ProjectChangesRevision(directory)[@"head"];
	OAK_ASSERT(!GitRepositoryIntegrate(directory, GitRepositoryMerge, @"refs/heads/review", GitMergeNoCommit));
	OAK_ASSERT([ProjectChangesRevision(directory)[@"head"] isEqual:head]);
	OAK_ASSERT([GitRepositoryToolbarContext(directory, @"main")[@"integration"] isEqual:@"merge"]);
	OAK_ASSERT(source_control_test_change(ProjectChangesSnapshot(directory, @{}), @"file.txt", GitChangeStaged) != nil);
	OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
}
