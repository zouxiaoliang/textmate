#import "ShortcutsPreferences.h"
#import <OakAppKit/NSMenuItem Additions.h>
#import <OakAppKit/OakKeyEquivalentView.h>
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <OakFoundation/NSString Additions.h>
#import <ns/ns.h>

static NSString* const kMenuShortcutsDefaultsKey = @"MenuShortcuts";
NSNotificationName const MenuShortcutsDidChangeNotification = @"MenuShortcutsDidChangeNotification";

@interface MenuShortcut : NSObject
@property (nonatomic) NSString* identifier;
@property (nonatomic) NSString* title;
@property (nonatomic) NSString* defaultEventString;
@property (nonatomic) NSString* eventString;
@property (nonatomic) NSString* defaultKey;
@property (nonatomic) NSEventModifierFlags defaultModifiers;
@property (nonatomic, weak) NSMenuItem* menuItem;
@end

@implementation MenuShortcut
@end

@interface MenuShortcutStore : NSObject
@property (nonatomic) NSArray<MenuShortcut*>* shortcuts;
@property (nonatomic) NSMutableDictionary<NSString*, NSString*>* overrides;
@end

@implementation MenuShortcutStore
+ (instancetype)sharedStore
{
	static MenuShortcutStore* store;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ store = [MenuShortcutStore new]; });
	return store;
}

- (void)collectMenu:(NSMenu*)menu path:(NSString*)path into:(NSMutableArray<MenuShortcut*>*)result
{
	for(NSMenuItem* item in menu.itemArray)
	{
		if(item.isSeparatorItem || item.title.length == 0)
			continue;
		NSString* title = path.length ? [NSString stringWithFormat:@"%@ › %@", path, item.title] : item.title;
		if(item.hasSubmenu)
		{
			// Services, recent documents, windows, and bundle menus are populated dynamically.
			if(item.submenu.delegate == nil && item.submenu != NSApp.servicesMenu &&
			   item.submenu != NSApp.windowsMenu && item.submenu != NSApp.helpMenu &&
			   ![item.title isEqualToString:@"Open Recent"])
				[self collectMenu:item.submenu path:title into:result];
		}
		else if(item.action && path.length)
		{
			MenuShortcut* shortcut = [MenuShortcut new];
			// Use the position and action, since menu titles may change during validation.
			shortcut.identifier = [NSString stringWithFormat:@"%@:%ld:%@", path, (long)[menu indexOfItem:item], NSStringFromSelector(item.action)];
			shortcut.title = title;
			shortcut.menuItem = item;
			shortcut.defaultKey = item.keyEquivalent;
			shortcut.defaultModifiers = item.keyEquivalentModifierMask;
			NSString* key = item.keyEquivalent;
			NSEventModifierFlags modifiers = item.keyEquivalentModifierMask;
			if(key.length == 1 && [key characterAtIndex:0] >= 'A' && [key characterAtIndex:0] <= 'Z')
			{
				key = key.lowercaseString;
				modifiers |= NSEventModifierFlagShift;
			}
			shortcut.defaultEventString = item.keyEquivalent.length ?
				[NSString stringWithCxxString:ns::normalize_event_string(ns::create_event_string(key, modifiers))] : @"";
			[result addObject:shortcut];
		}
	}
}

- (void)loadIfNeeded
{
	if(self.shortcuts || !NSApp.mainMenu)
		return;
	NSMutableArray* shortcuts = [NSMutableArray array];
	[self collectMenu:NSApp.mainMenu path:@"" into:shortcuts];
	self.shortcuts = shortcuts;
	NSDictionary* saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kMenuShortcutsDefaultsKey];
	self.overrides = [NSMutableDictionary dictionary];
	for(MenuShortcut* shortcut in self.shortcuts)
	{
		id value = saved[shortcut.identifier];
		if([value isKindOfClass:NSString.class])
			self.overrides[shortcut.identifier] = value;
		shortcut.eventString = self.overrides[shortcut.identifier] ?: shortcut.defaultEventString;
		[self applyShortcut:shortcut];
	}
	[NSNotificationCenter.defaultCenter postNotificationName:MenuShortcutsDidChangeNotification object:nil];
}

