#import <UIKit/UIKit.h>

@class PhotoGallery;
@class PhotoGalleryViewController;

@interface AppDelegate : NSObject
{
	UIWindow *                      _window;
	UINavigationController *        _navController;

    NSString *                      _galleryURLString;
    PhotoGallery *                  _photoGallery;
    PhotoGalleryViewController *    _photoGalleryViewController;
}

@property (nonatomic, retain) IBOutlet UIWindow *               window;
@property (nonatomic, retain) IBOutlet UINavigationController * navController;

@end
