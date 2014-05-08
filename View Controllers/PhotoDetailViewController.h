#import <UIKit/UIKit.h>

@class Photo;
@class PhotoGallery;
@class QImageScrollView;

@interface PhotoDetailViewController : UIViewController
{
    QImageScrollView *          _scrollView;
    UILabel *                   _loadingLabel;
    
    Photo *                     _photo;
    PhotoGallery *              _photoGallery;
}

@property (nonatomic, retain, readwrite) IBOutlet QImageScrollView *        scrollView;
@property (nonatomic, retain, readwrite) IBOutlet UILabel *                 loadingLabel;

@property (nonatomic, retain, readonly) Photo *         photo;
@property (nonatomic, retain, readonly) PhotoGallery *  photoGallery;

- (id)initWithPhoto:(Photo *)photo photoGallery:(PhotoGallery *)photoGallery;

@end
