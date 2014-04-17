#import <UIKit/UIKit.h>

/*
    QImageScrollView is a simplified image scroller based to a large degree on the code 
    from the PhotoScroller sample.

    <http://developer.apple.com/iphone/library/samplecode/PhotoScroller/>
    
    It's simplified because a) it does not support rotation, b) it does not support tiling 
    (and uses a hackish workaround on old school hardware, where non-tiled performance is 
    way too slow), and c) it ignores the Retina display.  It's possible to fix all of these, 
    but such UI complexity is the scope of this /networking/ sample code. If you want to see 
    how to do this stuff properly, you should check out the PhotoScroller sample code and 
    WWDC 2010 Session 104 "Designing Apps with Scroll Views".

    <http://developer.apple.com/videos/wwdc/2010/>
*/

@interface QImageScrollView : UIScrollView
{
    UIImage *       _image;
    UIImageView *   _imageView;
    BOOL            _limitImageSize;
}

@property (nonatomic, retain, readwrite) UIImage * image;

@end
