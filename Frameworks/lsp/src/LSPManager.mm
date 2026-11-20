#import "LSPManager.h"
#import "LSPClient.h"
#import "LSPServerSelection.h"
#import "LSPSemanticTokens.h"
#import <document/OakDocument Private.h>
#import <settings/settings.h>
#import <text/types.h>
#import <io/path.h>
#import <ns/ns.h>
#import <oak/oak.h>
#import <OakFoundation/NSString Additions.h>
#include <limits>

NSString* const LSPDiagnosticsDidChangeNotification = @"LSPDiagnosticsDidChange";
NSString* const LSPServerStatusDidChangeNotification = @"LSPServerStatusDidChange";
NSString* const LSPDocumentDidOpenNotification = @"LSPDocumentDidOpen";

static NSDictionary<NSString*, NSString*>* scopeToLanguageId ()
{
	static NSDictionary* map = @{
		@"source.php"           : @"php",
		@"source.c"             : @"c",
		@"source.c++"          : @"cpp",
		@"source.objc"          : @"objective-c",
		@"source.objc++"       : @"objective-cpp",
		@"source.js"            : @"javascript",
		@"source.ts"            : @"typescript",
		@"source.python"        : @"python",
		@"source.go"            : @"go",
		@"source.rust"          : @"rust",
		@"source.ruby"          : @"ruby",
		@"source.java"          : @"java",
		@"source.json"          : @"json",
		@"source.css"           : @"css",
		@"source.html"          : @"html",
		@"source.shell"         : @"shellscript",
		@"source.yaml"          : @"yaml",
		@"source.swift"         : @"swift",
		@"text.html.markdown"   : @"markdown",
	};
	return map;
}

static NSString* languageIdForScope (NSString* fileType)
{
	if(!fileType)
		return @"plaintext";

	NSDictionary* map = scopeToLanguageId();

	// Try progressively shorter scope prefixes for best match
	NSString* scope = fileType;
	while(scope.length > 0)
	{
		NSString* langId = map[scope];
		if(langId)
			return langId;

		NSRange lastDot = [scope rangeOfString:@"." options:NSBackwardsSearch];
		if(lastDot.location == NSNotFound)
			break;
		scope = [scope substringToIndex:lastDot.location];
	}

	// Fallback: strip "source." prefix and use remainder
	if([fileType hasPrefix:@"source."])
		return [fileType substringFromIndex:7];

	return @"plaintext";
}

// Match familiar TextMate theme selectors while retaining the grammar scopes
// beneath the semantic scope. Unknown token types keep their grammar styling.
static std::string scopeForSemanticToken (NSString* type, uint32_t modifiers, NSArray<NSString*>* legend)
{
	static NSDictionary<NSString*, NSString*>* scopes = @{
		@"namespace": @"entity.name.namespace", @"type": @"entity.name.type",
		@"class": @"entity.name.type.class", @"enum": @"entity.name.type.enum",
		@"interface": @"entity.name.type.interface", @"struct": @"entity.name.type.struct",
		@"typeParameter": @"entity.name.type.parameter", @"parameter": @"variable.parameter",
		@"variable": @"variable.other", @"property": @"variable.other.property",
		@"enumMember": @"constant.other.enum", @"event": @"entity.name.event",
		@"function": @"entity.name.function", @"method": @"entity.name.function.member",
		@"macro": @"entity.name.function.macro", @"keyword": @"keyword",
		@"modifier": @"storage.modifier", @"comment": @"comment",
		@"string": @"string", @"number": @"constant.numeric",
		@"regexp": @"string.regexp", @"operator": @"keyword.operator",
		@"decorator": @"entity.name.function.decorator"
	};
	if([@[ @"variable", @"property" ] containsObject:type])
	{
		NSUInteger index = [legend indexOfObject:@"readonly"];
		if(index < 32 && (modifiers & (uint32_t(1) << index)))
			return "constant.other";
	}
	return to_s(scopes[type] ?: @"");
}

