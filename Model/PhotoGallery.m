#import "PhotoGallery.h"
#import "Photo.h"
#import "PhotoGalleryContext.h"
#import "NetworkManager.h"
#import "RecursiveDeleteOperation.h"
#import "RetryingHTTPOperation.h"
#import "GalleryParserOperation.h"
#import "Logging.h"

@interface PhotoGallery ()

// read/write variants of public properties
@property (nonatomic, retain, readwrite) NSEntityDescription *      photoEntity;

// private properties
@property (nonatomic, assign, readonly ) NSUInteger                 sequenceNumber;
@property (nonatomic, retain, readwrite) PhotoGalleryContext *      galleryContext;

//当前 gallery 的 cache 目录.例如:"~/Library/Cache/Gallery419574630.724151015.gallery"
@property (nonatomic, copy,   readonly ) NSString *                 galleryCachePath;

@property (nonatomic, retain, readwrite) NSTimer *                  saveTimer;
@property (nonatomic, assign, readwrite) PhotoGallerySyncState      syncState;  //同步状态值
@property (nonatomic, retain, readwrite) RetryingHTTPOperation *    getOperation;
@property (nonatomic, retain, readwrite) GalleryParserOperation *   parserOperation;
@property (nonatomic, copy,   readwrite) NSDate *                   lastSyncDate;
@property (nonatomic, copy,   readwrite) NSError *                  lastSyncError;

// forward declarations
- (void)startParserOperationWithData:(NSData *)data;
- (void)commitParserResults:(NSArray *)latestResults;

@end

#pragma mark -
@implementation PhotoGallery

// These strings define the format of our gallery cache.  First up, kGalleryNameTemplate 
// and kGalleryExtension specify the name of the gallery cache directory itself.
static NSString * kGalleryNameTemplate = @"Gallery%.9f.%@";
static NSString * kGalleryExtension    = @"gallery";

// Then, within each gallery cache directory, there are the following items:
//
// o kInfoFileName is the name of a plist file within the gallery cache.  If this is missing, 
//   the gallery cache has been abandoned (and can be removed at the next startup time).
//
// o kDatabaseFileName is the name of the Core Data file that holds the Photo and Thumbnail 
//   model objects.
//
// o kPhotosDirectoryName is the name of the directory containing the actual photo files.
//   Note that this is shared with PhotoGalleryContext, which is why it's not "static".

static NSString * kInfoFileName        = @"GalleryInfo.plist";
static NSString * kDatabaseFileName    = @"Gallery.db";

// 注意 kPhotosDirectoryName 没有用 "static" 存储修饰符,因为在 PhotoGalleryContext.m 文件中声明了 "extern" 存储修饰符.
// 一般一个变量 只能有一个 存储修饰符. 这两个存储修饰符是互斥的,为什么呢?
// 这里 "static" means Internal Linkage, "extern" means External Linkage.
// [Internal Linkage] refers to everything only in scope of a translation unit (编译单元, 所谓编译单元( translation unit ) 基本上它是单一源码文件加上其所含入的头文件).
// [External Linkage] refers to things that exist beyond a particular translation unit. In other words, accessable through the whole program.
// So both are mutually exclusive (互相排斥的).
       NSString * kPhotosDirectoryName = @"Photos";

static NSString * galleryClearCacheKey = @"galleryClearCache";
// The gallery info file (kInfoFileName) contains a dictionary with just one property 
// currently defined, kInfoFileName, which is the URL string of the gallery's XML data.

static NSString * kGalleryInfoKeyGalleryURLString = @"gallerURLString";

@synthesize saveTimer = _saveTimer;
@synthesize galleryURLString = _galleryURLString;
@synthesize sequenceNumber   = _sequenceNumber;
@synthesize syncState = _syncState;
@synthesize getOperation     = _getOperation;
@synthesize parserOperation  = _parserOperation;
@synthesize lastSyncDate     = _lastSyncDate;
@synthesize galleryContext = _galleryContext;
@synthesize photoEntity = _photoEntity;
@synthesize lastSyncError = _lastSyncError;

#pragma mark - Class Methods
// Returns the path to the caches directory.
// This is a class method because it's used by [self applicationStartup]
// 查找本程序的 Caches 目录的绝对路径
+ (NSString *)cachesDirectoryPath
{
    NSString *      result;
    NSArray *       paths;

    result = nil;
    paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if ( (paths != nil) && ([paths count] != 0) ) {
        assert([[paths objectAtIndex:0] isKindOfClass:[NSString class]]);
        result = [paths objectAtIndex:0];
    }
    return result;
}

//删除 Caches/****.gallery/的GalleryInfo.plist 文件,这样 cache 目录就不会被使用了
+ (void)abandonGalleryCacheAtPath:(NSString *)galleryCachePath
{
    (void) [[NSFileManager defaultManager] removeItemAtPath:[galleryCachePath stringByAppendingPathComponent:kInfoFileName] error:NULL];
}

/*!
 *  在一个独立的低优先级线程里, 清理掉那些无用的或者过期的缓存目录(即,带.gallery后缀的文件名)
 */
