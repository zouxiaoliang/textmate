#import <OakFilterList/OakChooser.h>

NSArray<NSDictionary<NSString*, NSString*>*>* OakFavoriteProjectEntries();

@interface FavoriteChooser : OakChooser
@property (class, readonly) FavoriteChooser* sharedInstance;
@end