std::vector<ng::buffer_t::semantic_range_t> lsp::decode_semantic_tokens (NSArray* data, NSArray<NSString*>* types, NSArray<NSString*>* modifiers, ng::buffer_t const& buffer)
{
	std::vector<ng::buffer_t::semantic_range_t> ranges;
	if(data.count % 5 != 0)
		return ranges;
	uint64_t line = 0, column = 0;
	NSUInteger cachedLine = NSNotFound;
	NSString* lineText = nil;
	for(NSUInteger i = 0; i < data.count; i += 5)
	{
		for(NSUInteger j = 0; j < 5; ++j)
			if(![data[i + j] isKindOfClass:NSNumber.class] || [data[i + j] longLongValue] < 0)
				return {};
		uint64_t deltaLine = [data[i] unsignedLongLongValue];
		uint64_t deltaColumn = [data[i + 1] unsignedLongLongValue];
		uint64_t length = [data[i + 2] unsignedLongLongValue];
		uint64_t typeIndex = [data[i + 3] unsignedLongLongValue];
		uint32_t flags = [data[i + 4] unsignedIntValue];
		if(deltaLine > std::numeric_limits<uint64_t>::max() - line)
			return {};
		line += deltaLine;
		if(line >= buffer.lines())
			return {};
		if(deltaLine) column = 0;
		if(deltaColumn > std::numeric_limits<uint64_t>::max() - column)
			return {};
		column += deltaColumn;
		if(line != cachedLine)
		{
			std::string bytes = buffer.substr(buffer.begin(line), buffer.eol(line));
			lineText = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding];
			if(!lineText) return {};
			cachedLine = line;
		}
		if(length == 0 || column > lineText.length || length > lineText.length - column || typeIndex >= types.count)
			continue;
		std::string semanticScope = scopeForSemanticToken(types[typeIndex], flags, modifiers);
		if(semanticScope.empty())
			continue;
		NSData* before = [[lineText substringToIndex:column] dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
		NSData* token = [[lineText substringWithRange:NSMakeRange(column, length)] dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
		if(!before || !token || !token.length)
			continue;
		size_t from = buffer.begin(line) + before.length;
		size_t to = from + token.length;
		if(to > buffer.eol(line) || (!ranges.empty() && from < ranges.back().to))
			continue;
		ranges.push_back({from, to, semanticScope});
	}
	return ranges;
}

// Uses shared LSPLanguageIdForExtension() from LSPClient.mm

static std::string detectWorkspaceRoot (std::string const& filePath);

// Defaults are only used when the project has no lspCommand setting. Check
// PATH before selecting one so opening a file does not launch a missing server.
NSString* LSPDefaultCommandForExtension (NSString* extension, NSString* searchPath)
{
	static NSDictionary<NSString*, NSArray<NSString*>*>* commands;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		commands = @{
			@"c": @[@"clangd"], @"h": @[@"clangd"], @"cc": @[@"clangd"],
			@"cpp": @[@"clangd"], @"cxx": @[@"clangd"], @"hpp": @[@"clangd"],
			@"hh": @[@"clangd"], @"hxx": @[@"clangd"],
			@"m": @[@"clangd"], @"mm": @[@"clangd"],
			@"go": @[@"gopls"], @"rs": @[@"rust-analyzer"],
			@"py": @[@"pyright-langserver --stdio", @"pylsp"],
			@"pyw": @[@"pyright-langserver --stdio", @"pylsp"],
			@"java": @[@"jdtls"],
			@"js": @[@"typescript-language-server --stdio"],
			@"jsx": @[@"typescript-language-server --stdio"],
			@"ts": @[@"typescript-language-server --stdio"],
			@"tsx": @[@"typescript-language-server --stdio"],
			@"php": @[@"intelephense --stdio"], @"rb": @[@"ruby-lsp"],
			@"lua": @[@"lua-language-server"],
			@"sh": @[@"bash-language-server start"],
			@"bash": @[@"bash-language-server start"],
			@"zsh": @[@"bash-language-server start"],
			@"swift": @[@"sourcekit-lsp", @"xcrun sourcekit-lsp"],
			@"json": @[@"vscode-json-language-server --stdio"],
			@"css": @[@"vscode-css-language-server --stdio"],
			@"html": @[@"vscode-html-language-server --stdio"],
			@"htm": @[@"vscode-html-language-server --stdio"],
			@"yaml": @[@"yaml-language-server --stdio"],
			@"yml": @[@"yaml-language-server --stdio"],
			@"vue": @[@"vue-language-server --stdio"],
			@"svelte": @[@"svelteserver --stdio"],
			@"md": @[@"marksman server"],
			@"toml": @[@"taplo lsp stdio"],
			@"tf": @[@"terraform-ls serve"],
			@"kt": @[@"kotlin-language-server"],
		};
	});

	NSFileManager* fm = NSFileManager.defaultManager;
	NSArray<NSString*>* candidates = commands[extension.lowercaseString];
	for(NSString* directory in [searchPath componentsSeparatedByString:@":"])
	{
		for(NSString* command in candidates)
		{
			std::vector<std::string> parts = path::unescape(to_s(command));
			if(parts.empty())
				continue;
			NSString* executable = to_ns(parts.front());
			NSString* candidate = [executable hasPrefix:@"/"] ? executable : [directory stringByAppendingPathComponent:executable];
			if([fm isExecutableFileAtPath:candidate])
				return [to_ns(path::escape(to_s(candidate))) stringByAppendingString:[command substringFromIndex:executable.length]];
		}
	}
	return nil;
}

std::string LSPExecutableSearchPath (std::string const& root, std::map<std::string, std::string> const& environment)
{
	std::string searchPath;
	auto it = environment.find("PATH");
	if(it != environment.end())
		searchPath = it->second;
	std::vector<std::string> additionalPaths = {
		path::join(root, "node_modules/.bin"), path::join(root, ".venv/bin"),
		path::join(root, "venv/bin")
	};
	if(auto home = environment.find("HOME"); home != environment.end())
	{
		additionalPaths.insert(additionalPaths.end(), {
			path::join(home->second, "go/bin"),
			path::join(home->second, ".cargo/bin"),
			path::join(home->second, ".local/bin"),
			path::join(home->second, ".rbenv/shims"),
			path::join(home->second, ".asdf/shims"),
			path::join(home->second, ".local/share/mise/shims")
		});
	}
	additionalPaths.insert(additionalPaths.end(), { "/opt/homebrew/bin", "/opt/homebrew/opt/llvm/bin", "/usr/local/bin" });
	for(auto path = additionalPaths.rbegin(); path != additionalPaths.rend(); ++path)
		searchPath = *path + ":" + searchPath;
	return searchPath;
}