+ (void)applicationStartup
/*
App 的 Library目录结构,每个 App 的 Library 都是独立的
 .Library
 ├── Caches
 │   ├── Gallery418203425.903194010.gallery
 │   │   ├── Gallery.db                  //sqlite 文件
 │   │   ├── Gallery.db-shm
 │   │   ├── Gallery.db-wal
 │   │   ├── GalleryInfo.plist
 │   │   └── Photos
 │   │       ├── Photo-13955766067916300168-0.jpg
 │   │       ├── Photo-16245101894383175045-0.jpg
 │   │       ├── Photo-3320466108841760573-0.jpg
 │   │       ├── Photo-3603534702205544874-0.jpg
 │   │       └── Photo-7294271919726091079-0.jpg
 │   ├── Gallery418283346.115673006.gallery
 │   │   ├── Gallery.db              //sqlite 文件
 │   │   ├── Gallery.db-shm
 │   │   ├── Gallery.db-wal
 │   │   ├── GalleryInfo.plist
 │   │   └── Photos
 │   ├── Gallery418283351.160021007.gallery
 │   │   ├── Gallery.db             //sqlite 文件
 │   │   ├── Gallery.db-shm
 │   │   ├── Gallery.db-wal
 │   │   ├── GalleryInfo.plist
 │   │   └── Photos
 │   ├── Gallery418283353.972082019.gallery
 │   │   ├── Gallery.db              //sqlite 文件
 │   │   ├── Gallery.db-shm
 │   │   ├── Gallery.db-wal
 │   │   ├── GalleryInfo.plist
 │   │   └── Photos
 │   ├── Snapshots
 │   │   └── com.apple.dts.MVCNetworking
 │   │       ├── Main
 │   │       │   ├── UIApplicationAutomaticSnapshotDefault-LandscapeLeft@2x.png
 │   │       │   └── UIApplicationAutomaticSnapshotDefault-Portrait@2x.png
 │   │       └── Main-downscaled
 │   │           ├── UIApplicationAutomaticSnapshotDefault-LandscapeLeft@2x.png
 │   │           └── UIApplicationAutomaticSnapshotDefault-Portrait@2x.png
 │   └── com.apple.dts.MVCNetworking
 │       ├── Cache.db    //sqlite 文件
 │       ├── Cache.db-shm
 │       ├── Cache.db-wal
 │       └── fsCachedData
 │           ├── 28EFBC76-CD5E-4591-8A07-85141C4AB77C  //这些是图片的缓存
 │           ├── 5C7E5144-25AC-4AB9-907F-5160C3A2387E
 │           ├── 5F418BCE-E951-48DC-B673-A89CE32DA490
 │           ├── 6148A093-6B54-4B1F-95C6-E7BC38A1F8F0
 │           ├── 625C2EEB-D82D-45F7-ADA6-0ED174F68E14
 │           ├── A68965B6-119B-4159-94E3-D0395B124E92
 │           ├── BD4331D4-D266-487B-B097-F047B654BDE1
 │           ├── CBCB25B7-316C-4C8F-B57B-DB4A445E05E1
 │           ├── E41BF802-2F3D-4711-8EA9-1295C46F6F24
 │           └── E5542D53-7312-4442-81C1-9680C36ACFD5
 └── Preferences
     ├── com.apple.PeoplePicker.plist               //选项配置文件
     └── com.apple.dts.MVCNetworking.plist

*/
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    assert(fileManager != nil);

    NSUserDefaults* userDefaults = [NSUserDefaults standardUserDefaults];
    assert(userDefaults != nil);
    
    //查找本程序的 Caches 目录的绝对路径 e.g. ~/Library/Caches/
    NSString* cachesDirectoryPath = [self cachesDirectoryPath];
    assert(cachesDirectoryPath != nil);

    // See if we've been asked to nuke all gallery caches.
    BOOL clearAllCaches = [userDefaults boolForKey:galleryClearCacheKey];
    if (clearAllCaches) {
        [[QLog log] logWithFormat:@"gallery clear cache"];
        
        [userDefaults removeObjectForKey:galleryClearCacheKey];
        [userDefaults synchronize];
    }

    // Walk the list of gallery caches looking for abandoned ones (or, if we're 
    // clearing all caches, do them all).  Add the targeted gallery caches 
    // to our list of things to delete.  Also, for any galleries that remain, 
    // put the path and the mod date in a list so that we can then find the 
    // oldest galleries and delete them.
    // 便利所有的 gallery caches 目录,寻找无用的(或者我们将要清除的缓存目录),然后记录下来路径.
    // 对于那些依然有效的缓存目录,同样记录下来,这样我们可以日后找到最老旧的缓存,然后删除他们.
    
    NSMutableArray*  deletableGalleryCachePaths = [NSMutableArray array]; //即将删除的缓存目录路径列表
    assert(deletableGalleryCachePaths != nil);
    
    //保存目录下的多有文件列表
    NSArray*  potentialGalleryCacheNames = [fileManager contentsOfDirectoryAtPath:cachesDirectoryPath error:NULL];
    assert(potentialGalleryCacheNames != nil);
    

    NSMutableArray* liveGalleryCachePathsAndDates = [NSMutableArray array];
    assert(liveGalleryCachePathsAndDates != nil);
    
    for (NSString * galleryCacheName in potentialGalleryCacheNames) {
        //那些带 .gallery 后缀的文件就是缓存目录
        if ([galleryCacheName hasSuffix:kGalleryExtension]) {
        
            NSString* galleryCachePath = [cachesDirectoryPath stringByAppendingPathComponent:galleryCacheName];
            assert(galleryCachePath != nil);

            NSString* galleryInfoFilePath = [galleryCachePath stringByAppendingPathComponent:kInfoFileName];
            assert(galleryInfoFilePath != nil);

            NSString* galleryDatabaseFilePath = [galleryCachePath stringByAppendingPathComponent:kDatabaseFileName];
            assert(galleryDatabaseFilePath != nil);

            //是否删除所有的缓存
            if (clearAllCaches) {
                [[QLog log] logWithFormat:@"gallery clear '%@'", galleryCacheName];
                (void)[fileManager removeItemAtPath:galleryInfoFilePath error:NULL];
                [deletableGalleryCachePaths addObject:galleryCachePath];
            } else if ( ! [fileManager fileExistsAtPath:galleryInfoFilePath]) { // 缓存目录不存在 GalleryInfo.plist 文件,则为无用缓存.
                [[QLog log] logWithFormat:@"gallery delete abandoned '%@'", galleryCacheName];
                [deletableGalleryCachePaths addObject:galleryCachePath];
            } else {
                // This gallery cache isn't abandoned. Get the modification date of its database.
                // If that fails, the gallery cache is toast, so just add it to the to-delete list.
                // If that succeeds, add a dictionary containing the gallery cache path and the 
                // modification date to the list of live gallery caches.
                
                // 如果这个缓存目录不是无效的. 那么得到它的数据库的修改时间.
                // 如果获取修改时间失败的话,那么这个缓存目录也是无效的,记录下来待会删掉.
                // 如果成功的话, 添加缓存目录路径到liveGalleryCachePathsAndDates,并记录最后修改时间
                
                NSDate* modDate = [[fileManager attributesOfItemAtPath:galleryDatabaseFilePath error:NULL] objectForKey:NSFileModificationDate];
                if (modDate == nil) {
                    [[QLog log] logWithFormat:@"gallery delete invalid '%@'", galleryCacheName];
                    [deletableGalleryCachePaths addObject:galleryCachePath];
                } else {
                    assert([modDate isKindOfClass:[NSDate class]]);
                    [liveGalleryCachePathsAndDates addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                        galleryCachePath,   @"path", 
                        modDate,            @"modDate", 
                        nil
                    ]];
                }
            }
        }
    }
    
    // See if we've exceeded our gallery cache limit, in which case we keep abandoning the oldest 
    // gallery cache until we're under that limit.

    // 目前我们还没有执行我们的 gallery cache 限制, 对缓存目录排序后, 删除那些多余的,最老的缓存.
    [liveGalleryCachePathsAndDates sortUsingDescriptors:[
                                                         NSArray arrayWithObject:[
                                                              [
                                                               [NSSortDescriptor alloc] initWithKey:@"modDate" ascending:YES
                                                              ]  autorelease
                                                          ]
                                                         ]];
    
    while ( [liveGalleryCachePathsAndDates count] > 3 ) {
        NSString * path = [[liveGalleryCachePathsAndDates objectAtIndex:0] objectForKey:@"path"];
        assert([path isKindOfClass:[NSString class]]);

        [[QLog log] logWithFormat:@"gallery abandon and delete '%@'", [path lastPathComponent]];

        // 删除 Caches/****.gallery/的GalleryInfo.plist 文件,这样 cache 目录就不会被使用了
        [self abandonGalleryCacheAtPath:path];
        [deletableGalleryCachePaths addObject:path];
        
        [liveGalleryCachePathsAndDates removeObjectAtIndex:0];
    }
    
    // Start an operation to delete the targeted gallery caches.  This happens on a 
    // thread so that it doesn't prevent the app starting up.  The app will 
    // ignore these gallery caches anyway, because we removed their gallery info files. 
    // Also, we don't monitor this operation for successful completion.  It 
    // just does its stuff and then goes away.  That means that we effectively 
    // leak the operation queue.  Not a big deal.  It also means that, if the 
    // app quits before the operation is done, it just gets killed.  That's 
    // OK too; the delete will pick up where it left off when the app is next 
    // relaunched.
    
    // 开启一个 operation 去删除那些无用的 gallery caches.
    // 这个operation 在一个独立的线程上执行,这样它就无法拖延程序的启动了.
    // 程序将要忽略掉那些我们记录下来的要删除的缓存目录,因为我们已经把目录里的 galleryInfo.plist文件了.
    // 并且,我们不监控这个操作是否顺利完成,它完成后会自动退出的. 就是说我们漏掉这个操作队列的其他处理.
    // 这并没有什么大不了的. 这意味着,如果 app 在删除操作没有完成以前就退出的话,这个操作就被杀死了.
    // 这也没有关系. 这个删除操作会在下次程序启动的时候再此运行的.

    if ( [deletableGalleryCachePaths count] != 0 ) {
        static NSOperationQueue *   sGalleryDeleteQueue;
        
        sGalleryDeleteQueue = [[NSOperationQueue alloc] init];
        assert(sGalleryDeleteQueue != nil);
        
        //递归删除掉 NSArry 里的目录路径
        RecursiveDeleteOperation * op = [[[RecursiveDeleteOperation alloc] initWithPaths:deletableGalleryCachePaths] autorelease];
        assert(op != nil);
        
        if ( [op respondsToSelector:@selector(setThreadPriority:)] ) {
            [op setThreadPriority:0.1]; // 我们把优先级设置的很低,以免抢占过多的资源
        }
        [sGalleryDeleteQueue addOperation:op];
    }
}

