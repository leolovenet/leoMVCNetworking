#import <UIKit/UIKit.h>

@protocol SetupViewControllerDelegate;

@interface SetupViewController : UITableViewController
{
    id<SetupViewControllerDelegate>     _delegate;
    NSMutableArray *                    _choices;
    BOOL                                _choicesDirty;
    NSUInteger                          _choiceIndex;
    NSString *                          _otherChoice;
    UITextField *                       _activeTextField;
}

+ (void)resetChoices;
    // Resets the list of choices back to their default values.  Called on application 
    // startup if the user enables the appropriate setting.

- (id)initWithGalleryURLString:(NSString *)galleryURLString;
    // galleryURLString may be nil, implying that no gallery is currently selected.

@property (nonatomic, assign, readwrite) id<SetupViewControllerDelegate> delegate;

- (void)presentModallyOn:(UIViewController *)parent animated:(BOOL)animated;

@end

#pragma mark - protocal  SetupViewControllerDelegate

@protocol SetupViewControllerDelegate <NSObject>

@required

- (void)setupViewController:(SetupViewController *)controller didChooseString:(NSString *)string;
    // string may be empty, to indicate no gallery

- (void)setupViewControllerDidCancel:(SetupViewController *)controller;

@end
    