std::string LSPCommandForDocument (settings_t const& settings, NSString* filePath)
{
	if(!settings.get("lspEnabled", true))
		return "";
	// An explicit empty command disables automatic selection for this file.
	if(settings.has("lspCommand"))
		return settings.get("lspCommand", "");

	std::string root = settings.get("lspRootPath", "");
	if(root.empty())
		root = detectWorkspaceRoot(to_s(filePath));
	std::string searchPath = LSPExecutableSearchPath(root, oak::basic_environment());
	NSString* command = LSPDefaultCommandForExtension(filePath.pathExtension, to_ns(searchPath));
	return command ? to_s(command) : "";
}

static std::vector<std::string> const& workspaceMarkers ()
{
	static std::vector<std::string> const markers = {
		".git", "composer.json", "package.json", "tsconfig.json",
		"CMakeLists.txt", "compile_commands.json", "go.mod",
		"go.work", "Cargo.toml", "pyproject.toml", "setup.py", ".clangd",
		"pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "Gemfile"
	};
	return markers;
}

static std::string detectWorkspaceRoot (std::string const& filePath)
{
	std::string dir = path::parent(filePath);
	std::string previousDir;

	while(dir != previousDir && dir != "/")
	{
		for(auto const& marker : workspaceMarkers())
		{
			if(path::exists(path::join(dir, marker)))
				return dir;
		}
		previousDir = dir;
		dir = path::parent(dir);
	}

	// No marker found — use file's directory
	return path::parent(filePath);
}

@interface LSPManager () <LSPClientDelegate>
{
	NSMutableDictionary<NSString*, LSPClient*>*              _clients;
	NSMutableDictionary<NSUUID*, LSPClient*>*                _documentClients;
	NSMutableDictionary<NSUUID*, NSNumber*>*                 _documentVersions;
	NSMutableSet<NSUUID*>*                                   _openDocuments;
	NSMutableDictionary<NSUUID*, NSTimer*>*                  _changeTimers;
	NSMutableDictionary<NSUUID*, NSArray*>*                  _documentSymbols;
	NSMutableDictionary<NSUUID*, NSNumber*>*                 _semanticTokenRequests;
	NSMutableDictionary<NSString*, NSArray<NSDictionary*>*>* _diagnosticsByURI;
	NSMutableDictionary<NSString*, NSString*>*               _diagnosticReportIdentifiers;
	NSMutableSet<NSString*>* _clearCacheClients;
}
- (void)requestSemanticTokensForDocument:(OakDocument*)document;
- (void)clearSemanticTokensForDocument:(OakDocument*)document;
@end

@implementation LSPManager
+ (instancetype)sharedManager
{
	static LSPManager* instance;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		instance = [LSPManager new];
	});
	return instance;
}

- (instancetype)init
{
	if(self = [super init])
	{
		_clients            = [NSMutableDictionary new];
		_documentClients    = [NSMutableDictionary new];
		_documentVersions   = [NSMutableDictionary new];
		_openDocuments      = [NSMutableSet new];
		_changeTimers       = [NSMutableDictionary new];
		_documentSymbols    = [NSMutableDictionary new];
		_semanticTokenRequests = [NSMutableDictionary new];
		_diagnosticsByURI   = [NSMutableDictionary new];
		_diagnosticReportIdentifiers = [NSMutableDictionary new];
		_clearCacheClients  = [NSMutableSet new];

		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:nil];
	}
	return self;
}

- (void)applicationWillTerminate:(NSNotification*)notification
{
	[self shutdownAll];
}

- (NSString*)keyForClient:(LSPClient*)client
{
	for(NSString* key in _clients)
	{
		if(_clients[key] == client)
			return key;
	}
	return nil;
}