#pragma mark - designated initializer
- (id)initWithGalleryURLString:(NSString *)galleryURLString
{
    assert(galleryURLString != nil);
    
    // The initialisation method is very simple.  All of the heavy lifting is done in -start.
    // 初始化操作很简单, 所有的重量级的操作都在本类里的 start 方法里
    self = [super init];
    if (self != nil) {
        // 一个 static 变量,用于保存 这个是第几个 gallery 的请求,自程序开始运行从0开始计数.
        static NSUInteger sNextGallerySequenceNumber;  // 默认为0
        
        self->_galleryURLString = [galleryURLString copy];
        self->_sequenceNumber = sNextGallerySequenceNumber;
        sNextGallerySequenceNumber += 1;
        
        //添加一个监控,等到程序变为 active 后,调用 didBecomeActive: 方法
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        
        [[QLog log] logWithFormat:@"%s gallery %zu is %@",__PRETTY_FUNCTION__, (size_t) self->_sequenceNumber, galleryURLString];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];

    [self->_galleryURLString release];

    // We should have been stopped before being released, so these properties 
    // should be nil by the time -dealloc is called.
    assert(self->_galleryContext == nil);
    assert(self->_photoEntity == nil);
    assert(self->_saveTimer == nil);

    [self->_lastSyncDate release];
    [self->_lastSyncError release];
    [self->_standardDateFormatter release];

    // We should have been stopped before being released, so these properties 
    // should be nil by the time -dealloc is called.
    assert(self->_getOperation == nil);
    assert(self->_parserOperation == nil);

    [super dealloc];
}


// 根据 app 首选项决定是否重新同步 URL 请求
- (void)didBecomeActive:(NSNotification *)note
{
    #pragma unused(note)
    // Having the ability to sync on activate makes it easy to test various cases where 
    // you want to force a sync in a weird context (like when the PhotoDetailViewController 
    // is up).
    
    if ( [[NSUserDefaults standardUserDefaults] boolForKey:@"gallerySyncOnActivate"] ) {
        if (self.galleryContext != nil) {
            [self startSync];
        }
    }
}

#pragma mark * Core Data wrangling
//Foundation 框架提供的表示属性依赖的机制
+ (NSSet *)keyPathsForValuesAffectingManagedObjectContext
{
    return [NSSet setWithObject:@"galleryContext"];
}

- (NSManagedObjectContext *)managedObjectContext
{
    return self.galleryContext;
}


//为执行 executeFetchRequest 需要的 NSFetchRequest 对象,创建一个NSEntityDescription对象
//在下面的 - (NSFetchRequest *)photosFetchRequest 方法里调用,PhotoGalleryViewcontroller里startFetcher方法也会调用
- (NSEntityDescription *)photoEntity
{
    if (self->_photoEntity == nil) {
        assert(self.galleryContext != nil);
        self->_photoEntity = [[NSEntityDescription entityForName:@"Photo" inManagedObjectContext:self.galleryContext] retain];
        assert(self->_photoEntity != nil);
    }
    return self->_photoEntity;
}


/*!
 *  为执行 executeFetchRequest 返回一个 NSFetchRequest
 *
 *  Returns a fetch request that gets all of the photos in the database.
 */
- (NSFetchRequest *)photosFetchRequest
{
    NSFetchRequest *    fetchRequest;
    
    fetchRequest = [[[NSFetchRequest alloc] init] autorelease];
    assert(fetchRequest != nil);

    [fetchRequest setEntity:self.photoEntity];
    [fetchRequest setFetchBatchSize:20];
    
    return fetchRequest;
}

/*!
 *  查找可以使用的 ~/Library/Cache/xxx.gallery/ 作为 Cache 的目录,如果不存在就创建一个新的
 *
 *  @return 存在且可用的 gallery cache 的路径 类似 ~/Library/Cache/xxx.gallery/
 */
