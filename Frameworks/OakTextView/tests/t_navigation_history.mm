#import <Foundation/Foundation.h>
#import <ns/ns.h>
#import <test/jail.h>
#import "../src/OakNavigationHistory.h"

// The history records the *origin* of every jump. These tests simulate real
// navigation sequences: standing at X, jumping (recordLocationForDocument:X),
// arriving at Y, and later rewinding with goBack/goForward.

static OakDocument* DocumentAtPath (test::jail_t& jail, char const* name)
{
	// +documentWithPath: requires the file to exist; the class-method helpers
	// (documentWithIdentifier: returns nil for unknown ids) are not usable here.
	jail.set_content(name, "");
	OakDocument* doc = [OakDocument documentWithPath:to_ns(jail.path(name))];
	OAK_ASSERT(doc.path != nil);
	return doc;
}

static text::range_t RangeAt (size_t line, size_t column)
{
	return text::range_t(text::pos_t(line, column));
}

void test_go_back_returns_jump_origin ()
{
	test::jail_t jail;
	OakNavigationHistory* history = [OakNavigationHistory new];
	OakDocument* a = DocumentAtPath(jail, "a.txt");
	OakDocument* b = DocumentAtPath(jail, "b.txt");

	// Standing in a(1,0), a "go to definition" jumps to b(5,2).
	[history recordLocationForDocument:a selection:RangeAt(1, 0)];

	__block NSString* jumpedTo = nil;
	__block text::range_t jumpedSel;
	BOOL moved = [history goBackFromDocument:b selection:RangeAt(5, 2) jump:^(NSString* path, text::range_t selection){
		jumpedTo = path;
		jumpedSel = selection;
	}];
	OAK_ASSERT_EQ(moved, YES);
	OAK_ASSERT([jumpedTo isEqualToString:a.path]);
	OAK_ASSERT(jumpedSel == RangeAt(1, 0));
	OAK_ASSERT_EQ(history.canGoForward, YES);
	OAK_ASSERT_EQ(history.canGoBack, NO);
}

void test_go_back_then_forward_roundtrip ()
{
	test::jail_t jail;
	OakNavigationHistory* history = [OakNavigationHistory new];
	OakDocument* a = DocumentAtPath(jail, "a.txt");
	OakDocument* b = DocumentAtPath(jail, "b.txt");

	[history recordLocationForDocument:a selection:RangeAt(1, 0)];

	__block NSString* jumpedTo = nil;
	[history goBackFromDocument:b selection:RangeAt(5, 2) jump:^(NSString* path, text::range_t selection){ jumpedTo = path; }];
	OAK_ASSERT([jumpedTo isEqualToString:a.path]);

	jumpedTo = nil;
	BOOL moved = [history goForwardFromDocument:a selection:RangeAt(1, 0) jump:^(NSString* path, text::range_t selection){ jumpedTo = path; }];
	OAK_ASSERT_EQ(moved, YES);
	OAK_ASSERT([jumpedTo isEqualToString:b.path]);
	OAK_ASSERT_EQ(history.canGoBack, YES);
	OAK_ASSERT_EQ(history.canGoForward, NO);
}

void test_new_jump_drops_forward_stack ()
{
	test::jail_t jail;
	OakNavigationHistory* history = [OakNavigationHistory new];
	OakDocument* a = DocumentAtPath(jail, "a.txt");
	OakDocument* b = DocumentAtPath(jail, "b.txt");

	[history recordLocationForDocument:a selection:RangeAt(1, 0)];
	[history goBackFromDocument:b selection:RangeAt(5, 2) jump:^(NSString* path, text::range_t selection){ }];
	OAK_ASSERT_EQ(history.canGoForward, YES);

	// From the rewound position a new jump takes place (from a, a different
	// selection). The forward stack must not survive.
	[history recordLocationForDocument:a selection:RangeAt(2, 0)];
	OAK_ASSERT_EQ(history.canGoForward, NO);
	OAK_ASSERT_EQ(history.canGoBack, YES);

	__block NSString* jumpedTo = nil;
	__block text::range_t jumpedSel;
	[history goBackFromDocument:a selection:RangeAt(2, 0) jump:^(NSString* path, text::range_t selection){ jumpedTo = path; jumpedSel = selection; }];
	OAK_ASSERT([jumpedTo isEqualToString:a.path]);
	OAK_ASSERT(jumpedSel == RangeAt(2, 0)); // The origin recorded by the new jump.
}