- (LSPClient*)clientForDocument:(OakDocument*)document
{
	if(document.disableLanguageServices || !document.path)
		return nil;

	std::string filePath  = to_s(document.path);
	std::string fileType  = to_s(document.fileType);
	std::string directory = to_s(document.directory ?: [document.path stringByDeletingLastPathComponent]);

	settings_t settings = settings_for_path(filePath, fileType, directory);

	std::string lspCommand = LSPCommandForDocument(settings, document.path);
	if(lspCommand.empty())
		return nil;

	bool lspEnabled = settings.get("lspEnabled", true);
	if(!lspEnabled)
		return nil;

	// Determine workspace root
	std::string rootPath = settings.get("lspRootPath", "");
	if(rootPath.empty())
		rootPath = detectWorkspaceRoot(filePath);

	NSString* root = to_ns(rootPath);
	std::string initOpts = settings.get("lspInitOptions", "");
	NSString* initOptsJSON = initOpts.empty() ? nil : to_ns(initOpts);
	NSString* key = [@[root, to_ns(lspCommand), initOptsJSON ?: @""] componentsJoinedByString:@"\u001f"];
	LSPClient* client = _clients[key];
	if(client)
		return client;

	// Parse command: first whitespace-delimited token is executable, rest are args
	std::vector<std::string> parts = path::unescape(lspCommand);
	if(parts.empty())
		return nil;

	NSString* executable = to_ns(parts[0]);
	NSMutableArray<NSString*>* args = [NSMutableArray new];
	for(size_t i = 1; i < parts.size(); ++i)
		[args addObject:to_ns(parts[i])];

	if([_clearCacheClients containsObject:key])
	{
		[_clearCacheClients removeObject:key];
		// Merge clearCache:true into initializationOptions for servers like Intelephense
		if(initOptsJSON.length)
		{
			NSData* data = [initOptsJSON dataUsingEncoding:NSUTF8StringEncoding];
			NSMutableDictionary* opts = [[NSJSONSerialization JSONObjectWithData:data options:0 error:nil] mutableCopy];
			if(!opts)
				opts = [NSMutableDictionary new];
			opts[@"clearCache"] = @YES;
			NSData* merged = [NSJSONSerialization dataWithJSONObject:opts options:0 error:nil];
			initOptsJSON = [[NSString alloc] initWithData:merged encoding:NSUTF8StringEncoding];
		}
		else
		{
			initOptsJSON = @"{\"clearCache\":true}";
		}
	}

	client = [[LSPClient alloc] initWithCommand:executable arguments:args workingDirectory:root initOptions:initOptsJSON];
	client.delegate = self;
	_clients[key] = client;
	[NSNotificationCenter.defaultCenter postNotificationName:LSPServerStatusDidChangeNotification object:self];
	return client;
}

- (void)documentDidOpen:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	if([_openDocuments containsObject:docId])
		return;

	NSString* langId = languageIdForScope(document.fileType);
	NSString* extension = document.path.pathExtension.lowercaseString;
	// Grammar scopes such as source.ts and source.js can cover TSX/JSX too;
	// those files need their own language IDs even when the scope matches.
	if([langId isEqualToString:@"plaintext"] || [@[ @"jsx", @"tsx", @"vue", @"svelte" ] containsObject:extension])
		langId = LSPLanguageIdForExtension(extension);

	// Don't connect plaintext files — prevents unscoped lspCommand
	// from launching a server for every file type
	if([langId isEqualToString:@"plaintext"])
		return;

	LSPClient* client = [self clientForDocument:document];
	if(!client)
		return;

	[_openDocuments addObject:docId];
	_documentClients[docId]  = client;
	_documentVersions[docId] = @1;

	[client openDocument:document languageId:langId];
}

- (void)clearSemanticTokensForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	NSNumber* request = _semanticTokenRequests[docId];
	if(request)
	{
		[_documentClients[docId] cancelRequest:request.intValue];
		[_semanticTokenRequests removeObjectForKey:docId];
	}
	if(document.isLoaded)
		[document buffer].set_semantic_scopes({});
}

- (void)requestSemanticTokensForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client || !client.running || !client.initialized || (!client.semanticTokensFullProvider && !client.semanticTokensRangeProvider) || !document.isLoaded || !document.path || ![_openDocuments containsObject:docId])
		return;
	NSNumber* oldRequest = _semanticTokenRequests[docId];
	if(oldRequest)
		[client cancelRequest:oldRequest.intValue];
	[_semanticTokenRequests removeObjectForKey:docId];

	NSString* path = [document.path copy];
	size_t revision = [document buffer].revision();
	NSNumber* version = _documentVersions[docId];
	NSArray<NSString*>* types = client.semanticTokenTypes;
	NSArray<NSString*>* modifiers = client.semanticTokenModifiers;
	NSMutableDictionary* params = [@{ @"textDocument": @{ @"uri": [NSURL fileURLWithPath:path].absoluteString } } mutableCopy];
	NSString* method = @"textDocument/semanticTokens/full";
	if(!client.semanticTokensFullProvider)
	{
		method = @"textDocument/semanticTokens/range";
		ng::buffer_t const& buffer = [document buffer];
		size_t lastLine = buffer.lines() - 1;
		NSString* lastLineText = to_ns(buffer.substr(buffer.begin(lastLine), buffer.eol(lastLine)));
		params[@"range"] = @{ @"start": @{ @"line": @0, @"character": @0 },
			@"end": @{ @"line": @(lastLine), @"character": @(lastLineText.length) } };
	}
	__block int requestId = -1;
	__weak LSPManager* weakSelf = self;
	requestId = [client sendCustomRequest:method params:params completion:^(id response) {
		LSPManager* manager = weakSelf;
		if(!manager || ![manager->_semanticTokenRequests[docId] isEqual:@(requestId)]) return;
		[manager->_semanticTokenRequests removeObjectForKey:docId];
		if(manager->_documentClients[docId] != client || ![manager->_documentVersions[docId] isEqual:version] ||
			!document.isLoaded || ![document.path isEqualToString:path] || [document buffer].revision() != revision)
			return;
		if(response == NSNull.null)
		{
			[document buffer].set_semantic_scopes({});
			return;
		}
		if(![response isKindOfClass:NSDictionary.class] || ![response[@"data"] isKindOfClass:NSArray.class])
			return;
		auto ranges = lsp::decode_semantic_tokens(response[@"data"], types, modifiers, [document buffer]);
		[document buffer].set_semantic_scopes(ranges);
	}];
	if(requestId >= 0)
		_semanticTokenRequests[docId] = @(requestId);
}