- (NSString *)galleryCachePathForOurGallery
    // Try to find the gallery cache for our gallery URL string.
{
    NSString *          result;
    NSFileManager *     fileManager;
    NSString *          cachesDirectoryPath;
    NSArray *           potentialGalleries;
    NSString *          galleryName;
    
    assert(self.galleryURLString != nil);
    
    fileManager = [NSFileManager defaultManager];
    assert(fileManager != nil);
    
    cachesDirectoryPath = [[self class] cachesDirectoryPath];
    assert(cachesDirectoryPath != nil);
    
    // First look through the caches directory for a gallery cache whose info file 
    // matches the gallery URL string we're looking for.
    // 罗列目录下所有文件.类似 ls 命令
    potentialGalleries = [fileManager contentsOfDirectoryAtPath:cachesDirectoryPath error:NULL];
    assert(potentialGalleries != nil);
    
    result = nil;
    for (galleryName in potentialGalleries) {
        // galleryName 为那些带 .gallery 结尾的目录
        if ([galleryName hasSuffix:kGalleryExtension]) {
            NSDictionary *  galleryInfo;
            NSString *      galleryInfoURLString;
            
            //读取 GalleryInfo.plist 文件的内容到字典文件中, 用到的方法是 dictionaryWithContentsOfFile:
            galleryInfo = [NSDictionary dictionaryWithContentsOfFile:[
                                     // ~/Lib/Cache/*****.gallery/GalleryInfo.plist
                                    [cachesDirectoryPath stringByAppendingPathComponent:galleryName]
                                    stringByAppendingPathComponent:kInfoFileName]
                           ];
            if (galleryInfo != nil) {
                galleryInfoURLString = [galleryInfo objectForKey:kGalleryInfoKeyGalleryURLString];
                // 如果文件保存的 URL 跟 self.galleryURLString 一样的话,这个 gallery cache 就可以用
                if ( [self.galleryURLString isEqual:galleryInfoURLString] ) {
                    result = [cachesDirectoryPath stringByAppendingPathComponent:galleryName];
                    break;
                }
            }
        }
    }
    
    // If we find nothing, create a new gallery cache and record it as belonging to the specified gallery URL string.
    // 如果上面没有发现 有用的  gallery cache 的话,我们就用指定的 gallery URL string 创建一个新的
    if (result == nil) {
        BOOL        success;

        galleryName = [NSString stringWithFormat:kGalleryNameTemplate, [NSDate timeIntervalSinceReferenceDate], kGalleryExtension];
        assert(galleryName != nil);
        
        result = [cachesDirectoryPath stringByAppendingPathComponent:galleryName];

        //创建目录
        success = [fileManager createDirectoryAtPath:result withIntermediateDirectories:NO attributes:NULL error:NULL];
        if (success) {
            NSDictionary *  galleryInfo;
            //创建用于 GalleryInfo.plist  文件的源数据字典
            galleryInfo = [NSDictionary dictionaryWithObjectsAndKeys:self.galleryURLString, kGalleryInfoKeyGalleryURLString, nil];
            assert(galleryInfo != nil);
            //保存 GalleryInfo.plist  ,使用的是 NSDictionary 的   writeToFile:atomically:  方法
            success = [galleryInfo writeToFile:[result stringByAppendingPathComponent:kInfoFileName] atomically:YES];
        }
        if ( ! success ) {
            result = nil;
        }

        [[QLog log] logWithFormat:@"gallery %zu created new '%@'", (size_t) self.sequenceNumber, galleryName];
    } else {
        assert(galleryName != nil);
        [[QLog log] logWithFormat:@"%s gallery %zu found existing '%@'",__PRETTY_FUNCTION__, (size_t) self.sequenceNumber, galleryName];
    }
    
    return result;
}

// Abandons the specified gallery cache directory.  We do this simply by removing the gallery info file.
// The directory will be deleted when the application is next launched.
// 调用本类的同名"类方法", 删除 Caches/****.gallery/的GalleryInfo.plist 文件, 这样下次 cache 目录就不会被使用了
- (void)abandonGalleryCacheAtPath:(NSString *)galleryCachePath
{
    assert(galleryCachePath != nil);

    [[QLog log] logWithFormat:@"gallery %zu abandon '%@'", (size_t) self.sequenceNumber, [galleryCachePath lastPathComponent]];
    
    [[self class] abandonGalleryCacheAtPath:galleryCachePath];
}


// 在下面的 setupGalleryContext 里初始化为: 当前 gallery 的 cache 目录的绝对路径.
//      cache目录的命名是在上面的方法 galleryCachePathForOurGallery 中订立的
//      例如:  @"~/Library/Cache/" + [NSString stringWithFormat:@"Gallery%.9f.%@", [NSDate timeIntervalSinceReferenceDate],@".gallery"]
//      ==>   @"~/Library/Cache/Gallery419574630.724151015.gallery"
- (NSString *)galleryCachePath
{
    assert(self.galleryContext != nil);
    return self.galleryContext.galleryCachePath;
}


