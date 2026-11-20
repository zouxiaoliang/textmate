#import "Preferences.h"

extern NSNotificationName const MenuShortcutsDidChangeNotification;

// Capture menu defaults and apply saved shortcuts after the application menu is built.
void ApplyMenuShortcutPreferences (void);

@interface ShortcutsPreferences : NSViewController <PreferencesPaneProtocol>
@property (nonatomic, readonly) NSImage* toolbarItemImage;
@end
