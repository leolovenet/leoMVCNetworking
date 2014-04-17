#import <Foundation/Foundation.h>

@interface GalleryParserOperation : NSOperation
{
    NSData *                _data;
    NSError *               _error;
#if ! defined(NDEBUG)
    NSTimeInterval          _debugDelay;
    NSTimeInterval          _debugDelaySoFar;
#endif
    NSXMLParser *           _parser;
    NSMutableArray *        _mutableResults;
    NSMutableDictionary *   _itemProperties;
}

- (id)initWithData:(NSData *)data;
    // Configures the operation to parse the specified XML data.

// properties specified at init time

@property (copy,   readonly ) NSData *              data;

// properties that can be changed before starting the operation

#if ! defined(NDEBUG)
@property (assign, readwrite) NSTimeInterval        debugDelay;     // default is 0.0
#endif

// properties that are valid after the operation is finished

@property (copy,   readonly ) NSError *             error;
@property (copy,   readonly ) NSArray *             results;       // of NSDictionary, keys below

@end

// Keys for the results dictionaries.

extern NSString * kGalleryParserResultPhotoID;      // NSString
extern NSString * kGalleryParserResultName;         // NSString
extern NSString * kGalleryParserResultDate;         // NSDate
extern NSString * kGalleryParserResultPhotoPath;    // NSString
extern NSString * kGalleryParserResultThumbnailPath;// NSString