#pragma mark - init galleryContext
// Attempt to start up the gallery cache for our gallery URL string, either by finding an existing
// cache or by creating one from scratch.  On success, self.galleryCachePath will point to that
// gallery cache and self.galleryContext will be the managed object context for the database  within the gallery cache.
// 尝试着要设置一个 gallery cache 为我们指定的 gallery URL.
// 或者查找现有的,或者从 scratch 中创建一个.
// 当成功后, self.galleryCachePath 会指向这个 gallery cache
// 而后伴随, self.galleryContext 将会成为这个 gallery cache 的 Managed Object Context
- (BOOL)setupGalleryContext
{
    BOOL                            success;
    NSError *                       error;
    NSFileManager *                 fileManager;
    NSString *                      galleryCachePath;
    NSString *                      photosDirectoryPath;
    BOOL                            isDir;
    NSURL *                         databaseURL;
    NSManagedObjectModel *          model;
    NSPersistentStoreCoordinator *  psc;

    assert(self.galleryURLString != nil);
    
    [[QLog log] logWithFormat:@"%s gallery %zu starting",__PRETTY_FUNCTION__, (size_t) self.sequenceNumber];  // self.sequenceNumber 初始化时为0,表示第几个  gallery 展示
    
    error = nil;
    
    fileManager = [NSFileManager defaultManager];
    assert(fileManager != nil);
    
    // Find the gallery cache directory for this gallery.
    // 查找可用的 ~/Library/Cache/****.gallery/ 作为 Cache 目录使用
    galleryCachePath = [self galleryCachePathForOurGallery];
    success = (galleryCachePath != nil);
    
    // Create the "~/Library/Cache/****.gallery/Photos/" directory if it doesn't already exist.
    if (success) {
        photosDirectoryPath = [galleryCachePath stringByAppendingPathComponent:kPhotosDirectoryName];
        assert(photosDirectoryPath != nil);
        
        //目录存在,并且是个目录才行,不然创建一个新的
        success = [fileManager fileExistsAtPath:photosDirectoryPath isDirectory:&isDir] && isDir;
        if ( ! success ) {
            // 创建  "~/Library/Cache/****.gallery/Photos/"
            success = [fileManager createDirectoryAtPath:photosDirectoryPath withIntermediateDirectories:NO attributes:NULL error:NULL];
        }
    }

    // Start up Core Data in the gallery directory.
    // 设置 NSManagedObjectModel 对象
    if (success) {
        NSString *      modelPath;
        modelPath = [[NSBundle bundleForClass:[self class]] pathForResource:@"Photos" ofType:@"mom"];
        assert(modelPath != nil);
        
        model = [[[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:modelPath]] autorelease];
        success = (model != nil);
    }
    
    
    //  设置 NSPersistentStoreCoordinator  对象
    if (success) {
        //    "~/Library/Cache/****.gallery/Gallery.db"
        databaseURL = [NSURL fileURLWithPath:[galleryCachePath stringByAppendingPathComponent:kDatabaseFileName]];
        assert(databaseURL != nil);

        psc = [[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model] autorelease];
        success = (psc != nil);
    }
    
    if (success) {
        success = [psc addPersistentStoreWithType:NSSQLiteStoreType 
                                    configuration:nil
                                              URL:databaseURL
                                          options:nil
                                            error:&error
                                                                        ] != nil;
        if (success) {
            error = nil;
        }
    }
    
    if (success) {
        PhotoGalleryContext *   context;
        
        // Everything has gone well, so we create a managed object context from our persistent 
        // store.  Note that we use a subclass of NSManagedObjectContext, PhotoGalleryContext, which 
        // carries along some state that the managed objects (specifically the Photo objects) need 
        // access to.
        context = [[[PhotoGalleryContext alloc] initWithGalleryURLString:self.galleryURLString galleryCachePath:galleryCachePath] autorelease];
        assert(context != nil);

        [context setPersistentStoreCoordinator:psc];

        // 在旧版本的代码中, 各种各样的分类,监控着我们的 photoGalleryContext 属性,当有改变时,他们很聪明的处理. 所以很重要的一点是,不要设置这个属性,直到所有的事情全部设置好,并运行起来.
        // 那种情况不再发生, 但是我们保持 configure-before-set 代码习惯,因为这个看起来很对.
        // In older versions of the code various folks observed our photoGalleryContext property 
        // and did clever things when it changed.  So it was important to not set that property 
        // until everything as fully up and running.  That no longer happens, but I've kept the
        // configure-before-set code because it seems like the right thing to do.
        self.galleryContext = context;

        // Subscribe to the context changed notification so that we can auto-save.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(contextChanged:)
                                                     name:NSManagedObjectContextObjectsDidChangeNotification
                                                   object:self.managedObjectContext];

        [[QLog log] logWithFormat:@"%s gallery %zu started '%@'",__PRETTY_FUNCTION__, (size_t) self.sequenceNumber, [self.galleryCachePath lastPathComponent]];
        
    } else {
        // Bad things happened.  Log the error and return NO.
        if (error == nil) {
            [[QLog log] logWithFormat:@"gallery %zu start error", (size_t) self.sequenceNumber];
        } else {
            [[QLog log] logWithFormat:@"gallery %zu start error %@", (size_t) self.sequenceNumber, error];
        }
        
        // Also, if we found or created a gallery cache but failed to start up in it, abandon it in 
        // the hope that our next attempt will work better.
        if (galleryCachePath != nil) {
            //该实例方法会调用"类同名方法", 删除 Caches/****.gallery/的GalleryInfo.plist 文件, 这样下次 cache 目录就不会被使用了
            [self abandonGalleryCacheAtPath:galleryCachePath];
        }
    }
    return success;
}


- (void)start
{
    BOOL   success;
    assert(self.galleryURLString != nil);
    
    // Try to start up.  If this fails, it abandons the gallery cache, so a retry 
    // on our part is warranted.
    success = [self setupGalleryContext];
    if ( ! success ) {
        success = [self setupGalleryContext];
    }
    
    // If all went well, start the syncing processing.  If not, the application is dead 
    // and we crash.
    if (success) {
        [self startSync];
    } else {
        abort();
    }
}



#pragma mark - save Core Data

- (void)save
{
    NSError *       error;
    error = nil;
    
    // Disable the auto-save timer.
    [self.saveTimer invalidate];
    self.saveTimer = nil;
    
    // Save.
    if ( (self.galleryContext != nil) && [self.galleryContext hasChanges] ) {
        BOOL success = [self.galleryContext save:&error];  // persist save the data to   "~/Library/Cache/****.gallery/Gallery.db"
        if (success) {
            error = nil;
        }
    }
    // Log the results.
    if (error == nil) {
        [[QLog log] logWithFormat:@"%s gallery %zu saved", __PRETTY_FUNCTION__ ,(size_t) self.sequenceNumber];
    } else {
        [[QLog log] logWithFormat:@"%s gallery %zu save error %@",__PRETTY_FUNCTION__, (size_t) self.sequenceNumber, error];
    }
}

#pragma mark - managed object context notification arrived
// Called when the managed object context changes (courtesy of the NSManagedObjectContextObjectsDidChangeNotification notification).
// We start an auto-save timer to fire in 5 seconds.  This means that rapid-fire changes don't cause a flood of saves.
- (void)contextChanged:(NSNotification *)note
{
    #pragma unused(note)
    if (self.saveTimer != nil) {
        [self.saveTimer invalidate];
    }
    self.saveTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(save) userInfo:nil repeats:NO];
}


/*
    Shuts down our access to the gallery cache.  We do this in two situations:
        o When the user switches gallery.
        o When the application terminates.
 
 // Called by the application delegate at -applicationDidEnterBackground: and
 // -applicationWillTerminate: time, respectively.  Note that it's safe, albeit(althought) a little
 // weird, to call -save and -stop even if you haven't called -start.

 
 */
- (void)stop
{
    [self stopSync];
    
    // Shut down the managed object context.
    
    if (self.galleryContext != nil) {

        // Shut down the auto save mechanism and then force a save.

        [[NSNotificationCenter defaultCenter] removeObserver:self name:NSManagedObjectContextObjectsDidChangeNotification object:self.galleryContext];
        
        [self save];
        
        self.photoEntity = nil;
        self.galleryContext = nil;
    }
    [[QLog log] logWithFormat:@"%s gallery %zu stopped",__PRETTY_FUNCTION__, (size_t) self.sequenceNumber];
}


//Foundation 框架提供的表示属性依赖的机制
+ (NSSet *)keyPathsForValuesAffectingSyncStatus
{
    return [NSSet setWithObjects:@"syncState", @"lastSyncError", @"standardDateFormatter", @"lastSyncDate", @"getOperation.retryStateClient", nil];
}


- (NSString *)syncStatus
{
    NSString *  result;
    
    if (self.lastSyncError == nil) {
        
        switch (self.syncState) {
            case kPhotoGallerySyncStateStopped: {
                if (self.lastSyncDate == nil) {
                    result = @"Not updated";
                } else {
                    result = [NSString stringWithFormat:@"Updated: %@", [self.standardDateFormatter stringFromDate:self.lastSyncDate]];
                }
            } break;
                
            default: {
                if ( (self.getOperation != nil) && (self.getOperation.retryStateClient == kRetryingHTTPOperationStateWaitingToRetry) ) {
                    result = @"Waiting for network";
                } else {
                    result = @"Updating…";
                }
            } break;
        }
        
    } else {
        
        if ([[self.lastSyncError domain] isEqual:NSCocoaErrorDomain] && [self.lastSyncError code] == NSUserCancelledError) {
            result = @"Update cancelled";
        } else {
            // At this point self.lastSyncError contains the actual error. 
            // However, we ignore that and return a very generic error status. 
            // Users don't understand "Connection reset by peer" anyway (-:
            result = @"Update failed";
        }
        
    }
    return result;
}


