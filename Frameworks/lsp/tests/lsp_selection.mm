#import <Foundation/Foundation.h>
#import "../src/LSPServerSelection.h"
#include <oak/oak.h>
#include <io/path.h>

static int failures = 0;

static void Check (BOOL condition, NSString* message)
{
	if(!condition)
	{
		fprintf(stderr, "FAIL: %s\n", message.UTF8String);
		++failures;
	}
}

int main ()
{
	@autoreleasepool
	{
		NSFileManager* fm = NSFileManager.defaultManager;
		NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
		Check([fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil], @"create test directory");

		for(NSString* executable in @[ @"pyright-langserver", @"pylsp", @"gopls", @"rust-analyzer", @"ruby-lsp", @"clangd", @"bash-language-server", @"jdtls" ])
		{
			NSString* path = [directory stringByAppendingPathComponent:executable];
			Check([fm createFileAtPath:path contents:[NSData data] attributes:@{ NSFilePosixPermissions: @0755 }], @"create executable");
		}

		Check([LSPDefaultCommandForExtension(@"PY", directory) isEqualToString:[[directory stringByAppendingPathComponent:@"pyright-langserver"] stringByAppendingString:@" --stdio"]], @"case-insensitive extension and first available server");
		NSDictionary<NSString*, NSString*>* expected = @{
			@"go": @"gopls", @"rs": @"rust-analyzer", @"rb": @"ruby-lsp",
			@"c": @"clangd", @"cpp": @"clangd", @"hxx": @"clangd",
			@"sh": @"bash-language-server", @"zsh": @"bash-language-server",
			@"java": @"jdtls"
		};
		for(NSString* extension in expected)
		{
			NSString* command = LSPDefaultCommandForExtension(extension, directory);
			NSString* executable = [directory stringByAppendingPathComponent:expected[extension]];
			auto parts = path::unescape(command.UTF8String ?: "");
			Check(!parts.empty() && parts.front() == executable.UTF8String, [NSString stringWithFormat:@"%@ selects %@", extension, expected[extension]]);
		}
		Check(LSPDefaultCommandForExtension(@"kt", directory) == nil, @"missing server is skipped");
		Check(LSPDefaultCommandForExtension(@"unknown", directory) == nil, @"unknown extension is skipped");

		[fm removeItemAtPath:[directory stringByAppendingPathComponent:@"pyright-langserver"] error:nil];
		Check([LSPDefaultCommandForExtension(@"py", directory) isEqualToString:[directory stringByAppendingPathComponent:@"pylsp"]], @"second available server is selected");

		settings_t override(std::map<std::string, std::string>{ { "lspCommand", "custom-lsp --stdio" } });
		Check(LSPCommandForDocument(override, @"/tmp/example.go") == "custom-lsp --stdio", @"explicit command overrides extension");
		settings_t disabled(std::map<std::string, std::string>{ { "lspEnabled", "false" }, { "lspCommand", "custom-lsp" } });
		Check(LSPCommandForDocument(disabled, @"/tmp/example.go").empty(), @"lspEnabled disables explicit server");
		settings_t empty(std::map<std::string, std::string>{ { "lspCommand", "" } });
		Check(LSPCommandForDocument(empty, @"/tmp/example.go").empty(), @"empty command disables automatic selection");

		auto goplsOptions = ^NSDictionary*(NSString* json) {
			NSString* result = LSPGoplsInitializationOptions(json);
			return [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
		};
		Check([goplsOptions(nil)[@"semanticTokens"] boolValue], @"gopls enables semantic tokens by default");
		Check([goplsOptions(nil)[@"hints"][@"parameterNames"] boolValue], @"gopls enables parameter name hints by default");
		NSDictionary* custom = goplsOptions(@"{\"semanticTokens\":false,\"hints\":{\"parameterNames\":false},\"staticcheck\":true}");
		Check([custom[@"semanticTokens"] isEqual:@NO], @"gopls preserves explicit semantic token setting");
		Check([custom[@"hints"][@"parameterNames"] isEqual:@NO], @"gopls preserves explicit hint setting");
		Check([custom[@"staticcheck"] isEqual:@YES], @"gopls preserves unrelated options");

		// GUI-launched TextMate has a system PATH even when Go installed gopls
		// into ~/go/bin. Exercise the actual document selection path.
		NSString* goBin = [directory stringByAppendingPathComponent:@"go/bin"];
		[fm createDirectoryAtPath:goBin withIntermediateDirectories:YES attributes:nil error:nil];
		[fm createFileAtPath:[goBin stringByAppendingPathComponent:@"gopls"] contents:[NSData data] attributes:@{ NSFilePosixPermissions: @0755 }];
		auto environment = oak::basic_environment();
		auto limitedEnvironment = environment;
		limitedEnvironment["HOME"] = directory.UTF8String;
		limitedEnvironment["PATH"] = "/usr/bin:/bin";
		oak::set_basic_environment(limitedEnvironment);
		std::string detected = LSPCommandForDocument(settings_t(), @"/tmp/example.go");
		Check(path::unescape(detected) == std::vector<std::string>{ [goBin stringByAppendingPathComponent:@"gopls"].UTF8String }, @"Go finds ~/go/bin/gopls outside GUI PATH");
		NSString* rubyShims = [directory stringByAppendingPathComponent:@".rbenv/shims"];
		[fm createDirectoryAtPath:rubyShims withIntermediateDirectories:YES attributes:nil error:nil];
		[fm createFileAtPath:[rubyShims stringByAppendingPathComponent:@"ruby-lsp"] contents:[NSData data] attributes:@{ NSFilePosixPermissions: @0755 }];
		detected = LSPCommandForDocument(settings_t(), @"/tmp/example.rb");
		Check(path::unescape(detected) == std::vector<std::string>{ [rubyShims stringByAppendingPathComponent:@"ruby-lsp"].UTF8String }, @"Ruby finds rbenv shim outside GUI PATH");
		NSString* project = [directory stringByAppendingPathComponent:@"project with spaces"];
		NSString* venvBin = [project stringByAppendingPathComponent:@".venv/bin"];
		[fm createDirectoryAtPath:venvBin withIntermediateDirectories:YES attributes:nil error:nil];
		[fm createFileAtPath:[project stringByAppendingPathComponent:@"pyproject.toml"] contents:[NSData data] attributes:nil];
		[fm createFileAtPath:[venvBin stringByAppendingPathComponent:@"pylsp"] contents:[NSData data] attributes:@{ NSFilePosixPermissions: @0755 }];
		detected = LSPCommandForDocument(settings_t(), [project stringByAppendingPathComponent:@"main.py"]);
		Check(path::unescape(detected) == std::vector<std::string>{ [venvBin stringByAppendingPathComponent:@"pylsp"].UTF8String }, @"Python finds project virtualenv and escapes spaces");
		oak::set_basic_environment(environment);

		[fm removeItemAtPath:directory error:nil];
	}
	return failures ? 1 : 0;
}
