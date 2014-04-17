#import <UIKit/UIKit.h>

@interface QLogViewer : UITableViewController
{
    int                 _logEntriesDummy;
    UIActionSheet *     _actionSheet;
    UIAlertView *       _alertView;
}

- (void)presentModallyOn:(UIViewController *)controller animated:(BOOL)animated;
    // Present the view controller modally on the specified view controller.

@end