//Foundation 框架提供的表示属性依赖的机制
+ (NSSet *)keyPathsForValuesAffectingSyncing
{
    return [NSSet setWithObject:@"syncState"];
}


//关闭对 syncState 的自动 KVO 通知
+ (BOOL)automaticallyNotifiesObserversOfSyncState
{
    return NO;
}

// 操作是否在运行中
- (BOOL)isSyncing
{
    return (self->_syncState > kPhotoGallerySyncStateStopped);
}

- (void)setSyncState:(PhotoGallerySyncState)newValue
{
    if (newValue != self->_syncState) {
        BOOL    isSyncingChanged;
        
        isSyncingChanged = (self->_syncState > kPhotoGallerySyncStateStopped) != (newValue > kPhotoGallerySyncStateStopped);
        [self willChangeValueForKey:@"syncState"];
        if (isSyncingChanged) {
            [self willChangeValueForKey:@"syncing"];
        }
        self->_syncState = newValue;
        if (isSyncingChanged) {
            [self didChangeValueForKey:@"syncing"];
        }
        [self didChangeValueForKey:@"syncState"];
    }
}

// 代表一个格式化了的时间字符串,初始化为当前时间
- (NSDateFormatter *)standardDateFormatter
{
    if (self->_standardDateFormatter == nil) {
        self->_standardDateFormatter = [[NSDateFormatter alloc] init];
        assert(self->_standardDateFormatter != nil);
        
        [self->_standardDateFormatter setDateStyle:NSDateFormatterMediumStyle];
        [self->_standardDateFormatter setTimeStyle:NSDateFormatterMediumStyle];
        
        // Watch for changes in the locale and time zone so that we can update 
        // our date formatter accordingly.
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(updateStandardDateFormatter:)
                                                     name:NSCurrentLocaleDidChangeNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(updateStandardDateFormatter:)
                                                     name:NSSystemTimeZoneDidChangeNotification
                                                   object:nil];
    }
    
    return self->_standardDateFormatter;
}


// 当当前的 locale 改变后,或者 TimeZone 改变后,调用本方法.
// Called when either the current locale or the current time zone changes.
// We respond by applying the latest values to our date formatter.
- (void)updateStandardDateFormatter:(NSNotification *)note
{
    #pragma unused(note)
    NSDateFormatter *   df;
    
    df = self.standardDateFormatter;
    [self willChangeValueForKey:@"standardDateFormatter"];
    [df setLocale:[NSLocale currentLocale]];
    [df setTimeZone:[NSTimeZone localTimeZone]];
    [self didChangeValueForKey:@"standardDateFormatter"];
}



//关闭对 lastSyncError 的自动 KVO 通知
+ (BOOL)automaticallyNotifiesObserversOfLastSyncError
{
    return NO;
}

// We override this setter purely so that we can log the error.
// 设定在 Sync 中遇到的错误值
- (void)setLastSyncError:(NSError *)newValue
{
    assert([NSThread isMainThread]);

    if (newValue != nil) {
        [[QLog log] logWithFormat:@"gallery %zu sync error %@", (size_t) self.sequenceNumber, newValue];
    }

    if (newValue != self->_lastSyncError) {
        [self willChangeValueForKey:@"lastSyncError"];
        [self->_lastSyncError release];
        self->_lastSyncError = [newValue copy];
        [self didChangeValueForKey:@"lastSyncError"];
    }
}



#pragma mark  -  开始一个执行 Operation, 由 startSync/stopSync  调用
// Starts the HTTP operation to GET the photo gallery's XML.
- (void)startGetOperation
   {
    NSMutableURLRequest *   request;

    assert(self.syncState == kPhotoGallerySyncStateStopped);

    [[QLog log] logOption:kLogOptionSyncDetails withFormat:@"%s gallery %zu sync get start", __PRETTY_FUNCTION__ ,(size_t) self.sequenceNumber];

     // 为什么要把 requestToGetGalleryRelativeString 放到 galleryContext 类里呢?
     // readme 里面提到了,这是一个 NSMangedObjectContext 的子类. 它存放着关于 photo gallery 的信息.
     // 这允许管理对象,特别是 Photo 对象获得 gallery 状态,例如gallery的URL等信息.
    request = [self.galleryContext requestToGetGalleryRelativeString:nil];
    assert(request != nil);
    
    assert(self.getOperation == nil);
     // 创建 operation
    self.getOperation = [[[RetryingHTTPOperation alloc] initWithRequest:request] autorelease];
    assert(self.getOperation != nil);
    
    [self.getOperation setQueuePriority:NSOperationQueuePriorityNormal];
    self.getOperation.acceptableContentTypes = [NSSet setWithObjects:@"application/xml", @"text/xml", nil];
    
     // 添加 operation 到 OperationQueue
     // 目前都在 main thread 上面执行,直到下面,self.getOperation被添加到 NetworkManger 的网络管理队列(queueForNetworkManagement)后,
     // self.getOperation 立即在那个队列里执行.
    [[NetworkManager sharedManager] addNetworkManagementOperation:self.getOperation finishedTarget:self action:@selector(getOperationDone:)];
     // 等到下载资源操作完成以后(可能超时不成功),在主线程上调用本类的getOperationDone: 方法.
    self.syncState = kPhotoGallerySyncStateGetting;
}

/*!
 *  等待 GET URL 请求结束后执行,并开始分析返回的 XML 内容
 *  operation 可能超时不成功,需要判断. 如果请求成功,开始分析 XML 文件内容.
 *  Called when the HTTP operation to GET the photo gallery's XML completes.
 *  If all is well we start an operation to parse the XML.
 *
 *  @param operation 封装好了的,执行HTTP GET请求的 Operation
 */
- (void)getOperationDone:(RetryingHTTPOperation *)operation
{
    NSError *   error;
    
    //确保执行环境的正确
    assert([operation isKindOfClass:[RetryingHTTPOperation class]]);
    assert(operation == self.getOperation);
    assert(self.syncState == kPhotoGallerySyncStateGetting);
    
    [[QLog log] logOption:kLogOptionSyncDetails withFormat:@"%s gallery %zu sync listing done",__PRETTY_FUNCTION__, (size_t) self.sequenceNumber];
    
    error = operation.error;
    if (error != nil) { //请求有错误,没有成功.
        self.lastSyncError = error;
        self.syncState = kPhotoGallerySyncStateStopped;
    } else {
        if ([QLog log].isEnabled) {
            [[QLog log] logOption:kLogOptionNetworkData withFormat:@"receive %@", self.getOperation.responseContent];
        }
        
        //开始分析 URL请求返回的 XML 文件内容
        [self startParserOperationWithData:self.getOperation.responseContent];
    }
    self.getOperation = nil;
}


