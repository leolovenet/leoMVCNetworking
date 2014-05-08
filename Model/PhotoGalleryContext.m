#import "PhotoGalleryContext.h"
#import "NetworkManager.h"

@implementation PhotoGalleryContext

- (id)initWithGalleryURLString:(NSString *)galleryURLString galleryCachePath:(NSString *)galleryCachePath
{
    assert(galleryURLString != nil);
    assert(galleryCachePath != nil);
    
    self = [super init];
    if (self != nil) {
        self->_galleryURLString = [galleryURLString copy];
        self->_galleryCachePath = [galleryCachePath copy];
    }
    return self;
}

- (void)dealloc
{
    [self->_galleryCachePath release];
    [self->_galleryURLString release];
    [super dealloc];
}

@synthesize galleryURLString = _galleryURLString;
@synthesize galleryCachePath = _galleryCachePath;

- (NSString *)photosDirectoryPath
{
    // This comes from the PhotoGallery class.  I didn't really want to include it's header 
    // here (because we are 'lower' in the architecture than PhotoGallery)
    
    // I don't want the declaration in "PhotoGalleryContext.h" either (because our public clients have no need of this).
    // The best solution would be to have "PhotoGalleryPrivate.h", and put all the gallery cache structure strings into that file.
    // But having a whole separate file just to solve that problem seems like overkill.  So, for the moment, we just declare it extern here.
    extern NSString * kPhotosDirectoryName;
    // self.galleryCachePath e.g. :
    //           /var/mobile/Applications/8181B390-29AC-4311-B18B-E0992F70D8DC/Library/Caches/Gallery418482044.875488997.gallery
    return [self.galleryCachePath stringByAppendingPathComponent:kPhotosDirectoryName];
    
}


// 把 path 路径和 galleryURLString 相关, 然后返回一个配置好了的HTTP GET的 NSMutableURLRequest 对象
// 如果参数 path 为 nil, 返回一个只有 galleryURLString 请求
// 如果 path 不是 nil ,也不是一个有效的 URL path, 返回 fail
// 当 path 为畸形时, url 可能为 nil

// 在 model 层的Photo中 startThumbnailGet: 与 startPhotoGet: 中被调用
- (NSMutableURLRequest *)requestToGetGalleryRelativeString:(NSString *)path
{
    NSMutableURLRequest *   result = nil;
    NSURL *                 url;
    assert([NSThread isMainThread]);
    assert(self.galleryURLString != nil);
    
    // Construct the URL.
    // self.galleryURLString  e.g. -> { http://Leo-MacBook-Pro.local:8888/TestGallery/index.xml }
    url = [NSURL URLWithString:self.galleryURLString];
    assert(url != nil);
    
    if (path != nil) {
        // + (id)URLWithString:(NSString *)URLString relativeToURL:(NSURL *)baseURL
        // NSURL  的这个方法,允许我们创建一个 基于 baseURL 的 URL.
        // 比如, 如果你有一个在硬盘上的目录 URL (/结尾的路径) 和在目录里的文件名, 你就能为这个文件构建一个新的 URL ,靠着提供目录的 URL 作为 baseURL 和 文件名作为 URLString 部分.
        
        url = [NSURL URLWithString:path relativeToURL:url];
        // url  e.g. ->  { @"images/IMG_0125.JPG -- http://Leo-MacBook-Pro.local:8888/TestGallery/index.xml" }
        // url may be nil because, while galleryURLString is guaranteed to be a valid URL, path may not be.
        // 当 path 为畸形时, url 可能为 nil
    }
    
    // Call down to the network manager so that it can set up its stuff (notably the user agent string).
    if (url != nil) {
        result = [[NetworkManager sharedManager] requestToGetURL:url];
        // { URL: http://Leo-MacBook-Pro.local:8888/TestGallery/images/IMG_0125.JPG }
        assert(result != nil);
    }
    
    return result;
}

@end