- (void)applyShortcut:(MenuShortcut*)shortcut
{
	if([shortcut.eventString isEqualToString:shortcut.defaultEventString])
	{
		shortcut.menuItem.keyEquivalent = shortcut.defaultKey;
		shortcut.menuItem.keyEquivalentModifierMask = shortcut.defaultModifiers;
	}
	else
		[shortcut.menuItem setKeyEquivalentCxxString:shortcut.eventString.length ? ns::normalize_event_string(to_s(shortcut.eventString)) : std::string()];
}

- (NSString*)conflictForEventString:(NSString*)eventString excluding:(MenuShortcut*)shortcut
{
	if(!eventString.length)
		return nil;
	std::string const normalized = ns::normalize_event_string(to_s(eventString));
	for(MenuShortcut* other in self.shortcuts)
	{
		if(other != shortcut && other.eventString.length && ns::normalize_event_string(to_s(other.eventString)) == normalized)
			return other.title;
	}
	return nil;
}

- (void)setEventString:(NSString*)eventString forShortcut:(MenuShortcut*)shortcut
{
	shortcut.eventString = eventString ?: @"";
	if([shortcut.eventString isEqualToString:shortcut.defaultEventString])
		[self.overrides removeObjectForKey:shortcut.identifier];
	else
		self.overrides[shortcut.identifier] = shortcut.eventString;
	[NSUserDefaults.standardUserDefaults setObject:self.overrides forKey:kMenuShortcutsDefaultsKey];
	[self applyShortcut:shortcut];
	[NSNotificationCenter.defaultCenter postNotificationName:MenuShortcutsDidChangeNotification object:nil];
}
@end

void ApplyMenuShortcutPreferences (void)
{
	[[MenuShortcutStore sharedStore] loadIfNeeded];
}

@class ShortcutsPreferences;
@interface MenuShortcutRecorder : OakKeyEquivalentView
@property (nonatomic) MenuShortcut* shortcut;
@property (nonatomic, weak) ShortcutsPreferences* preferences;
- (void)displayEventString:(NSString*)eventString;
@end

@interface MenuShortcutResetButton : NSButton
@property (nonatomic) MenuShortcut* shortcut;
@end

@implementation MenuShortcutResetButton
@end

@interface ShortcutsPreferences () <NSSearchFieldDelegate>
@property (nonatomic) NSStackView* rows;
@property (nonatomic) NSTextField* statusLabel;
- (void)changeShortcut:(MenuShortcut*)shortcut toEventString:(NSString*)eventString recorder:(MenuShortcutRecorder*)recorder;
@end

@implementation MenuShortcutRecorder
- (void)displayEventString:(NSString*)eventString
{
	[super setEventString:eventString];
}

- (void)setEventString:(NSString*)eventString
{
	if(!self.shortcut)
	{
		[super setEventString:eventString];
		return;
	}
	[self.preferences changeShortcut:self.shortcut toEventString:eventString recorder:self];
}
@end

@implementation ShortcutsPreferences
- (NSImage*)toolbarItemImage { return PreferencesToolbarImage(@"keyboard", @"Shortcuts", nil); }

- (id)init
{
	if(self = [self initWithNibName:nil bundle:nil])
	{
		self.identifier = @"Shortcuts";
		self.title = @"Shortcuts";
	}
	return self;
}

- (void)changeShortcut:(MenuShortcut*)shortcut toEventString:(NSString*)eventString recorder:(MenuShortcutRecorder*)recorder
{
	NSString* value = eventString.length ? [NSString stringWithCxxString:ns::normalize_event_string(to_s(eventString))] : @"";
	// A plain character shortcut would intercept normal typing in an editor.
	if(value.length && [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"@^~"]].location == NSNotFound &&
	   [value characterAtIndex:value.length - 1] < NSF1FunctionKey)
	{
		self.statusLabel.stringValue = @"Use Command, Control, Option, or a function key.";
		[recorder displayEventString:shortcut.eventString];
		return;
	}
	NSString* conflict = [[MenuShortcutStore sharedStore] conflictForEventString:value excluding:shortcut];
	if(conflict)
	{
		self.statusLabel.stringValue = [NSString stringWithFormat:@"Already used by %@.", conflict];
		[recorder displayEventString:shortcut.eventString];
		return;
	}
	self.statusLabel.stringValue = @"Click to record, press Delete to clear, or Reset to restore the default.";
	[[MenuShortcutStore sharedStore] setEventString:value forShortcut:shortcut];
	[recorder displayEventString:shortcut.eventString];
}