// Starts the operation to parse the gallery's XML.
// 创建 GalleryParserOperation operation 对象,并将此 operation 入列到 main thread 上执行
- (void)startParserOperationWithData:(NSData *)data
{
    assert(self.syncState == kPhotoGallerySyncStateGetting);

    [[QLog log] logOption:kLogOptionSyncDetails withFormat:@"%s gallery %zu sync parse start", __PRETTY_FUNCTION__, (size_t) self.sequenceNumber];

    assert(self.parserOperation == nil);
    
    // GalleryParserOperation 类为一个重写了 main 方法继承自 NSOperation 的子类, 将这个 operation 添加到 queue 后,当 main 方法返回时，这个NSOperation就结束了.
    // GalleryParserOperation 类会 copy 一份 data
    self.parserOperation = [[[GalleryParserOperation alloc] initWithData:data] autorelease];
    assert(self.parserOperation != nil);

    [self.parserOperation setQueuePriority:NSOperationQueuePriorityNormal];
    
    //入列,开始执行 main 方法, 添加到 NetworkManger 的CPU队列(queueForCPU)上执行,也就是在main thread 上面执行,指定回调函数parserOperationDone:
    [[NetworkManager sharedManager] addCPUOperation:self.parserOperation finishedTarget:self action:@selector(parserOperationDone:)];

    self.syncState = kPhotoGallerySyncStateParsing; // 改变动作状态为 Parsing
}


// Called when the operation to parse the gallery's XML completes.
// If all went well we commit the results to our database.

//在 main thread 上分析完网络下载的新 xml 文件后的回调函数, 结果保存在 operation.results 中,是把每个 xml 中 photo 元素属性组成的dictionary,存放到的一个 array.
- (void)parserOperationDone:(GalleryParserOperation *)operation
{
    assert([NSThread isMainThread]);
    assert([operation isKindOfClass:[GalleryParserOperation class]]);
    assert(operation == self.parserOperation);
    assert(self.syncState == kPhotoGallerySyncStateParsing);

    [[QLog log] logOption:kLogOptionSyncDetails withFormat:@"%s gallery %zu sync parse done",__PRETTY_FUNCTION__, (size_t) self.sequenceNumber];
    
    if (operation.error != nil) { // 分析 xml 有错误
        self.lastSyncError = operation.error;
        self.syncState = kPhotoGallerySyncStateStopped;
    } else {
        [self commitParserResults:operation.results];
        
        assert(self.lastSyncError == nil);
        self.lastSyncDate = [NSDate date];  //保存一个时间戳
        self.syncState = kPhotoGallerySyncStateStopped;
        [[QLog log] logWithFormat:@"%s gallery %zu sync success",__PRETTY_FUNCTION__, (size_t) self.sequenceNumber];
    }

    self.parserOperation = nil;
}


#if ! defined(NDEBUG)
// In debug mode we call this routine after committing our changes to the database
// to verify that the database looks reasonable.
// 在调试模式下,我们可以在提交了对数据库的修改后,调用这个方法用于效验数据.
- (void)checkDatabase
{
    NSFetchRequest *    photosFetchRequest;
    NSFetchRequest *    thumbnailsFetchRequest;
    NSArray *           allPhotos;
    NSMutableSet *      remainingThumbnails;
    Photo *             photo;
    Thumbnail *         thumbnail;
    
    assert(self.galleryContext != nil);
    
    // Get all of the photos and all of the thumbnails.
    
    photosFetchRequest = [self photosFetchRequest];
    assert(photosFetchRequest != nil);

    allPhotos = [self.galleryContext executeFetchRequest:photosFetchRequest error:NULL];
    assert(allPhotos != nil);

    thumbnailsFetchRequest = [[[NSFetchRequest alloc] init] autorelease];
    assert(thumbnailsFetchRequest != nil);

    [thumbnailsFetchRequest setEntity:[NSEntityDescription entityForName:@"Thumbnail" inManagedObjectContext:self.galleryContext]];
    [thumbnailsFetchRequest setFetchBatchSize:20];
    
    remainingThumbnails = [NSMutableSet setWithArray:[self.galleryContext executeFetchRequest:thumbnailsFetchRequest error:NULL]];
    assert(remainingThumbnails != nil);
    
    // Check that ever photo has a thumbnail (and also remove that thumbnail 
    // from the remainingThumbnails set).
    
    for (photo in allPhotos) {        
        assert([photo isKindOfClass:[Photo class]]);
        
        thumbnail = photo.thumbnail;
        if (thumbnail != nil) {
            if ([remainingThumbnails containsObject:thumbnail]) {
                [remainingThumbnails removeObject:thumbnail];
            } else {
                NSLog(@"*** photo %@ has no thumbnail", photo.photoID);
            }
        }
    }
    
    // Check that there are no orphaned thumbnails (thumbnails that aren't attached to 
    // a photo).
    
    for (thumbnail in remainingThumbnails) {
        NSLog(@"*** thumbnail %@ orphaned", thumbnail);
    }
}
#endif


/*!
   网络下载的 xml 文件分析完后,提交由每个 Photo 元素(以字典形式保存)组成 Array 结果到这个函数
 
   本函数检查 core data 中是否存在这个 photo:
        如果有存在就更新为最新的properties.
        如果没有存在,就创建一个新的 Photo 对象
 
   如果在 core data 中存在的 photo 没有在新的 xml 文件中存在,那么将它从 core data 中删除
 
   Commits the results of parsing our the gallery's XML to the Core Data database.
 
 *  @param parserResults
 */
