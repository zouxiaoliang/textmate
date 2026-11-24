#include <oak/misc.h>

@class OFBHeaderView;
@class OFBActionsView;

@interface FileBrowserView : NSView
@property (nonatomic) OFBHeaderView*  headerView;
@property (nonatomic) NSOutlineView*  outlineView;
@property (nonatomic) OFBActionsView* actionsView;
@property (nonatomic) BOOL folderCollapsed;
@property (nonatomic, copy) void (^folderCollapseDidChange)(void);
@end
