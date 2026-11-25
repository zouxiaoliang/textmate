#import "ProjectWorkspace.h"
#import <io/path.h>
#import <ns/ns.h>

NSData* ProjectJSONDataWithoutComments(NSData* original)
{
	NSMutableData* cleaned = [original mutableCopy];
	auto bytes = static_cast<unsigned char*>(cleaned.mutableBytes);
	NSUInteger length = cleaned.length;
	if(length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf)
		memset(bytes, ' ', 3);

	bool quoted = false;
	for(NSUInteger index = 0; index < length; ++index)
	{
		unsigned char ch = bytes[index];
		if(quoted)
		{
			if(ch == '\\')
				++index;
			else if(ch == '"')
				quoted = false;
		}
		else if(ch == '"')
			quoted = true;
		else if(ch == '/' && index+1 < length && bytes[index+1] == '/')
		{
			while(index < length && bytes[index] != '\r' && bytes[index] != '\n')
				bytes[index++] = ' ';
		}
		else if(ch == '/' && index+1 < length && bytes[index+1] == '*')
		{
			bytes[index++] = ' ';
			bytes[index++] = ' ';
			while(index+1 < length && !(bytes[index] == '*' && bytes[index+1] == '/'))
			{
				if(bytes[index] != '\r' && bytes[index] != '\n')
					bytes[index] = ' ';
				++index;
			}
			if(index+1 >= length)
				return nil;
			bytes[index++] = ' ';
			bytes[index] = ' ';
		}
	}

	quoted = false;
	for(NSUInteger index = 0; index < length; ++index)
	{
		unsigned char ch = bytes[index];
		if(quoted)
		{
			if(ch == '\\')
				++index;
			else if(ch == '"')
				quoted = false;
		}
		else if(ch == '"')
			quoted = true;
		else if(ch == ',')
		{
			NSUInteger next = index+1;
			while(next < length && strchr(" \t\r\n", bytes[next]))
				++next;
			NSUInteger previous = index;
			while(previous > 0 && strchr(" \t\r\n", bytes[previous-1]))
				--previous;
			if(previous && bytes[previous-1] != '[' && bytes[previous-1] != '{' && bytes[previous-1] != ',' &&
			   next < length && (bytes[next] == '}' || bytes[next] == ']'))
				bytes[index] = ' ';
		}
	}
	return cleaned;
}

static NSUInteger AfterJSONString(unsigned char const* bytes, NSUInteger start, NSUInteger length)
{
	for(NSUInteger index = start+1; index < length; ++index)
	{
		if(bytes[index] == '\\')
			++index;
		else if(bytes[index] == '"')
			return index+1;
	}
	return length;
}

static NSRange WorkspaceFoldersRange(NSData* json)
{
	auto bytes = static_cast<unsigned char const*>(json.bytes);
	NSUInteger length = json.length, depth = 0;
	NSRange result = NSMakeRange(NSNotFound, 0);
	for(NSUInteger index = 0; index < length; ++index)
	{
		switch(bytes[index])
		{
			case '{': case '[': ++depth; break;
			case '}': case ']': --depth; break;
			case '"':
			{
				NSUInteger end = AfterJSONString(bytes, index, length);
				if(depth == 1)
				{
					NSUInteger colon = end;
					while(colon < length && strchr(" \t\r\n", bytes[colon]))
						++colon;
					if(colon < length && bytes[colon] == ':')
					{
						NSData* key = [json subdataWithRange:NSMakeRange(index, end-index)];
						if([[NSJSONSerialization JSONObjectWithData:key options:NSJSONReadingFragmentsAllowed error:nil] isEqual:@"folders"])
						{
							if(result.location != NSNotFound)
								return NSMakeRange(NSNotFound, 0);
							NSUInteger start = colon+1;
							while(start < length && strchr(" \t\r\n", bytes[start]))
								++start;
							if(start == length || bytes[start] != '[')
								return NSMakeRange(NSNotFound, 0);
							NSUInteger arrays = 1, cursor = start+1;
							while(cursor < length && arrays)
							{
								switch(bytes[cursor++])
								{
									case '[': ++arrays; break;
									case ']': --arrays; break;
									case '"': cursor = AfterJSONString(bytes, cursor-1, length); break;
								}
							}
							result = NSMakeRange(start, cursor-start);
						}
					}
				}
				index = end-1;
				break;
			}
		}
	}
	return result;
}

