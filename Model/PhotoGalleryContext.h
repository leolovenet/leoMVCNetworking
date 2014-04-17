#import <CoreData/CoreData.h>

// There's a one-to-one relationship between PhotoGallery and PhotoGalleryContext objects. 
// The reason why certain bits of state are stored here, rather than in PhotoGallery, is 
// so that managed objects, specifically the Photo objects, can get access to this state 
// easily (via their managedObjectContext property).

// 在 PhotoGallery 和 PhotoGalleryContext 对象之间的关系是 一对一的.
// 与状态相关的某些 bits 存储在这里,而不是 PhotoGallery 里, 这样 managed object,特别是 Photo objects,可以很方便容易的通过 managedObjectContext 对象的属性访问

@interface PhotoGalleryContext : NSManagedObjectContext
{
    NSString *      _galleryURLString;
    NSString *      _galleryCachePath;
}

- (id)initWithGalleryURLString:(NSString *)galleryURLString galleryCachePath:(NSString *)galleryCachePath;

@property (nonatomic, copy,   readonly ) NSString *     galleryURLString;
@property (nonatomic, copy,   readonly ) NSString *     galleryCachePath;       // path to gallery cache directory

// 路径示例: "/var/mobile/Applications/8181B390-29AC-4311-B18B-E0992F70D8DC/Library/Caches/Gallery418482044.875488997.gallery/Photos/"

@property (nonatomic, copy,   readonly ) NSString *     photosDirectoryPath;    // path to Photos directory within galleryCachePath


// Returns a mutable request that's configured to do an HTTP GET operation for a resources with the given path relative to the galleryURLString.
// If path is nil, returns a request for the galleryURLString resource itself.
// This can return fail (and return nil) if path is not nil and yet not a valid URL path.

// 把 path 路径和 galleryURLString 相关, 然后返回一个配置好了的  HTTP GET 的 NSMutableURLRequest 对象
// 如果参数 path 为 nil, 返回一个只有 galleryURLString 请求
// 如果 path 不是 nil ,也不是一个有效的 URL path, 返回 fail
- (NSMutableURLRequest *)requestToGetGalleryRelativeString:(NSString *)path;

@end
