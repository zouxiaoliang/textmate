#import <Foundation/Foundation.h>
#import "../src/LSPSemanticTokens.h"
#include <cstdio>

static bool check (bool condition, char const* message)
{
	if(!condition)
		fprintf(stderr, "%s\n", message);
	return condition;
}

int main ()
{
	@autoreleasepool
	{
		ng::buffer_t buffer;
		buffer.insert(0, "a😀b\nlet name");
		NSArray* types = @[ @"function", @"variable", @"unknown" ];
		NSArray* modifiers = @[ @"declaration", @"readonly" ];
		// First token is the emoji (UTF-16 columns 1..3); next token starts
		// on line 1. The last token is unsupported and should be ignored.
		NSArray* data = @[ @0, @1, @2, @0, @0,
			@1, @4, @4, @1, @2,
			@0, @1, @2, @2, @0 ];
		auto ranges = lsp::decode_semantic_tokens(data, types, modifiers, buffer);
		bool valid = check(ranges.size() == 2, "expected two semantic ranges");
		if(ranges.size() == 2)
		{
			valid &= check(ranges[0].from == 1 && ranges[0].to == 5 && ranges[0].scope == "entity.name.function", "UTF-16 emoji position was not converted to UTF-8");
			valid &= check(ranges[1].from == 11 && ranges[1].to == 15 && ranges[1].scope == "constant.other", "relative line or readonly modifier was decoded incorrectly");
		}
		valid &= check(lsp::decode_semantic_tokens(@[ @0, @1 ], types, modifiers, buffer).empty(), "partial token was accepted");
		valid &= check(lsp::decode_semantic_tokens(@[ @0, @2, @1, @0, @0 ], types, modifiers, buffer).empty(), "split surrogate pair was accepted");
		valid &= check(lsp::decode_semantic_tokens(@[ @9, @0, @1, @0, @0 ], types, modifiers, buffer).empty(), "out-of-bounds line was accepted");
		return valid ? 0 : 1;
	}
}
