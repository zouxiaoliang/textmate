#ifndef LSP_SEMANTIC_TOKENS_H_4WQ9XK
#define LSP_SEMANTIC_TOKENS_H_4WQ9XK

#import <Foundation/Foundation.h>
#include <buffer/buffer.h>

namespace lsp
{
	std::vector<ng::buffer_t::semantic_range_t> decode_semantic_tokens (NSArray* data, NSArray<NSString*>* types, NSArray<NSString*>* modifiers, ng::buffer_t const& buffer);
}

#endif