- (void)documentDidChange:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	if(![_openDocuments containsObject:docId])
		return;

	[self clearSemanticTokensForDocument:document];
	[_documentSymbols removeObjectForKey:docId];
	[_changeTimers[docId] invalidate];

	__weak LSPManager* weakSelf = self;
	_changeTimers[docId] = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:NO block:^(NSTimer* timer) {
		[weakSelf sendDidChangeForDocument:document];
	}];
}

- (void)sendDidChangeForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	[_changeTimers removeObjectForKey:docId];

	LSPClient* client = _documentClients[docId];
	if(!client)
		return;

	int version = [_documentVersions[docId] intValue] + 1;
	_documentVersions[docId] = @(version);
	[client documentDidChange:document version:version];
	[self requestSemanticTokensForDocument:document];
}

- (void)documentDidSave:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	if(![_openDocuments containsObject:docId])
		return;

	// Flush any pending change notification
	if(_changeTimers[docId])
	{
		[_changeTimers[docId] invalidate];
		[self sendDidChangeForDocument:document];
	}

	LSPClient* client = _documentClients[docId];
	if(client)
		[client documentDidSave:document];
}

- (void)documentWillClose:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	if(![_openDocuments containsObject:docId])
		return;

	[self clearSemanticTokensForDocument:document];
	[_changeTimers[docId] invalidate];
	[_changeTimers removeObjectForKey:docId];

	LSPClient* client = _documentClients[docId];
	if(client)
		[client closeDocument:document];

	[_openDocuments removeObject:docId];
	[_documentClients removeObjectForKey:docId];
	[_documentVersions removeObjectForKey:docId];
	[_documentSymbols removeObjectForKey:docId];

	NSString* path = document.path;
	if(path)
	{
		NSURL* fileURL = [NSURL fileURLWithPath:path];
		[_diagnosticsByURI removeObjectForKey:fileURL.absoluteString];
		[_diagnosticReportIdentifiers removeObjectForKey:fileURL.absoluteString];
	}
}

- (void)shutdownAll
{
	for(NSUUID* docId in _openDocuments)
		if(OakDocument* document = [OakDocument documentWithIdentifier:docId])
			[self clearSemanticTokensForDocument:document];
	for(NSTimer* timer in _changeTimers.allValues)
		[timer invalidate];
	[_changeTimers removeAllObjects];

	for(LSPClient* client in _clients.allValues)
		[client shutdown];

	[_clients removeAllObjects];
	[_documentClients removeAllObjects];
	[_documentVersions removeAllObjects];
	[_documentSymbols removeAllObjects];
	[_openDocuments removeAllObjects];
}

- (void)flushPendingChangesForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	if(![_openDocuments containsObject:docId])
		return;

	// Cancel any pending debounce timer
	[_changeTimers[docId] invalidate];
	[_changeTimers removeObjectForKey:docId];

	// Always send current content so server has latest state
	LSPClient* client = _documentClients[docId];
	if(!client)
		return;

	int version = [_documentVersions[docId] intValue] + 1;
	_documentVersions[docId] = @(version);
	[client documentDidChange:document version:version];
	[self requestSemanticTokensForDocument:document];
}

- (void)requestCompletionsForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character prefix:(NSString*)prefix completion:(void(^)(NSArray<NSDictionary*>*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback)
			callback(@[]);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(@[]);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	[client requestCompletionForURI:uri line:line character:character completion:^(NSArray<NSDictionary*>* suggestions) {
		if(callback)
			callback(suggestions);
	}];
}

- (dispatch_block_t)requestLanguageQuery:(NSString*)method forDocument:(OakDocument*)document params:(NSDictionary*)params completion:(void(^)(id, NSString*))callback
{
	NSAssert(NSThread.isMainThread, @"Language queries run on the main thread");
	LSPClient* client = _documentClients[document.identifier];
	if(!client || !client.running || ![_openDocuments containsObject:document.identifier]) { callback(nil, @"server_unavailable"); return nil; }
	if(!client.initialized) { callback(nil, @"server_starting"); return nil; }
	if(![client supportsLanguageQuery:method]) { callback(nil, @"unsupported_capability"); return nil; }
	[self flushPendingChangesForDocument:document];
	int requestId = [client sendCustomRequest:method params:params completion:^(id result){
		callback(result, result ? nil : @"language_request_failed");
	}];
	__weak LSPClient* originalClient = client;
	return ^{ [originalClient cancelRequest:requestId]; };
}

- (NSArray*)cachedDocumentSymbolsForDocument:(OakDocument*)document
{
	return document ? _documentSymbols[document.identifier] : nil;
}

- (dispatch_block_t)requestDocumentSymbolsForDocument:(OakDocument*)document completion:(void(^)(NSArray*))callback
{
	NSString* path = document.path;
	if(!path || !document.isLoaded)
	{
		callback(nil);
		return nil;
	}

	NSUUID* docId = document.identifier;
	__weak LSPClient* originalClient = _documentClients[docId];
	size_t revision = [document buffer].revision();
	NSDictionary* params = @{ @"textDocument": @{ @"uri": [NSURL fileURLWithPath:path].absoluteString } };
	return [self requestLanguageQuery:@"textDocument/documentSymbol" forDocument:document params:params completion:^(id result, NSString* errorCode){
		LSPClient* client = originalClient;
		if(errorCode || !client || _documentClients[docId] != client || !document.isLoaded || ![document.path isEqualToString:path] || [document buffer].revision() != revision)
		{
			callback(nil);
			return;
		}
		NSArray* symbols = [result isKindOfClass:NSArray.class] ? result : (result == NSNull.null ? @[] : nil);
		if(symbols)
			_documentSymbols[docId] = symbols;
		callback(symbols);
	}];
}

