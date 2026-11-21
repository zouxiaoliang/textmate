#import "OakTextView_Private.h"
#import <lsp/LSPManager.h>
#import <settings/settings.h>
#import <text/utf16.h>

@implementation OakTextView (InlayHints)

- (void)invalidateInlayHintRequest
{
	[_inlayHintTimer invalidate];
	_inlayHintTimer = nil;
	if(_inlayHintCancellation)
		_inlayHintCancellation();
	_inlayHintCancellation = nil;
	++_inlayHintGeneration;
	_inlayHintRequestedLines = NSMakeRange(NSNotFound, 0);
}

- (void)clearInlayHints
{
	[self invalidateInlayHintRequest];
	if(documentView)
	{
		documentView->set_inlay_hints({});
		[self reflectDocumentSize];
		[self setNeedsDisplay:YES];
	}
}

- (void)refreshInlayHints:(NSNotification*)notification
{
	if(notification.object != self.document)
		return;
	// Keep the current hints visible while fetching their replacements.
	[self invalidateInlayHintRequest];
	[self scheduleInlayHints];
}

- (void)scheduleInlayHints
{
	[_inlayHintTimer invalidate];
	_inlayHintTimer = nil;
	if(!documentView || !self.window || !self.document.path)
		return;

	OakDocument* doc = self.document;
	settings_t const settings = settings_for_path(to_s(doc.virtualPath ?: doc.path), to_s(doc.fileType), to_s(doc.directory ?: [doc.path stringByDeletingLastPathComponent]));
	if(!settings.get("lspInlayHints", true))
	{
		[self clearInlayHints];
		return;
	}

	__weak OakTextView* weakSelf = self;
	_inlayHintTimer = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:NO block:^(NSTimer*) {
		OakTextView* view = weakSelf;
		if(!view || !view->documentView || view.document != doc)
			return;
		view->_inlayHintTimer = nil;
		if(![[LSPManager sharedManager] serverSupportsInlayHintsForDocument:doc])
			return;

		NSRect visible = view.visibleRect;
		size_t top = view->documentView->index_at_point(CGPointMake(NSMinX(visible), NSMinY(visible))).index;
		size_t bottom = view->documentView->index_at_point(CGPointMake(NSMinX(visible), NSMaxY(visible))).index;
		size_t startLine = view->documentView->convert(std::min(top, view->documentView->size())).line;
		size_t endLine = view->documentView->convert(std::min(bottom, view->documentView->size())).line;
		startLine = startLine > 10 ? startLine - 10 : 0;
		endLine = std::min(endLine + 10, view->documentView->lines() - 1);
		NSRange lines = NSMakeRange(startLine, endLine - startLine + 1);
		if(NSEqualRanges(lines, view->_inlayHintRequestedLines))
			return;

		if(view->_inlayHintCancellation)
			view->_inlayHintCancellation();
		view->_inlayHintCancellation = nil;
		NSUInteger generation = ++view->_inlayHintGeneration;
		view->_inlayHintRequestedLines = lines;
		size_t revision = view->documentView->revision();
		size_t last = view->documentView->eol(endLine);
		std::string endText = view->documentView->substr(view->documentView->begin(endLine), last);
		NSUInteger endCharacter = utf16::distance(endText.data(), endText.data() + endText.size());
		NSString* uri = [NSURL fileURLWithPath:doc.path].absoluteString;
		NSDictionary* params = @{
			@"textDocument": @{ @"uri": uri },
			@"range": @{
				@"start": @{ @"line": @(startLine), @"character": @0 },
				@"end": @{ @"line": @(endLine), @"character": @(endCharacter) }
			}
		};
		BOOL parameterNames = settings.get("lspInlayHintsParameterNames", true);
		view->_inlayHintCancellation = [[LSPManager sharedManager] requestLanguageQuery:@"textDocument/inlayHint" forDocument:doc params:params completion:^(id result, NSString* errorCode) {
			OakTextView* target = weakSelf;
			if(!target || !target->documentView || target.document != doc || target->_inlayHintGeneration != generation || target->documentView->revision() != revision)
				return;
			target->_inlayHintCancellation = nil;
			if(errorCode || ![result isKindOfClass:[NSArray class]])
			{
				target->_inlayHintRequestedLines = NSMakeRange(NSNotFound, 0);
				return;
			}

			std::map<size_t, std::string> hints = target->documentView->inlay_hints();
			hints.erase(hints.lower_bound(target->documentView->begin(startLine)),
			            hints.upper_bound(target->documentView->eol(endLine)));
			for(id item in (NSArray*)result)
			{
				if(![item isKindOfClass:[NSDictionary class]]) continue;
				NSDictionary* hint = item;
				NSDictionary* position = hint[@"position"];
				if(![position isKindOfClass:[NSDictionary class]]) continue;
				NSNumber* lineValue = position[@"line"];
				NSNumber* characterValue = position[@"character"];
				if(![lineValue isKindOfClass:[NSNumber class]] || ![characterValue isKindOfClass:[NSNumber class]]) continue;
				NSInteger line = lineValue.integerValue;
				NSInteger character = characterValue.integerValue;
				if(line < (NSInteger)startLine || line > (NSInteger)endLine || character < 0) continue;
				if(!parameterNames && [hint[@"kind"] integerValue] == 2) continue;

				NSString* label = [hint[@"label"] isKindOfClass:[NSString class]] ? hint[@"label"] : nil;
				if(!label && [hint[@"label"] isKindOfClass:[NSArray class]])
				{
					NSMutableString* combined = [NSMutableString new];
					for(NSDictionary* part in hint[@"label"])
						if([part isKindOfClass:[NSDictionary class]] && [part[@"value"] isKindOfClass:[NSString class]])
							[combined appendString:part[@"value"]];
					label = combined;
				}
				if(!label.length) continue;

				size_t bol = target->documentView->begin(line);
				std::string text = target->documentView->substr(bol, target->documentView->eol(line));
				size_t offset = utf16::advance(text.data(), (size_t)character, text.data() + text.size()) - text.data();
				NSString* padded = [NSString stringWithFormat:@"%@%@%@", [hint[@"paddingLeft"] boolValue] ? @" " : @"", label, [hint[@"paddingRight"] boolValue] ? @" " : @""];
				std::string& slot = hints[bol + offset];
				if(!slot.empty() && slot.back() != ' ') slot += ' ';
				slot += to_s(padded);
				if(slot.back() != ' ') slot += ' ';
			}
			target->documentView->set_inlay_hints(hints);
			[target reflectDocumentSize];
			[target setNeedsDisplay:YES];
		}];
	}];
}

@end
