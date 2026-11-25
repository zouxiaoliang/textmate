#import "MenuBuilder.h"

NSMenuItem* MBCreateMenuItem (MBMenuItem const& item)
{
	NSMenuItem* menuItem;
	if(item.title && !item.separator)
			menuItem = [[NSMenuItem alloc] initWithTitle:item.title action:item.action keyEquivalent:item.keyEquivalent];
	else	menuItem = [NSMenuItem separatorItem];

	menuItem.keyEquivalentModifierMask = item.modifierFlags;
	menuItem.tag                       = item.tag;
	menuItem.target                    = item.target;
	menuItem.alternate                 = item.alternate;
	menuItem.enabled                   = item.enabled;
	menuItem.hidden                    = item.hidden;
	menuItem.indentationLevel          = item.indent;
	menuItem.state                     = item.state;
	menuItem.representedObject         = item.representedObject;

	if(item.hidden && (![item.keyEquivalent isEqualToString:@""] || item.key))
		menuItem.allowsKeyEquivalentWhenHidden = YES;

	if(item.key)
		menuItem.keyEquivalent = [NSString stringWithFormat:@"%C", item.key];

	if(item.submenu.size() > 0 || item.systemMenu != MBMenuTypeRegular || item.delegate || item.submenuRef)
	{
		NSMenu* submenu = MBCreateMenu(item.submenu, [[NSMenu alloc] initWithTitle:item.title]);
		submenu.delegate = item.delegate;
		menuItem.submenu = submenu;

		switch(item.systemMenu)
		{
			case MBMenuTypeServices:   NSApp.servicesMenu                       = submenu; break;
			case MBMenuTypeFont:       NSFontManager.sharedFontManager.fontMenu = submenu; break;
			case MBMenuTypeWindows:    NSApp.windowsMenu                        = submenu; break;
			case MBMenuTypeHelp:       NSApp.helpMenu                           = submenu; break;

			case MBMenuTypeOpenRecent:
				if([submenu respondsToSelector:@selector(_setMenuName:)])
					[submenu performSelector:@selector(_setMenuName:) withObject:@"NSRecentDocumentsMenu"];
			break;
		}

		if(item.submenuRef)
			*item.submenuRef = submenu;
	}

	if(item.ref)
		*item.ref = menuItem;

	return menuItem;
}

NSMenu* MBCreateMenu (MBMenu const& items, NSMenu* existingMenu)
{
	NSMenu* menu = existingMenu ?: [[NSMenu alloc] initWithTitle:@"AMainMenu"];
	for(auto const& item : items)
		[menu addItem:MBCreateMenuItem(item)];
	return menu;
}

BOOL MBPerformRunMenuKeyEquivalent (NSMenu* menu, NSEvent* event)
{
	NSString* key = event.charactersIgnoringModifiers;
	if(key.length != 1 || [key characterAtIndex:0] < NSF1FunctionKey || [key characterAtIndex:0] > NSF35FunctionKey)
		return NO;

	NSMenu* run = [menu itemWithTitle:@"Run"].submenu;
	NSUInteger mask = NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption;
	NSUInteger modifiers = event.modifierFlags & mask;
	for(NSMenuItem* item in run.itemArray)
	{
		if(![item.keyEquivalent isEqualToString:key] || (item.keyEquivalentModifierMask & mask) != modifiers)
			continue;
		if(![NSApp targetForAction:item.action to:item.target from:item])
			return NO;
		[run update];
		if(item.enabled)
			[NSApp sendAction:item.action to:item.target from:item];
		return YES;
	}
	return NO;
}