- (void)requestDefinitionForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSArray<NSDictionary*>*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback)
			callback(@[]);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(@[]);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	[client requestDefinitionForURI:uri line:line character:character completion:callback];
}

- (int)requestHoverForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSDictionary*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback)
			callback(nil);
		return 0;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(nil);
		return 0;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	return [client requestHoverForURI:uri line:line character:character completion:callback];
}

- (void)cancelRequest:(int)requestId forDocument:(OakDocument*)document
{
	if(requestId == 0)
		return;

	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	[client cancelRequest:requestId];
}

- (void)requestReferencesForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSArray<NSDictionary*>*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback)
			callback(@[]);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(@[]);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	[client requestReferencesForURI:uri line:line character:character completion:callback];
}

- (void)requestFormattingForDocument:(OakDocument*)document tabSize:(NSUInteger)tabSize insertSpaces:(BOOL)insertSpaces completion:(void(^)(NSArray<NSDictionary*>*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client || !client.documentFormattingProvider)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	[client requestFormattingForURI:uri tabSize:tabSize insertSpaces:insertSpaces completion:callback];
}

- (void)requestRangeFormattingForDocument:(OakDocument*)document startLine:(NSUInteger)startLine startCharacter:(NSUInteger)startCharacter endLine:(NSUInteger)endLine endCharacter:(NSUInteger)endCharacter tabSize:(NSUInteger)tabSize insertSpaces:(BOOL)insertSpaces completion:(void(^)(NSArray<NSDictionary*>*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client || !client.documentRangeFormattingProvider)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	[client requestRangeFormattingForURI:uri startLine:startLine startCharacter:startCharacter endLine:endLine endCharacter:endCharacter tabSize:tabSize insertSpaces:insertSpaces completion:callback];
}

- (void)resolveCompletionItem:(NSDictionary*)item forDocument:(OakDocument*)document completion:(void(^)(NSDictionary*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback)
			callback(nil);
		return;
	}

	[client resolveCompletionItem:item completion:^(NSDictionary* resolved) {
		if(callback)
			callback(resolved);
	}];
}

- (BOOL)serverSupportsCompletionResolveForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	return client && client.completionResolveProvider;
}

- (BOOL)serverSupportsFormattingForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	return client && client.documentFormattingProvider;
}

- (BOOL)serverSupportsRangeFormattingForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	return client && client.documentRangeFormattingProvider;
}

- (BOOL)serverSupportsRenameForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	return client && client.renameProvider;
}

- (void)requestPrepareRenameForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSDictionary* _Nullable))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	[client prepareRenameForURI:uri line:line character:character completion:callback];
}

- (void)requestRenameForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character newName:(NSString*)newName completion:(void(^)(NSDictionary* _Nullable))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	[client requestRenameForURI:uri line:line character:character newName:newName completion:callback];
}

- (BOOL)serverSupportsCodeActionsForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	return client && client.codeActionProvider;
}

- (BOOL)serverSupportsCodeActionResolveForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	return client && client.codeActionResolveProvider;
}

- (void)requestCodeActionsForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character endLine:(NSUInteger)endLine endCharacter:(NSUInteger)endCharacter completion:(void(^)(NSArray<NSDictionary*>*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback) callback(nil);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback) callback(nil);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	NSArray<NSDictionary*>* diagnostics = [self diagnosticsForDocument:document atLine:line character:character endLine:endLine endCharacter:endCharacter];

	[self flushPendingChangesForDocument:document];
	[client requestCodeActionsForURI:uri line:line character:character endLine:endLine endCharacter:endCharacter diagnostics:diagnostics completion:callback];
}

- (void)resolveCodeAction:(NSDictionary*)codeAction forDocument:(OakDocument*)document completion:(void(^)(NSDictionary*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback) callback(nil);
		return;
	}
	[client resolveCodeAction:codeAction completion:callback];
}

- (void)executeCommand:(NSString*)command arguments:(NSArray*)arguments forDocument:(OakDocument*)document completion:(void(^)(id))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback) callback(nil);
		return;
	}
	[client executeCommand:command arguments:arguments completion:callback];
}

- (BOOL)hasClientForDocument:(OakDocument*)document
{
	return document && _documentClients[document.identifier] != nil;
}

- (NSDictionary<NSString*, NSNumber*>*)diagnosticCountsForDocument:(OakDocument*)document
{
	NSUInteger errors = 0, warnings = 0, info = 0;
	NSString* path = document.path;
	if(path)
	{
		NSURL* fileURL = [NSURL fileURLWithPath:path];
		NSArray<NSDictionary*>* diags = _diagnosticsByURI[fileURL.absoluteString];
		for(NSDictionary* diag in diags)
		{
			switch([diag[@"severity"] intValue])
			{
				case 1:  errors++;   break;
				case 2:  warnings++; break;
				case 3:
				case 4:  info++;     break;
				default: break;
			}
		}
	}
	return @{ @"errors": @(errors), @"warnings": @(warnings), @"info": @(info) };
}

