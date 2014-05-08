#import <UIKit/UIKit.h>

@class Photo;

@interface PhotoCell : UITableViewCell
{
    Photo *             _photo;
    NSDateFormatter *   _dateFormatter;
}

- (id)initWithReuseIdentifier:(NSString *)reuseIdentifier;

@property (nonatomic, retain, readwrite) Photo *            photo;


// IMPORTANT: dateFormatter is /retain/, not /copy/, because we want to share the same 
// date formatter object between all our cells.
@property (nonatomic, retain, readwrite) NSDateFormatter *  dateFormatter;

@end
