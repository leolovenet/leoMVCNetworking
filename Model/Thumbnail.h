#import <CoreData/CoreData.h>

// In contrast to the Photo class, the Thumbnail class is entirely passive. 
// It's just a dumb container for the thumbnail data.
//
// Keep in mind that, by default, managed object properties are retained, not 
// copied, so clients of Thumbnail must be careful if they assign potentially 
// mutable data to the imageData property.

@class Photo;

@interface Thumbnail :  NSManagedObject  

@property (nonatomic, retain, readwrite) NSData *   imageData;      // holds a PNG representation of the thumbnail
@property (nonatomic, retain, readwrite) Photo *    photo;          // a pointer back to the owning photo

@end