- (void)commitParserResults:(NSArray *)parserResults
{
    NSError *           error;
    NSDate *            syncDate;

    syncDate = [NSDate date]; //当前的时间戳
    assert(syncDate != nil);

    // Start by getting all of the photos that we currently have in the database.
    // 我们当前 在数据库里 已经有的所有 photos
    NSArray *           knownPhotos;    // of Photo
    knownPhotos = [self.galleryContext executeFetchRequest:[self photosFetchRequest] error:&error];
    assert(knownPhotos != nil);
    
    if (knownPhotos != nil) { // 有错误返回 nil,没有错误,但是没有匹配的,返回空 array
        
        // For each photo found in the XML, get the corresponding Photo object (based on the photoID).
        // If there is one, update it based on the new properties from the XML (this may cause the photo to get new thumbnail
        // and photo images, and trigger significant(important) UI updates).
        // If there isn't an existing photo, create one based on the properties from the XML.

        
        // Create photosToRemove, which starts out as a set of all the photos we know about.
        // As we refresh each existing photo, we remove it from this set.
        // Any photos left over are no longer present in the XML, and we remove them.
        // 任何存在与Core Data 中,但是不再存在于 XML 中的,删除他们.
        NSMutableSet *  photosToRemove;
        photosToRemove = [NSMutableSet setWithArray:knownPhotos]; // 默认是初始化所有的在 Core Data 中的 Photo 对象,都标记为删除,除非新获取的 xml 中包含此 photoID
        assert(photosToRemove != nil);
        
        // Create photoIDToKnownPhotos, which is a map from photoID to photo.
        // We use this to quickly determine if a photo with a specific photoID currently exists.
        
        // 存在与 Core Data 中, 基于 Photo 元素的属性 ID ,和该 ID 属性对应的 Photo 对象 map 组成的 Dictionary
        NSMutableDictionary *   photoIDToKnownPhotos;
        photoIDToKnownPhotos = [NSMutableDictionary dictionary];
        assert(photoIDToKnownPhotos != nil);
        
        Photo *   knownPhoto;
        for (knownPhoto in knownPhotos) {
            assert([knownPhoto isKindOfClass:[Photo class]]);
            
            [photoIDToKnownPhotos setObject:knownPhoto forKey:knownPhoto.photoID];
        }
        
        
        // Finally, create parserIDs, which is set of all the photoIDs that have come in  from the XML.
        // We use this to detect duplicate photoIDs in the incoming XML.
        // It would be bad to have two photos with the same ID.
        
        //将用于保存从网络 XML 中获得的 PhotoID, PhotoID 不能有重复的,所以采用 Set 数据格式.
        NSMutableSet *  parserIDs = [NSMutableSet set];
        assert(parserIDs != nil);
        
        // Iterate through the incoming XML results, processing each one in turn.
        // 轮询处理我们从网络下载的 photo 元素组成的数组 parserResults  (其中每个 photo 元素是由其属性以及包含的 image子标签属性,组成的dictionary 数据结构)
        for (NSDictionary * parserResult in parserResults) {
            NSString *  photoID;
                        
            photoID  = [parserResult objectForKey:kGalleryParserResultPhotoID];
            assert([photoID isKindOfClass:[NSString class]]);
            
            // Check for duplicates.
            if ([parserIDs containsObject:photoID]) { // 是否是重复的photoID对象
                [[QLog log] logOption:kLogOptionSyncDetails withFormat:@"gallery %zu sync duplicate photo %@", (size_t) self.sequenceNumber, photoID];
            } else {
                
                [parserIDs addObject:photoID];
            
                // Build a properties dictionary, used by both the create and update code paths.
                NSDictionary *  properties;
                properties = [NSDictionary dictionaryWithObjectsAndKeys:
                    photoID,                                                        @"photoID",
                    [parserResult objectForKey:kGalleryParserResultName],           @"displayName", 
                    [parserResult objectForKey:kGalleryParserResultDate],           @"date", 
                    [parserResult objectForKey:kGalleryParserResultPhotoPath],      @"remotePhotoPath", 
                    [parserResult objectForKey:kGalleryParserResultThumbnailPath],  @"remoteThumbnailPath", 
                    nil
                ];
                assert(properties != nil);
            
                // See whether we know about this specific photoID.
                // 检查从网络中获取的此 Photo,是否已经存在于从 Core Data 获取 Photo 对象中
                knownPhoto = [photoIDToKnownPhotos objectForKey:photoID];
                
                if (knownPhoto != nil) {//已经在 core Data
                    
                    // Yes.  Give the photo a chance to update itself from the incoming properties.
                    [[QLog log] logOption:kLogOptionSyncDetails withFormat:@"%s gallery %zu sync refresh %@",__PRETTY_FUNCTION__, (size_t) self.sequenceNumber, photoID];
                    [photosToRemove removeObject:knownPhoto]; // 已经存在的话,就不用删除此对象了
                    
                    [knownPhoto updateWithProperties:properties]; // 更新此 Photo 对象的属性
                    
                } else {
                    // No.  Create a new photo with the specified properties.
                    // 没有存在 Core Data ,那么创建一个新的
                    
                    [[QLog log] logOption:kLogOptionSyncDetails withFormat:@"gallery %zu sync create %@", (size_t) self.sequenceNumber, photoID];
                    
                    
                    //这将导致将新的 Photo 对象插入到 self.galleryContext 中,稍后会得到 KVO 的通知,而调用 save 函数,保存数据.
                    knownPhoto = [Photo insertNewPhotoWithProperties:properties inManagedObjectContext:self.galleryContext];
                    
                    assert(knownPhoto != nil);
                    assert(knownPhoto.photoID        != nil);
                    assert(knownPhoto.localPhotoPath == nil);
                    assert(knownPhoto.thumbnail      == nil);
                    
                    [photoIDToKnownPhotos setObject:knownPhoto forKey:knownPhoto.photoID];
                }
            }
        }

        // Remove any photos that are no longer present in the XML.
        // 删除所有存在与 Core Data 中,但是已经不存在于新获取的 XML 中的 Photo 对象
        for (knownPhoto in photosToRemove) {
            [[QLog log] logOption:kLogOptionSyncDetails withFormat:@"gallery %zu sync delete %@", (size_t) self.sequenceNumber, knownPhoto.photoID];
            [self.galleryContext deleteObject:knownPhoto]; //从 core data 中删除
        }
    }
    
    #if ! defined(NDEBUG)
        [self checkDatabase];
    #endif
}


// Force a sync to start right now.  Does nothing if a sync is already in progress.
- (void)startSync
{
    if ( ! self.isSyncing ) {
        //类型为 PhotoGallerySyncState 默认初始化就为 kPhotoGallerySyncStateStopped, 检测 self.syncState 是否为默认值
        if (self.syncState == kPhotoGallerySyncStateStopped) {
            [[QLog log] logWithFormat:@"%s gallery %zu sync start",__PRETTY_FUNCTION__, (size_t) self.sequenceNumber];
            assert(self.getOperation == nil);
            self.lastSyncError = nil;
            
            // Starts the HTTP operation to GET the photo gallery's XML.
            [self startGetOperation];
        }
    }
}

// Force a sync to stop right now.  Does nothing if a no sync is in progress.
- (void)stopSync
{
    if (self.isSyncing) {
         // getOperation 在 startGetOperation 方法中被初始化为RetryingHTTPOperation的一个对象,然后加入到 NetworkMangeer 的网络管理队列(queueForNetworkManagement)
        if (self.getOperation != nil) {
            [[NetworkManager sharedManager] cancelOperation:self.getOperation];
            self.getOperation = nil;
        }
        // parserOperation 在 startParserOperationWithData 方法中被初始化为GalleryParserOperation的一个对象,然后加入到 NetworkMangeer 的CPU操作队列(queueForCPU)
        if (self.parserOperation) {
            [[NetworkManager sharedManager] cancelOperation:self.parserOperation];
            self.parserOperation = nil;
        }
        
        self.lastSyncError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
        self.syncState = kPhotoGallerySyncStateStopped;  //恢复状态值
        
        [[QLog log] logWithFormat:@"%s gallery %zu sync stopped",__PRETTY_FUNCTION__, (size_t) self.sequenceNumber];
    }

}

@end