- (NSArray<NSDictionary*>*)diagnosticsForDocument:(OakDocument*)document
{
	NSString* path = document.path;
	if(!path)
		return @[];

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	return _diagnosticsByURI[fileURL.absoluteString] ?: @[];
}

- (NSDictionary*)diagnosticReportForDocument:(OakDocument*)document
{
	NSAssert(NSThread.isMainThread, @"Capture diagnostics on the main thread");
	NSString* uri = document.path ? [NSURL fileURLWithPath:document.path].absoluteString : nil;
	NSArray* diagnostics = uri ? _diagnosticsByURI[uri] : nil;
	NSString* serverStatus = uri ? ([self serverStatusForDocument:document] ?: @"unavailable") : @"unavailable";
	return @{ @"diagnostics": [diagnostics copy] ?: @[],
	          @"reportId": (uri ? _diagnosticReportIdentifiers[uri] : nil) ?: (id)NSNull.null,
	          @"status": diagnostics ? @"reported" : ([serverStatus isEqual:@"unavailable"] ? @"unavailable" : @"pending"),
	          @"serverStatus": serverStatus,
	          @"pendingChanges": @(_changeTimers[document.identifier] != nil),
	          // LSP diagnostics do not always carry a document version. The
	          // current buffer revision must not be presented as their revision.
	          @"freshness": @"unknown" };
}

- (NSString*)serverStatusForDocument:(OakDocument*)document
{
	LSPClient* client = _documentClients[document.identifier];
	if(!client)
		return nil;
	if(client.initialized && client.indexing)
		return @"indexing";
	if(client.initialized)
		return @"running";
	if(client.running)
		return @"starting";
	return nil;
}

- (NSString*)serverNameForDocument:(OakDocument*)document
{
	LSPClient* client = _documentClients[document.identifier];
	return client.serverName;
}

- (void)restartServerForDocument:(OakDocument*)document
{
	LSPClient* client = _documentClients[document.identifier];
	if(!client)
		return;

	// Collect affected documents and clean up state synchronously
	// so documentDidOpen: can re-register them with a fresh client
	NSMutableArray<OakDocument*>* affectedDocs = [NSMutableArray new];
	for(NSUUID* docId in _documentClients)
	{
		if(_documentClients[docId] == client)
		{
			OakDocument* doc = [OakDocument documentWithIdentifier:docId];
			if(doc && doc.isLoaded)
				[affectedDocs addObject:doc];
		}
	}

	// Remove client from _clients so a new one will be created
	NSString* keyToRemove = [self keyForClient:client];
	if(keyToRemove)
		[_clients removeObjectForKey:keyToRemove];

	// Dissociate documents before shutdown
	for(OakDocument* doc in affectedDocs)
	{
		NSUUID* docId = doc.identifier;
		[self clearSemanticTokensForDocument:doc];
		[_changeTimers[docId] invalidate];
		[_changeTimers removeObjectForKey:docId];
		[_documentClients removeObjectForKey:docId];
		[_documentVersions removeObjectForKey:docId];
		[_documentSymbols removeObjectForKey:docId];
		[_openDocuments removeObject:docId];
	}

	// Old process shuts down asynchronously; lspClientDidTerminate: will be a no-op
	[client shutdown];

	// Re-open with fresh client immediately
	for(OakDocument* doc in affectedDocs)
		[self documentDidOpen:doc];

	[NSNotificationCenter.defaultCenter postNotificationName:LSPServerStatusDidChangeNotification object:self];
}

- (void)reindexWorkspaceForDocument:(OakDocument*)document
{
	LSPClient* client = _documentClients[document.identifier];
	if(!client)
		return;

	// Check if server advertises a reindex-like command
	for(NSString* cmd in client.executeCommands)
	{
		NSString* lower = cmd.lowercaseString;
		if([lower containsString:@"reindex"] || [lower containsString:@"index.workspace"] || [lower containsString:@"index-workspace"])
		{
			NSLog(@"[LSP:%@] Re-index: using server command '%@'", client.serverName, cmd);
			[client executeCommand:cmd arguments:nil completion:^(id result) {
				if(!result)
					NSLog(@"[LSP:%@] Re-index command '%@' failed or returned null", client.serverName, cmd);
			}];
			return;
		}
	}
	NSLog(@"[LSP:%@] Re-index: restarting with clearCache", client.serverName);

	// Fallback: restart with clearCache in initializationOptions
	NSString* keyToFlag = [self keyForClient:client];
	if(keyToFlag)
		[_clearCacheClients addObject:keyToFlag];

	[self restartServerForDocument:document];
}