static BOOL WorkspaceError(NSError** error, NSString* description)
{
	if(error)
		*error = [NSError errorWithDomain:@"TextMate.ProjectWorkspace" code:1 userInfo:@{ NSLocalizedDescriptionKey: description }];
	return NO;
}

static NSString* WorkspacePath(NSString* value, NSURL* base)
{
	if(![value isKindOfClass:NSString.class] || value.length == 0 ||
	   [value rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound)
		return nil;
	NSString* absolute = value.isAbsolutePath ? value : [base.path stringByAppendingPathComponent:value];
	return absolute.stringByStandardizingPath.stringByResolvingSymlinksInPath;
}

static BOOL IsWorkspaceDirectory(NSString* path)
{
	BOOL directory = NO;
	return path && [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && directory;
}

@interface ProjectWorkspace ()
@property (nonatomic, readwrite) NSURL* URL;
@property (nonatomic) NSArray* entries;
@property (nonatomic) NSRange foldersRange;
@property (nonatomic) NSData* source;
@end

@implementation ProjectWorkspace
+ (instancetype)workspaceAtURL:(NSURL*)url error:(NSError**)error
{
	if(!url.isFileURL)
	{
		WorkspaceError(error, @"Choose a local workspace file.");
		return nil;
	}

	url = url.URLByStandardizingPath.URLByResolvingSymlinksInPath;
	NSData* source = [NSData dataWithContentsOfURL:url options:0 error:error];
	if(!source)
		return nil;

	NSData* json = ProjectJSONDataWithoutComments(source);
	id configuration = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
	NSRange range = [configuration isKindOfClass:NSDictionary.class] ? WorkspaceFoldersRange(json) : NSMakeRange(NSNotFound, 0);
	if(range.location == NSNotFound || ![configuration[@"folders"] isKindOfClass:NSArray.class])
	{
		WorkspaceError(error, @"The workspace file must contain a valid JSON object with a single folders array.");
		return nil;
	}

	ProjectWorkspace* workspace = [self new];
	workspace.URL = url;
	workspace.source = source;
	workspace.foldersRange = range;
	workspace.entries = configuration[@"folders"];
	return workspace;
}

+ (instancetype)createAtURL:(NSURL*)url folderPaths:(NSArray<NSString*>*)paths error:(NSError**)error
{
	if(!url.isFileURL)
	{
		WorkspaceError(error, @"Choose a local workspace file.");
		return nil;
	}
	ProjectWorkspace* workspace = [self new];
	workspace.URL = url.URLByStandardizingPath.URLByResolvingSymlinksInPath;
	workspace.entries = @[];
	NSArray* entries = [workspace entriesByAddingPaths:paths error:error];
	if(!entries)
		return nil;
	NSData* data = [NSJSONSerialization dataWithJSONObject:@{ @"folders": entries } options:NSJSONWritingPrettyPrinted|NSJSONWritingWithoutEscapingSlashes error:error];
	if(!data || ![data writeToURL:workspace.URL options:NSDataWritingWithoutOverwriting error:error])
		return nil;
	return [self workspaceAtURL:workspace.URL error:error];
}

- (NSString*)name
{
	return self.URL.URLByDeletingPathExtension.lastPathComponent;
}

- (NSArray<NSDictionary<NSString*, NSString*>*>*)folders
{
	NSMutableArray* folders = [NSMutableArray array];
	NSMutableSet* paths = [NSMutableSet set];
	for(id entry in self.entries)
	{
		if(![entry isKindOfClass:NSDictionary.class])
			continue;
		NSString* path = WorkspacePath(entry[@"path"], self.URL.URLByDeletingLastPathComponent);
		if(!path || [paths containsObject:path])
			continue;
		[paths addObject:path];
		NSString* name = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : nil;
		NSString* basename = path.lastPathComponent;
		[folders addObject:@{ @"path": path, @"name": name.length ? name : (basename.length ? basename : path) }];
	}
	return folders;
}

- (NSArray*)entriesByAddingPaths:(NSArray<NSString*>*)paths error:(NSError**)error
{
	NSURL* base = self.URL.URLByDeletingLastPathComponent;
	NSMutableArray* entries = [self.entries mutableCopy];
	NSMutableSet* existing = [NSMutableSet setWithArray:[self.folders valueForKey:@"path"]];
	for(NSString* value in paths)
	{
		NSString* path = WorkspacePath(value, base);
		if(!IsWorkspaceDirectory(path))
		{
			WorkspaceError(error, [NSString stringWithFormat:@"“%@” is not an available folder.", value]);
			return nil;
		}
		if(![existing containsObject:path])
		{
			[existing addObject:path];
			NSString* relative = [path isEqualToString:base.path] ? @"." : to_ns(path::relative_to(to_s(path), to_s(base.path)));
			[entries addObject:@{ @"path": relative }];
		}
	}
	return entries;
}

- (BOOL)writeEntries:(NSArray*)entries error:(NSError**)error
{
	ProjectWorkspace* latest = [ProjectWorkspace workspaceAtURL:self.URL error:error];
	if(!latest)
		return NO;
	if(![latest.entries isEqual:self.entries])
		return WorkspaceError(error, @"The workspace folders were changed on disk. Reopen the workspace before editing them.");
	if([entries isEqual:self.entries])
		return YES;

	NSData* encoded = [NSJSONSerialization dataWithJSONObject:entries options:NSJSONWritingPrettyPrinted|NSJSONWritingWithoutEscapingSlashes error:error];
	if(!encoded)
		return NO;

	NSMutableData* updated = [latest.source mutableCopy];
	[updated replaceBytesInRange:latest.foldersRange withBytes:encoded.bytes length:encoded.length];
	if(![updated writeToURL:self.URL options:NSDataWritingAtomic error:error])
		return NO;
	self.entries = entries;
	return YES;
}

- (BOOL)addFolderPaths:(NSArray<NSString*>*)paths error:(NSError**)error
{
	NSArray* entries = [self entriesByAddingPaths:paths error:error];
	return entries && [self writeEntries:entries error:error];
}

- (BOOL)removeFolderAtPath:(NSString*)path error:(NSError**)error
{
	NSURL* base = self.URL.URLByDeletingLastPathComponent;
	NSString* normalized = WorkspacePath(path, base);
	NSArray* entries = [self.entries filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id entry, NSDictionary* bindings){
		return ![entry isKindOfClass:NSDictionary.class] || ![normalized isEqualToString:WorkspacePath(entry[@"path"], base)];
	}]];
	return [self writeEntries:entries error:error];
}

- (NSString*)folderContainingPath:(NSString*)path
{
	NSString* absolute = [path isAbsolutePath] ? WorkspacePath(path, nil) : nil;
	if(!absolute)
		return nil;
	NSString* best = nil;
	for(NSDictionary* folder in self.folders)
	{
		NSString* root = folder[@"path"];
		if(root.length > best.length && ([root isEqualToString:@"/"] || path::is_child(to_s(absolute), to_s(root))))
			best = root;
	}
	return best;
}

- (NSString*)availableFolderPreferringPath:(NSString*)path
{
	NSString* first = nil;
	for(NSDictionary* folder in self.folders)
	{
		NSString* root = folder[@"path"];
		if(!IsWorkspaceDirectory(root))
			continue;
		if([path isEqualToString:root])
			return root;
		first = first ?: root;
	}
	return first;
}
@end
