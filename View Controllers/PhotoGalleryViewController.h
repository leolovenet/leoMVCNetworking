#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>

@class PhotoGallery;

@interface PhotoGalleryViewController : UITableViewController
{
    UIBarButtonItem *               _stopBarButtonItem;
    UIBarButtonItem *               _refreshBarButtonItem;
    UIBarButtonItem *               _fixedBarButtonItem;
    UIBarButtonItem *               _flexBarButtonItem;
    UIBarButtonItem *               _statusBarButtonItem;
    
    PhotoGallery *                  _photoGallery;
    NSFetchedResultsController *    _fetcher;
    NSDateFormatter *               _dateFormatter;
}

- (id)initWithPhotoGallery:(PhotoGallery *)photoGallery;
    // Creates a view controller to show the photos in the specified gallery. 
    //
    // IMPORTANT: photoGallery may be nil, in which case it simply displays 
    // a placeholder UI.

@property (nonatomic, retain, readwrite) PhotoGallery *     photoGallery;
    // The client can change the gallery being shown by setting this property.

@end