void test_repeated_record_of_same_location_stacks_once ()
{
	test::jail_t jail;
	OakNavigationHistory* history = [OakNavigationHistory new];
	OakDocument* a = DocumentAtPath(jail, "a.txt");

	// Two identical jumps to a(1,0) (e.g. clicking the same reference twice)
	// must leave a single entry.
	[history recordLocationForDocument:a selection:RangeAt(1, 0)];
	[history recordLocationForDocument:a selection:RangeAt(1, 0)];

	__block int jumps = 0;
	[history goBackFromDocument:a selection:RangeAt(1, 0) jump:^(NSString* path, text::range_t selection){ ++jumps; }];
	OAK_ASSERT_EQ(jumps, 1);
	BOOL moved = [history goBackFromDocument:a selection:RangeAt(1, 0) jump:^(NSString* path, text::range_t selection){ ++jumps; }];
	OAK_ASSERT_EQ(moved, NO);
	OAK_ASSERT_EQ(jumps, 1); // Only one entry was stacked, so nothing more to pop.
}

void test_go_back_on_empty_stack_is_rejected ()
{
	test::jail_t jail;
	OakNavigationHistory* history = [OakNavigationHistory new];
	OakDocument* a = DocumentAtPath(jail, "a.txt");

	__block BOOL jumpCalled = NO;
	BOOL moved = [history goBackFromDocument:a selection:RangeAt(1, 0) jump:^(NSString* path, text::range_t selection){ jumpCalled = YES; }];
	OAK_ASSERT_EQ(moved, NO);
	OAK_ASSERT_EQ(jumpCalled, NO);
}

void test_untitled_documents_are_not_recorded ()
{
	test::jail_t jail;
	OakNavigationHistory* history = [OakNavigationHistory new];
	OakDocument* untitled = [OakDocument documentWithString:@"untitled" fileType:@"text" customName:nil]; // No path.
	OakDocument* a = DocumentAtPath(jail, "a.txt");
	OAK_ASSERT(untitled.path == nil);

	[history recordLocationForDocument:untitled selection:RangeAt(1, 0)];
	[history recordLocationForDocument:a selection:RangeAt(2, 0)];

	__block NSString* jumpedTo = nil;
	BOOL moved = [history goBackFromDocument:a selection:RangeAt(2, 0) jump:^(NSString* path, text::range_t selection){ jumpedTo = path; }];
	OAK_ASSERT_EQ(moved, YES);
	OAK_ASSERT([jumpedTo isEqualToString:a.path]); // Only the titled document made it onto the stack.
	OAK_ASSERT_EQ(history.canGoBack, NO);
}

void test_go_back_walks_the_whole_chain ()
{
	test::jail_t jail;
	OakNavigationHistory* history = [OakNavigationHistory new];
	OakDocument* a = DocumentAtPath(jail, "a.txt");
	OakDocument* b = DocumentAtPath(jail, "b.txt");

	// a → b → (same file, further down): two jumps, two origins.
	[history recordLocationForDocument:a selection:RangeAt(1, 0)];
	[history recordLocationForDocument:b selection:RangeAt(10, 0)];

	__block NSString* jumpedTo = nil;
	[history goBackFromDocument:b selection:RangeAt(20, 0) jump:^(NSString* path, text::range_t selection){ jumpedTo = path; }];
	OAK_ASSERT([jumpedTo isEqualToString:b.path]);
	[history goBackFromDocument:b selection:RangeAt(10, 0) jump:^(NSString* path, text::range_t selection){ jumpedTo = path; }];
	OAK_ASSERT([jumpedTo isEqualToString:a.path]);
	OAK_ASSERT_EQ(history.canGoBack, NO);
}