- (void)restoreDefault:(MenuShortcutResetButton*)button
{
	MenuShortcut* shortcut = button.shortcut;
	[[MenuShortcutStore sharedStore] setEventString:shortcut.defaultEventString forShortcut:shortcut];
	for(NSView* row in self.rows.arrangedSubviews)
	{
		for(NSView* view in row.subviews)
			if([view isKindOfClass:MenuShortcutRecorder.class] && ((MenuShortcutRecorder*)view).shortcut == shortcut)
				[(MenuShortcutRecorder*)view displayEventString:shortcut.eventString];
	}
	self.statusLabel.stringValue = @"Default shortcut restored.";
}

- (void)controlTextDidChange:(NSNotification*)notification
{
	NSString* query = [((NSSearchField*)notification.object).stringValue lowercaseString];
	for(NSView* row in self.rows.arrangedSubviews)
	{
		NSTextField* label = (NSTextField*)row.subviews.firstObject;
		row.hidden = query.length && [label.stringValue.lowercaseString rangeOfString:query].location == NSNotFound;
	}
}

- (void)loadView
{
	[[MenuShortcutStore sharedStore] loadIfNeeded];
	NSSearchField* search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
	search.placeholderString = @"Search menu commands";
	search.delegate = self;

	self.rows = [NSStackView stackViewWithViews:@[]];
	self.rows.orientation = NSUserInterfaceLayoutOrientationVertical;
	self.rows.alignment = NSLayoutAttributeLeading;
	self.rows.spacing = 6;
	self.rows.edgeInsets = NSEdgeInsetsMake(10, 12, 10, 12);

	for(MenuShortcut* shortcut in [MenuShortcutStore sharedStore].shortcuts)
	{
		NSTextField* label = [NSTextField labelWithString:shortcut.title];
		label.lineBreakMode = NSLineBreakByTruncatingMiddle;
		[label.widthAnchor constraintEqualToConstant:350].active = YES;
		MenuShortcutRecorder* recorder = [[MenuShortcutRecorder alloc] initWithFrame:NSZeroRect];
		recorder.preferences = self;
		recorder.shortcut = shortcut;
		[recorder displayEventString:shortcut.eventString];
		[recorder.widthAnchor constraintEqualToConstant:115].active = YES;
		MenuShortcutResetButton* reset = [MenuShortcutResetButton buttonWithTitle:@"Reset" target:self action:@selector(restoreDefault:)];
		reset.bezelStyle = NSBezelStyleRounded;
		reset.controlSize = NSControlSizeSmall;
		reset.shortcut = shortcut;
		NSStackView* row = [NSStackView stackViewWithViews:@[ label, recorder, reset ]];
		row.spacing = 10;
		row.alignment = NSLayoutAttributeCenterY;
		[self.rows addArrangedSubview:row];
	}

	NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	scroll.hasVerticalScroller = YES;
	scroll.borderType = NSBezelBorder;
	scroll.documentView = self.rows;
	self.rows.translatesAutoresizingMaskIntoConstraints = NO;
	[self.rows.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor].active = YES;

	self.statusLabel = [NSTextField labelWithString:@"Click to record, press Delete to clear, or Reset to restore the default."];
	self.statusLabel.textColor = NSColor.secondaryLabelColor;
	NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 650, 460)];
	for(NSView* child in @[ search, scroll, self.statusLabel ])
	{
		child.translatesAutoresizingMaskIntoConstraints = NO;
		[view addSubview:child];
		[child.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:16].active = YES;
		[child.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-16].active = YES;
	}
	[search.topAnchor constraintEqualToAnchor:view.topAnchor constant:16].active = YES;
	[scroll.topAnchor constraintEqualToAnchor:search.bottomAnchor constant:12].active = YES;
	[self.statusLabel.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:10].active = YES;
	[self.statusLabel.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-16].active = YES;
	self.view = view;
}
@end