- (NSArray<NSDictionary*>*)diagnosticsForDocument:(OakDocument*)document atLine:(NSUInteger)line character:(NSUInteger)character endLine:(NSUInteger)endLine endCharacter:(NSUInteger)endCharacter
{
	NSString* path = document.path;
	if(!path)
		return @[];

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;
	NSArray<NSDictionary*>* allDiags = _diagnosticsByURI[uri];
	if(!allDiags)
		return @[];

	NSMutableArray<NSDictionary*>* result = [NSMutableArray array];
	for(NSDictionary* diag in allDiags)
	{
		NSUInteger dLine    = [diag[@"line"] unsignedIntegerValue];
		NSUInteger dEndLine = [diag[@"endLine"] unsignedIntegerValue];

		// Simple line-range overlap check
		if(dEndLine >= line && dLine <= endLine)
			[result addObject:diag];
	}
	return result;
}

#pragma mark - LSPClientDelegate

- (void)lspClient:(LSPClient*)client didReceiveNotification:(NSString*)method params:(NSDictionary*)params
{
	if(![method isEqualToString:@"workspace/semanticTokens/refresh"])
		return;
	for(NSUUID* docId in [_openDocuments copy])
	{
		if(_documentClients[docId] != client)
			continue;
		if(OakDocument* doc = [OakDocument documentWithIdentifier:docId])
		{
			[self flushPendingChangesForDocument:doc];
		}
	}
}

- (void)lspClient:(LSPClient*)client didOpenDocument:(OakDocument*)document
{
	// An older client may still be finishing a deferred didOpen after a restart.
	if(_documentClients[document.identifier] == client)
	{
		[NSNotificationCenter.defaultCenter postNotificationName:LSPDocumentDidOpenNotification object:document];
		[self requestSemanticTokensForDocument:document];
	}
}

- (void)lspClient:(LSPClient*)client didReceiveApplyEditRequest:(NSDictionary*)workspaceEdit requestId:(id)requestId
{
	dispatch_async(dispatch_get_main_queue(), ^{
		NSDictionary* userInfo = @{
			@"workspaceEdit": workspaceEdit,
			@"requestId": requestId ?: [NSNull null],
			@"client": client
		};
		[NSNotificationCenter.defaultCenter postNotificationName:@"LSPApplyEditRequest" object:self userInfo:userInfo];
	});
}

- (void)lspClientDidTerminate:(LSPClient*)client
{
	NSLog(@"[LSP:%@] Handling server termination, cleaning up client", client.serverName);

	// Find and remove the dead client from _clients
	NSString* keyToRemove = [self keyForClient:client];
	if(keyToRemove)
		[_clients removeObjectForKey:keyToRemove];

	// Dissociate all documents that were using this client
	NSMutableArray<NSUUID*>* docIdsToRemove = [NSMutableArray new];
	for(NSUUID* docId in _documentClients)
	{
		if(_documentClients[docId] == client)
			[docIdsToRemove addObject:docId];
	}

	for(NSUUID* docId in docIdsToRemove)
	{
		if(OakDocument* doc = [OakDocument documentWithIdentifier:docId])
			[self clearSemanticTokensForDocument:doc];
		[_changeTimers[docId] invalidate];
		[_changeTimers removeObjectForKey:docId];
		[_documentClients removeObjectForKey:docId];
		[_documentVersions removeObjectForKey:docId];
		[_documentSymbols removeObjectForKey:docId];
		[_openDocuments removeObject:docId];
	}

	[NSNotificationCenter.defaultCenter postNotificationName:LSPServerStatusDidChangeNotification object:self];
}

- (void)lspClient:(LSPClient*)client didReceiveDiagnostics:(NSArray<NSDictionary*>*)diagnostics forDocumentURI:(NSString*)uri
{
	// Cache full diagnostics for codeAction requests
	_diagnosticsByURI[uri] = [diagnostics copy];
	_diagnosticReportIdentifiers[uri] = NSUUID.UUID.UUIDString;

	NSURL* url = [NSURL URLWithString:uri];
	NSString* filePath = url.path;
	if(!filePath)
		return;

	OakDocument* doc = [OakDocument documentWithPath:filePath];
	if(!doc || !doc.isLoaded)
		return;

	[doc removeAllMarksOfType:@"error"];
	[doc removeAllMarksOfType:@"warning"];
	[doc removeAllMarksOfType:@"note"];

	for(NSDictionary* diag in diagnostics)
	{
		NSNumber* severity = diag[@"severity"];
		NSString* message  = diag[@"message"];
		NSNumber* line     = diag[@"line"];

		if(!message || !line)
			continue;

		NSString* markType;
		switch(severity.intValue)
		{
			case 1:  markType = @"error";   break;
			case 2:  markType = @"warning"; break;
			default: markType = @"note";    break;
		}

		text::pos_t pos(line.unsignedIntegerValue, 0);
		[doc setMarkOfType:markType atPosition:pos content:message];
	}

	[NSNotificationCenter.defaultCenter postNotificationName:LSPDiagnosticsDidChangeNotification object:self userInfo:@{ @"uri": uri }];
}

- (NSSet<NSString*>*)lspClientOpenDocumentPaths:(LSPClient*)client
{
	NSMutableSet<NSString*>* paths = [NSMutableSet new];
	for(NSUUID* docId in _openDocuments)
	{
		if(_documentClients[docId] != client)
			continue;

		OakDocument* doc = [OakDocument documentWithIdentifier:docId];
		if(doc.path)
			[paths addObject:doc.path];
	}
	return paths;
}
@end
