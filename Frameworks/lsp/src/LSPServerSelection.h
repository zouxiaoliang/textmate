#ifndef LSP_SERVER_SELECTION_H
#define LSP_SERVER_SELECTION_H

#import <Foundation/Foundation.h>
#include <settings/settings.h>

NSString* LSPDefaultCommandForExtension (NSString* extension, NSString* searchPath);
std::string LSPExecutableSearchPath (std::string const& root, std::map<std::string, std::string> const& environment);
std::string LSPCommandForDocument (settings_t const& settings, NSString* filePath);
NSString* LSPGoplsInitializationOptions (NSString* configuredJSON);

#endif
