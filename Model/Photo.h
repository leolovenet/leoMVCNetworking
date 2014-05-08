#import <CoreData/CoreData.h>
#import <UIKit/UIKit.h>

// When trying to figure out Core Data issues, it's useful to know what photo ID a 
// particular Photo object corresponds to, even if Core Data has forgetten that 
// information (for example, after the object has been deleted, and hence turned 
// into a fault).  So, if you set MVCNETWORKING_KEEP_PHOTO_ID_BACKUP each Photo keeps 
// its own record of the photoID, outside of the scope of Core Data.

#if ! defined(MVCNETWORKING_KEEP_PHOTO_ID_BACKUP)
    #define MVCNETWORKING_KEEP_PHOTO_ID_BACKUP 0
#endif

extern const CGFloat kThumbnailSize;

@class Thumbnail;
@class RetryingHTTPOperation;
@class MakeThumbnailOperation;

@interface Photo : NSManagedObject  
{
    
#if MVCNETWORKING_KEEP_PHOTO_ID_BACKUP
    NSString *                  _photoIDBackup;
#endif
    
    UIImage *                   _thumbnailImage;
    BOOL                        _thumbnailImageIsPlaceholder;
    RetryingHTTPOperation *     _thumbnailGetOperation;
    MakeThumbnailOperation *    _thumbnailResizeOperation;
    RetryingHTTPOperation *     _photoGetOperation;
    NSString *                  _photoGetFilePath;
    NSUInteger                  _photoNeededAssertions; //一个标识数,表示此 Photo 对象的大图是否是在展示中
    NSError *                   _photoGetError;
}

// Creates a photo with the specified properties in the specified context.
// The properties dictionary is keyed by property names, in a KVC fashion.
+ (Photo *)insertNewPhotoWithProperties:(NSDictionary *)properties inManagedObjectContext:(NSManagedObjectContext *)managedObjectContext;


// Updates the photo with the specified properties.  This will update the various
// readonly properties listed below, triggering KVO notifications along the way.
- (void)updateWithProperties:(NSDictionary *)properties;

// 实例 13955766067916300168
@property (nonatomic, retain, readonly ) NSString *     photoID;                // immutable, unique ID for the photo within this database

// 在PhotoCell中被监控,如果值有变化会通知 PhotoCell 去更新UI
// 在PhotoDetailViewController中被监控,用于更改大图页面的 title
// observable, user-visible name of the photo
// 实例 "Thumbnail Not Found"
@property (nonatomic, retain, readonly ) NSString *     displayName;

// 在PhotoCell中被监控,如果值有变化会通知 PhotoCell 去更新UI
// observable, date associated with the photo
// 实例 "2010-08-16 02:46:33 +0000"
@property (nonatomic, retain, readonly ) NSDate *       date;


// observable, path of the photo file on disk, relative to the PhotoGalleryContext photosDirectoryPath, or nil if not downloaded
// 实例 "Photo-13955766067916300168-0.jpg"
@property (nonatomic, retain, readonly ) NSString *     localPhotoPath;

// observable, URL path of the photo, relative to the PhotoGalleryContext galleryURLString
// 实例 "images/IMG_0125.JPG"
@property (nonatomic, retain, readonly ) NSString *     remotePhotoPath;

// observable, URL path of the thumbnail, relative to the PhotoGalleryContext galleryURLString,
// 实例 "thumbnails/IMG_0125xxx.jpg"
@property (nonatomic, retain, readonly ) NSString *     remoteThumbnailPath;


// observable, pointer to the Thumbnail object, or nil if not downloaded.
// 为 Thumbnail 对象, 代表 core data 里的一个 thumbnail 对象,在 thumbnailCommitImageData 中赋值,或者从 core data 中初始化
// 默认 nil,实例: "0x374030 <x-coredata://04EE60A0-46D4-4F5E-89C2-BE7860B66C98/Thumbnail/p4>"
@property (nonatomic, retain, readonly ) Thumbnail *    thumbnail;


// 此值,为UIImage 对象,在PhotoCell中被监控,如果值有变化会通知 PhotoCell 去更新UI
// observable, returns a placeholder if the thumbnail isn't available yet.
@property (nonatomic, retain, readonly ) UIImage *      thumbnailImage;


// observable, returns nil if the photo isn't available yet
// 被 PhotoDetailViewController 类所监控,用于判断是否显示大图,或者 loading 信息
@property (nonatomic, retain, readonly ) UIImage *      photoImage;


// The Photo object does not download the full photo (that is, photoImage) unless someone wants to 
// display it.  Clients should register and unregister their interest in the full photo using these 
// methods.

- (void)assertPhotoNeeded;
- (void)deassertPhotoNeeded;

// Status properties for the photo download operation.  Note that photoGetError is only really 
// interesting if photoImage is nil (indicating that the photo hasn't been downloaded), 
// photoGetting is NO (indicating that the photo is not in the process of being downloaded), 
// -assertPhotoNeeded has been called (indicating that someone actually wants the photo). 
// In that case, photoGetError contains the error from the most recent photo get attempt.


// 被 PhotoDetailViewController 类所监控,用于判断是否显示大图,或者 loading 信息
@property (nonatomic, assign, readonly ) BOOL           photoGetting;           // observable

@property (nonatomic, copy,   readonly ) NSError *      photoGetError;          // observable

@end
