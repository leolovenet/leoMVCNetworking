
#import "Photo.h"
#import "Thumbnail.h"
#import "PhotoGalleryContext.h"
#import "MakeThumbnailOperation.h"
#import "NetworkManager.h"
#import "RetryingHTTPOperation.h"
#import "QHTTPOperation.h"
#import "Logging.h"

// After downloading a thumbnail this code automatically reduces the image to a square 
// that's kThumbnailSize x kThumbnailSize.  This is not exactly elegant (what if some 
// other client wanted a different thumbnail size?), but it is very convenient.  It 
// means we can store the data for the reduced thumbnail image in the database, making 
// it very quick to access.  It also means the photo reduce operation is done by this 
// code, right next to the photo get operation.
//
// Ideally you would have a one-to-many relationship between Photo and Thumbnail objects, 
// and the thumbnail would record its own size.  That would allow you to keep thumbnails 
// around for many different clients simultaneously.  I considered that option but decided 
// that it was too complex for this sample.

const CGFloat kThumbnailSize = 60.0f;

@interface Photo ()

// read/write versions of public properties

// IMPORTANT: The default implementation of a managed object property setter does not copy the incoming value.
// We could fix this by writing our own setters, but that's a pain.
// Instead, we take care to only assign values that are immutable, or to copy the values ourself.
// We can do this because the properties are readonly to our external clients.

@property (nonatomic, retain, readwrite) NSString *         photoID;                //实例 13955766067916300168
@property (nonatomic, retain, readwrite) NSString *         displayName;            //实例 "Thumbnail Not Found"
@property (nonatomic, retain, readwrite) NSDate *           date;                   //实例 "2010-08-16 02:46:33 +0000"
@property (nonatomic, retain, readwrite) NSString *         localPhotoPath;         //默认 nil,实例 "Photo-13955766067916300168-0.jpg"
@property (nonatomic, retain, readwrite) NSString *         remotePhotoPath;        //实例 "images/IMG_0125.JPG"
@property (nonatomic, retain, readwrite) NSString *         remoteThumbnailPath;    //实例 "thumbnails/IMG_0125xxx.jpg"
@property (nonatomic, retain, readwrite) Thumbnail *        thumbnail;          //默认 nil,实例: "0x374030 <x-coredata://04EE60A0-46D4-4F5E-89C2-BE7860B66C98/Thumbnail/p4>"
@property (nonatomic, copy,   readwrite) NSError *          photoGetError;          //

// private properties
@property (nonatomic, retain, readonly ) PhotoGalleryContext *      photoGalleryContext;
@property (nonatomic, retain, readwrite) RetryingHTTPOperation *    thumbnailGetOperation;
@property (nonatomic, retain, readwrite) MakeThumbnailOperation *   thumbnailResizeOperation;
@property (nonatomic, retain, readwrite) RetryingHTTPOperation *    photoGetOperation;
@property (nonatomic, copy,   readwrite) NSString *                 photoGetFilePath;
@property (nonatomic, assign, readwrite) BOOL                       thumbnailImageIsPlaceholder;


// forward declarations
- (void)updateThumbnail;
- (void)updatePhoto;

- (void)thumbnailCommitImage:(UIImage *)image isPlaceholder:(BOOL)isPlaceholder;
- (void)thumbnailCommitImageData:(UIImage *)image;

@end


/*
    本类继承自 NSManagedObject, 可以被存入,或提取自 , core data.
         // 本类实例在初次初始化时,没有从网络获取 thumbnail 的数据,在 PhotoCell 初次请求 thumbnailImage 属性时,
         // 会先返回一个 PlaceHolder, 并启用一个异步网络请求去加载服务器的thnubnail
         // 如果请求成功,会 resize 后,返回真正的 thunbnail
         // 如果请求失败,返回一个请求失败的 placeholder.
*/


@implementation Photo

@dynamic photoID;
@dynamic displayName;
@dynamic date;
@dynamic localPhotoPath;
@dynamic remotePhotoPath;
@dynamic remoteThumbnailPath;
@dynamic thumbnail;

@synthesize thumbnailGetOperation       = _thumbnailGetOperation;
@synthesize thumbnailResizeOperation    = _thumbnailResizeOperation;
@synthesize thumbnailImageIsPlaceholder = _thumbnailImageIsPlaceholder;  //一个开关标识,代表现在展示 thumbnail 的图片是不是 placeholder
@synthesize photoGetOperation           = _photoGetOperation;
@synthesize photoGetFilePath            = _photoGetFilePath; // 代表下载的大图,暂时存储在临时目录下的路径.
@synthesize photoGetError               = _photoGetError;

// 此方法在 PhotoGallery.m 中的 commitParserResults 方法中被调用.
// 由新下载的 xml 文件中得到的 photo 信息,构建一个 photo 对象,并把它存入到 core data 中.
// properties 的构成,查看PhotoGallery.m 中的 commitParserResults 方法中的定义.
+ (Photo *)insertNewPhotoWithProperties:(NSDictionary *)properties inManagedObjectContext:(NSManagedObjectContext *)managedObjectContext
{
    assert(properties != nil);
    assert( [[properties objectForKey:@"photoID"] isKindOfClass:[NSString class]] );
    assert( [[properties objectForKey:@"displayName"] isKindOfClass:[NSString class]] );
    assert( [[properties objectForKey:@"date"] isKindOfClass:[NSDate class]] );//保存 photo 的时间信息的对象
    assert( [[properties objectForKey:@"remotePhotoPath"] isKindOfClass:[NSString class]] );
    assert( [[properties objectForKey:@"remoteThumbnailPath"] isKindOfClass:[NSString class]] );
    assert(managedObjectContext != nil);

    //执行插入数据到 core data
    Photo *     result;
    result = (Photo *) [NSEntityDescription insertNewObjectForEntityForName:@"Photo" inManagedObjectContext:managedObjectContext];
    if (result != nil) {
        assert([result isKindOfClass:[Photo class]]);
        
        result.photoID = [[[properties objectForKey:@"photoID"] copy] autorelease];
        assert(result.photoID != nil);
        
#if MVCNETWORKING_KEEP_PHOTO_ID_BACKUP
        result->_photoIDBackup = [result.photoID copy];
#endif
        result.displayName         = [[[properties objectForKey:@"displayName"] copy] autorelease];
        result.date                = [[[properties objectForKey:@"date"] copy] autorelease];
        result.remotePhotoPath     = [[[properties objectForKey:@"remotePhotoPath"] copy] autorelease];
        result.remoteThumbnailPath = [[[properties objectForKey:@"remoteThumbnailPath"] copy] autorelease];
    }
    return result;
}


#if MVCNETWORKING_KEEP_PHOTO_ID_BACKUP
// In the debug build we maintain _photoIDBackup to assist with debugging.
- (id)initWithEntity:(NSEntityDescription *)entity insertIntoManagedObjectContext:(NSManagedObjectContext *)context
{
    self = [super initWithEntity:entity insertIntoManagedObjectContext:context];
    if (self != nil) {
        self->_photoIDBackup = [self.photoID copy];
    }
    return self;
}
#endif

- (void)dealloc
{
    
#if MVCNETWORKING_KEEP_PHOTO_ID_BACKUP
    [self->_photoIDBackup release];
#endif
 
    [self->_thumbnailImage release];
    assert(self->_thumbnailGetOperation == nil);            // As far as I can tell there are only two ways for these objects to get deallocated, 
    assert(self->_thumbnailResizeOperation == nil);         // namely, the object being deleted and the entire managed object context going away 
    assert(self->_photoGetOperation == nil);                // (which turns the object into a fault).  In both cases -stop runs, which shuts down 
    assert(self->_photoGetFilePath == nil);                 // this stuff.  But the asserts are here, just to be sure.
    [self->_photoGetError release];
    [super dealloc];
}

// 此方法在 PhotoGallery.m 中的 commitParserResults 方法中被调用.
// 本方法的作用为,将此 Photo 对象的属性更新为最新的从网络下载的 xml 中定义的值
- (void)updateWithProperties:(NSDictionary *)properties
{
    assert( [self.photoID isEqual:[properties objectForKey:@"photoID"]] );
    assert( [[properties objectForKey:@"displayName"] isKindOfClass:[NSString class]] );
    assert( [[properties objectForKey:@"date"] isKindOfClass:[NSDate class]] );
    assert( [[properties objectForKey:@"remotePhotoPath"] isKindOfClass:[NSString class]] );
    assert( [[properties objectForKey:@"remoteThumbnailPath"] isKindOfClass:[NSString class]] );

    if ( ! [self.displayName isEqual:[properties objectForKey:@"displayName"]] ) {
        self.displayName = [[[properties objectForKey:@"displayName"] copy] autorelease];
    }
    
    BOOL    thumbnailNeedsUpdate;
    BOOL    photoNeedsUpdate;
    thumbnailNeedsUpdate = NO;
    photoNeedsUpdate     = NO;
    
    // Look at the date and the various remote paths and decide what needs updating.
    
    if ( ! [self.date isEqual:[properties objectForKey:@"date"]] ) {
        self.date = [[[properties objectForKey:@"date"] copy] autorelease];
        thumbnailNeedsUpdate = YES;
        photoNeedsUpdate     = YES;
    }
    if ( ! [self.remotePhotoPath isEqual:[properties objectForKey:@"remotePhotoPath"]] ) {
        self.remotePhotoPath = [[[properties objectForKey:@"remotePhotoPath"] copy] autorelease];
        photoNeedsUpdate     = YES;
    }
    if ( ! [self.remoteThumbnailPath isEqual:[properties objectForKey:@"remoteThumbnailPath"]] ) {
        self.remoteThumbnailPath = [[[properties objectForKey:@"remoteThumbnailPath"] copy] autorelease];
        thumbnailNeedsUpdate = YES;
    }

    // Do the updates.    
    if (thumbnailNeedsUpdate) {
        [self updateThumbnail];
    }
    if (photoNeedsUpdate) {
        [self updatePhoto];
    }
}


// managedObjectContext 为在注册本类实例时添加上的.即在本类 insertNewPhotoWithProperties:inManagedObjectContext: 中添加.
- (PhotoGalleryContext *)photoGalleryContext
{
    PhotoGalleryContext *   result;
    result = (PhotoGalleryContext *) [self managedObjectContext];
    assert( [result isKindOfClass:[PhotoGalleryContext class]] );
    
    return result;
}



// Stops all async activity on the object.
- (void)stop
{
    BOOL    didSomething;
    
    // If we're currently fetching the thumbnail, cancel that.
    
    didSomething = [self stopThumbnail];
    if (didSomething) {
        [[QLog log] logWithFormat:@"photo %@ thumbnail get stopped", self.photoID];
    }
    
    // If we're currently fetching the photo, cancel that.

    if (self.photoGetOperation != nil) {
        [[NetworkManager sharedManager] cancelOperation:self.photoGetOperation];
        self.photoGetOperation = nil;
        if (self.photoGetFilePath != nil) {
            (void) [[NSFileManager defaultManager] removeItemAtPath:self.photoGetFilePath error:NULL];
            self.photoGetFilePath = nil;
        }
        [[QLog log] logWithFormat:@"photo %@ photo get stopped", self.photoID];
    }
}

- (void)prepareForDeletion
    // We have to override prepareForDeletion in order to get rid of the photo 
    // file.  We take the opportunity to stop any async operations at the 
    // same time.  We'll get a second bite of that cherry in -willTurnIntoFault, 
    // but we might as well do it now.
{
    BOOL    success;
    
    [[QLog log] logWithFormat:@"photo %@ deleted", self.photoID];

    // Stop any asynchronous operations.
    
    [self stop];
    
    // Delete the photo file if it exists on disk.
    
    if (self.localPhotoPath != nil) {
        success = [[NSFileManager defaultManager]
                   removeItemAtPath:[self.photoGalleryContext.photosDirectoryPath stringByAppendingPathComponent:self.localPhotoPath]
                   error:NULL];
        
        assert(success);
    }
    
    [super prepareForDeletion];
}

- (void)willTurnIntoFault
    // There are three common reasons for turning into a fault:
    // 
    // o Core Data has decided we're uninteresting, and is reclaiming our memory.
    // o We're in the process of being deleted.
    // o The managed object context itself is going away.
    //
    // Regardless of the reason, if we turn into a fault we can any async 
    // operations on the object.  This is especially important in the last 
    // case, where Core Data can't satisfy any fault requests (and, unlike in 
    // the delete case, we didn't get a chance to stop our async operations in 
    // -prepareForDelete).
{
    [self stop];
    [super willTurnIntoFault];
}


#pragma mark - Thumbnails

// Starts the HTTP operation to GET the photo's thumbnail.
- (void)startThumbnailGet
{
    assert(self.remoteThumbnailPath != nil);
    assert(self.thumbnailGetOperation == nil);
    assert(self.thumbnailResizeOperation == nil);
   
    NSURLRequest * request = [self.photoGalleryContext requestToGetGalleryRelativeString:self.remoteThumbnailPath];
    if (request == nil) {    
        [[QLog log] logWithFormat:@"%s photo %@ thumbnail get bad path '%@'",__PRETTY_FUNCTION__, self.photoID, self.remoteThumbnailPath];
        [self thumbnailCommitImage:nil isPlaceholder:YES];  //构造 NSURLRequest 对象失败,设置Placeholder图像.
    } else {
        self.thumbnailGetOperation = [[[RetryingHTTPOperation alloc] initWithRequest:request] autorelease];
        assert(self.thumbnailGetOperation != nil);
        
        [self.thumbnailGetOperation setQueuePriority:NSOperationQueuePriorityLow];
        self.thumbnailGetOperation.acceptableContentTypes = [NSSet setWithObjects:@"image/jpeg", @"image/png", nil];

        [[QLog log] logWithFormat:@"%s photo %@ thumbnail get start '%@'",__PRETTY_FUNCTION__, self.photoID, self.remoteThumbnailPath];
        
        
        //对thumbnailGetOperation 的 hasHadRetryableFailure 属性添加一个监控.在第一次获取失败后,启用一个新的placehoder图片(Placeholder-Deferred.png),说明在重新获取图片.
        [self.thumbnailGetOperation addObserver:self forKeyPath:@"hasHadRetryableFailure" options:0 context:&self->_thumbnailImage];
        
        //添加到 Runloop,并当完成 opertaion 后调用回调函数
        [[NetworkManager sharedManager] addNetworkManagementOperation:self.thumbnailGetOperation finishedTarget:self action:@selector(thumbnailGetDone:)];
    }
}

// 停止get Thumbnail 或 resize Thumbnail 操作, 并清理相关属性变量.
// 返回YES,表示进行了取消get或resize操作,返回NO,表示压根就不用进行取消操作
- (BOOL)stopThumbnail
{
    BOOL    didSomething;
    
    didSomething = NO;
    if (self.thumbnailGetOperation != nil) { //网络获取 thumbnail 操作可以被取消
        
        //在 startThumbnailGet 中添加了对 RetryingHTTPOperation 类的此属性监控,用于展示一个新的 thumbnail placeholder deferred 图片,提示用户,图片获取在重新尝试中.
        [self.thumbnailGetOperation removeObserver:self forKeyPath:@"hasHadRetryableFailure"];
        
        [[NetworkManager sharedManager] cancelOperation:self.thumbnailGetOperation];
        self.thumbnailGetOperation = nil;
        didSomething = YES;
    }
    if (self.thumbnailResizeOperation != nil) {//更改 thumbnail 的尺寸的操作可以被取消
        [[NetworkManager sharedManager] cancelOperation:self.thumbnailResizeOperation];
        self.thumbnailResizeOperation = nil;
        didSomething = YES;
    }
    return didSomething;
}


// 如果 RetryingHTTPOperation 获取失败后,第一次进行 retry 的话,会更改 hasHadRetryableFailure 的值,本类收到通知,调用本方法.
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == &self->_thumbnailImage) {
        assert(object == self.thumbnailGetOperation); // 发送此消息的是RetryingHTTPOperation类的实例,thumbnailGetOperation 操作
        assert( [keyPath isEqual:@"hasHadRetryableFailure"] );
        assert([NSThread isMainThread]);    //因为涉及到 UI 的更新, 本方法是在 main thread 上调用
        
        // If we're currently showing a placeholder and the network operation 
        // indicates that it's had one failure, change the placeholder to the deferred placeholder.
        //
        // The test for thumbnailImageIsPlaceholder is necessary in the
        // -updateThumbnail case because we don't want to replace a valid (but old) 
        // thumbnail with a placeholder.
        
        // 本类实例在初次初始化时,没有从网络获取 thumbnail 的数据,在 PhotoCell 初次请求 thumbnailImage 属性时,
        // 会先返回一个 PlaceHolder, 并启用一个异步网络请求去加载服务器的thnubnail
        // 如果请求成功,会 resize 后,返回真正的 thunbnail
        // 如果请求失败,返回一个请求失败的 placeholder.
        if (self.thumbnailImageIsPlaceholder && self.thumbnailGetOperation.hasHadRetryableFailure) {
            [self thumbnailCommitImage:[UIImage imageNamed:@"Placeholder-Deferred.png"] isPlaceholder:YES];
        }
        
    } else if (NO) {   // Disabled because the super class does nothing useful with it.
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

// Called when the HTTP operation to GET the photo's thumbnail completes.
// If all is well, we start a resize operation to reduce it the appropriate size.
- (void)thumbnailGetDone:(RetryingHTTPOperation *)operation
{
    assert([NSThread isMainThread]);
    assert([operation isKindOfClass:[RetryingHTTPOperation class]]);
    assert(operation == self.thumbnailGetOperation);
    assert([self.thumbnailGetOperation isFinished]);

    assert(self.thumbnailResizeOperation == nil);  //此时应该还没有设置 resize operation

    [[QLog log] logWithFormat:@"%s photo %@ thumbnail get done. %@",__PRETTY_FUNCTION__, self.photoID , operation.request.URL];
    
    if (operation.error != nil) {
        [[QLog log] logWithFormat:@"photo %@ thumbnail get error %@", self.photoID, operation.error];
        [self thumbnailCommitImage:nil isPlaceholder:YES];  //从网络获取thumbnail失败的话,就启用 placeholder
        (void) [self stopThumbnail];  //做清理工作
        
    } else { //从网络获 thumbnail 成功完成
        
        [[QLog log] logOption:kLogOptionNetworkData withFormat:@"receive %@", operation.responseContent];

        // Got the data successfully.  Let's start the resize operation.
        // 开始 resize 操作
        
        self.thumbnailResizeOperation = [[[MakeThumbnailOperation alloc] initWithImageData:operation.responseContent MIMEType:operation.responseMIMEType] autorelease];
        assert(self.thumbnailResizeOperation != nil);

        self.thumbnailResizeOperation.thumbnailSize = kThumbnailSize; // MakeThumbnailOperation 类的thumbnailSize 默认为32.0f
        
        // We want thumbnails resizes to soak up(吸收) unused CPU time, but the main thread should
        // always run if it can.  The operation priority is a relative value (courtesy of(由...提供) the
        // underlying Mach THREAD_PRECEDENCE_POLICY), that is, it sets the priority relative 
        // to other threads in the same process.  A value of 0.5 is the default, so we set a 
        // value significantly lower than that.
        
        if ( [self.thumbnailResizeOperation respondsToSelector:@selector(setThreadPriority:)] ) {
            [self.thumbnailResizeOperation setThreadPriority:0.2];
        }
        [self.thumbnailResizeOperation setQueuePriority:NSOperationQueuePriorityLow];
        
        
        // 向 main thread 上添加任务
        [[NetworkManager sharedManager] addCPUOperation:self.thumbnailResizeOperation finishedTarget:self action:@selector(thumbnailResizeDone:)];
    }
}

// Called when the operation to resize the thumbnail completes.
// If all is well, we commit the thumbnail to our database.
- (void)thumbnailResizeDone:(MakeThumbnailOperation *)operation
{
    assert([NSThread isMainThread]);
    assert([operation isKindOfClass:[MakeThumbnailOperation class]]);
    assert(operation == self.thumbnailResizeOperation);
    assert([self.thumbnailResizeOperation isFinished]);

    [[QLog log] logWithFormat:@"%s photo %@ thumbnail resize done. %@", __PRETTY_FUNCTION__, self.photoID, self.thumbnailGetOperation.request.URL];
 
    UIImage *   image;
    if (operation.thumbnail == NULL) {
        [[QLog log] logWithFormat:@"photo %@ thumbnail resize failed", self.photoID];
        image = nil;
    } else { //  resize operation 顺利完成
        // 返回处理好的图片
        image = [UIImage imageWithCGImage:operation.thumbnail];
        assert(image != nil);
    }
    
    [self thumbnailCommitImage:image isPlaceholder:NO];
    [self stopThumbnail]; //清理工作
}

// Commits the thumbnail image to the object itself and to the Core Data database.
// 如果成功 resize thumbnail 后,将处理好的 UIImage 提交上来.此时, placeholder 开关应该为 NO
// 如果 get thumbnial 或 resize thumbnail 的操作出现错误, 将 image 设置为 nil, 此时.placeholder 开关应该为 YES, 表示启用预先定义好的 Placeholder
// 如果 placeholder 为 NO 的话, 会把 Image 存入到 CoreData.
// 无论如何,本方法会更改 thumbnailImage 属性的值,导致监控本属性的 PhotoCell 类得到通知,更新 UI 上的照片.
- (void)thumbnailCommitImage:(UIImage *)image isPlaceholder:(BOOL)isPlaceholder
{
    // If we were given no image, that's a shortcut for the bad image placeholder.  In 
    // that case we ignore the incoming value of placeholder and force it to YES.
    
    if (image == nil) {
        isPlaceholder = YES;
        //On iOS 4 and later, if the file is in PNG format, it is not necessary to specify the .PNG filename extension.
        //Prior to iOS 4, you must specify the filename extension.
        //image = [UIImage imageNamed:@"Placeholder-Bad.png"];
        image = [UIImage imageNamed:@"Placeholder-Bad"];
        assert(image != nil);
    }
    
    // If it was a placeholder, someone else has logged about the failure, so 
    // we only log for real thumbnails.
    
    if ( ! isPlaceholder ) {
        [[QLog log] logWithFormat:@"%s photo %@ thumbnail commit to UI.%@",__PRETTY_FUNCTION__, self.photoID, self.thumbnailGetOperation.request.URL];
    }
    
    // If we got a non-placeholder image, commit its PNG representation into our thumbnail database.
    // To avoid the scroll view stuttering(结巴,口吃), we only want to do this if the run loop is running in the default mode.
    // Thus, we check the mode and either do it directly or defer the work until the next time the default run loop mode runs.
    //
    // If we were running on iOS 4 or later we could get the PNG representation using 
    // ImageIO, but I want to maintain iOS 3 compatibility for the moment and on that 
    // system we have to use UIImagePNGRepresentation.
    
    //将不是 placeholder 的数据存入 Core Data
    if ( ! isPlaceholder ) {
        if ( [[[NSRunLoop currentRunLoop] currentMode] isEqual:NSDefaultRunLoopMode] ) {
            [self thumbnailCommitImageData:image];
        } else {
            [self performSelector:@selector(thumbnailCommitImageData:)
                       withObject:image
                       afterDelay:0.0
                          inModes:[NSArray arrayWithObject:NSDefaultRunLoopMode]
             ];
        }
    }
    
    // Commit the change to our thumbnailImage property.  PhotoCell中监控着此属性值的改变.将导致其更新自己的 UI 图片
    [self willChangeValueForKey:@"thumbnailImage"];
    [self->_thumbnailImage release];
    self->_thumbnailImage = [image retain];
    [self  didChangeValueForKey:@"thumbnailImage"];
    
}


// Commits the thumbnail data to the Core Data database.
// 本方法只有在 thumbnail.imageData为空时,才存入数据. 不会更新 thumbnail.
// 更新 thumbnail ,请调用 updateThumbnail 方法.
- (void)thumbnailCommitImageData:(UIImage *)image
{
    [[QLog log] logWithFormat:@"%s photo %@ thumbnail commit image to CoreData. %@",__PRETTY_FUNCTION__, self.photoID ,self.thumbnailGetOperation.request.URL];
    
    // If we have no thumbnail object, create it.
    if (self.thumbnail == nil) {
        // managedObjectContext 在本类 insertNewPhotoWithProperties:inManagedObjectContext: 方法中注册本类实例时添加上的.
        self.thumbnail = [NSEntityDescription insertNewObjectForEntityForName:@"Thumbnail" inManagedObjectContext:self.managedObjectContext];
        assert(self.thumbnail != nil);
    }
    
    // Stash the data in the thumbnail object's imageData property.
    // 只有在 thumbnail.imageData为空时,才存入数据.
    if (self.thumbnail.imageData == nil) {
        
        // If we were running on iOS 4 or later we could get the PNG representation using
        // ImageIO, but I want to maintain iOS 3 compatibility for the moment and on that
        // system we have to use UIImagePNGRepresentation.
        self.thumbnail.imageData = UIImagePNGRepresentation(image);
        assert(self.thumbnail.imageData != nil);
    }
}

// 被 PhotoCell 类读取,用于赋值到其self.imageView.image属性中,用于 UI 展示.
//
// 初次访问,它会暂时将一个 placeholder 的图片返回,并启用异步的加载 operation ,
// 从网络请求 thumbnail,如果下载成功完成,会紧接着启用 resize operation. 将刚刚下载的 thumbnailImage 重新设置尺寸,
// 完成后将结果存入 CoreData ,并赋值给self.photo.thumbnailImage.
- (UIImage *)thumbnailImage
{
    if (self->_thumbnailImage == nil) { //本属性还没有被初始化
        if ( (self.thumbnail != nil) && (self.thumbnail.imageData != nil) ) { //已经从网络下载了thumbnail,并从 Core Data 获取到
        
            // If we have a thumbnail from the database, return that.
            self.thumbnailImageIsPlaceholder = NO;
            self->_thumbnailImage = [[UIImage alloc] initWithData:self.thumbnail.imageData];
            assert(self->_thumbnailImage != nil);
            
        } else { //刚刚初始化的对象,还没有从网络下载数据
            
            assert(self.thumbnailGetOperation    == nil);   // These should be nil because the only code paths that start 
            assert(self.thumbnailResizeOperation == nil);   // a get also ensure there's a thumbnail in place (either a 
                                                            // placeholder or the old thumbnail).
        
            // Otherwise, return the placeholder and kick off a get (unless we're already getting).
            self.thumbnailImageIsPlaceholder = YES;//暂时返回一个 PlaceHolder
            self->_thumbnailImage = [[UIImage imageNamed:@"Placeholder.png"] retain];
            assert(self->_thumbnailImage != nil);
            
            [self startThumbnailGet]; //启用网络下载最新的 thumbnail
        }
    }
    return self->_thumbnailImage;
}


// Updates the thumbnail is response to a change in the photo's XML entity.
// 更新 thumbnail 的值为从网络下载的 xml 中的数据.
- (void)updateThumbnail
{
    [[QLog log] logWithFormat:@"%s photo %@ update thumbnail. %@",__PRETTY_FUNCTION__, self.photoID,self.thumbnailGetOperation.request.URL];

    // We only do an update if we've previously handed out(分发,公布) a thumbnail image.
    // If not, the thumbnail will be fetched normally when the client first requests an image.
    
    if (self->_thumbnailImage != nil) {
    
        // If we're already getting a thumbnail, stop that get (it may be getting from the old path).
        (void) [self stopThumbnail];
        
        // Nix our thumbnail data.  This ensures that, if we quit before the get is complete, 
        // then, on relaunch, we will notice that we need to get the thumbnail.
        if (self.thumbnail != nil) {
            self.thumbnail.imageData = nil;
        }
        
        // Kick off the network get.  Note that we don't nix _thumbnailImage here.  The client 
        // will continue to see the old thumbnail (which might be a placeholder) until the 
        // get completes.
        [self startThumbnailGet];
    }
    
}


#pragma mark - Photos

// PhotoDetailViewController 的 viewWillAppear 中调用
// 声明现在需要大图了.
- (void)assertPhotoNeeded
{
    self->_photoNeededAssertions += 1;
    if ( (self.localPhotoPath == nil) && ! self.photoGetting ) { //如果还没有下载的话
        [self startPhotoGet];
    }
}

// Starts the HTTP operation to GET the photo itself.
// 开始下载大图,在 assertPhotoNeeded 中被调用
// 当前是在 main thread 上运行那个
- (void)startPhotoGet
{
    NSURLRequest *      request;

    assert(self.remotePhotoPath != nil);
    // assert(self.localPhotoPath  == nil);     -- May be non-nil when we're updating the photo.
    assert( ! self.photoGetting );

    assert(self.photoGetOperation == nil);
    assert(self.photoGetFilePath == nil);
    
    self.photoGetError = nil;
    
    //示例: self.remotePhotoPath = @"images/IMG_0125.JPG"
    request = [self.photoGalleryContext requestToGetGalleryRelativeString:self.remotePhotoPath];
    //示例:  request = { URL: http://Leo-MacBook-Pro.local:8888/TestGallery/images/IMG_0125.JPG }
    if (request == nil) {
        [[QLog log] logWithFormat:@"%s photo %@ photo get bad path '%@'",__PRETTY_FUNCTION__, self.photoID, self.remotePhotoPath];
        self.photoGetError = [NSError errorWithDomain:kQHTTPOperationErrorDomain code:400 userInfo:nil];
    } else {

        // We start by downloading the photo to a temporary file.  Create an output stream for that file.
        self.photoGetFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"PhotoTemp-%.9f", [NSDate timeIntervalSinceReferenceDate]
                                ]];
        //example :  self.photoGetFilePath = /private/var/mobile/Applications/8181B390-29AC-4311-B18B-E0992F70D8DC/tmp/PhotoTemp-418620304.233712971
        assert(self.photoGetFilePath != nil);
        
        // Create, configure, and start the download operation.
        self.photoGetOperation = [[[RetryingHTTPOperation alloc] initWithRequest:request] autorelease];
        assert(self.photoGetOperation != nil);
        
        [self.photoGetOperation setQueuePriority:NSOperationQueuePriorityHigh];
        self.photoGetOperation.responseFilePath = self.photoGetFilePath; //设置 下载内容到文件 的路径, 在 RetryingHTTPOperation 的 startRequest 方法里会检测这个值.
        self.photoGetOperation.acceptableContentTypes = [NSSet setWithObjects:@"image/jpeg", @"image/png", nil];

        [[QLog log] logWithFormat:@"%s photo %@ photo get start '%@'",__PRETTY_FUNCTION__, self.photoID, self.remotePhotoPath];
        
        // 添加到网络管理队列, 在其他队列里运行 get 操作
        [[NetworkManager sharedManager] addNetworkManagementOperation:self.photoGetOperation finishedTarget:self action:@selector(photoGetDone:)];
    }
}

// Called when the HTTP operation to GET the photo completes.
// If all is well, we commit the photo to the database.
- (void)photoGetDone:(RetryingHTTPOperation *)operation
{
    assert([NSThread isMainThread]);
    assert([operation isKindOfClass:[RetryingHTTPOperation class]]);
    assert(operation == self.photoGetOperation);

    [[QLog log] logWithFormat:@"%s photo %@ photo get done '%@'",__PRETTY_FUNCTION__, self.photoID,self.remotePhotoPath];
    
    if (operation.error != nil) {
        [[QLog log] logWithFormat:@"photo %@ photo get error %@", self.photoID, operation.error];
        self.photoGetError = operation.error;
    } else {

        // Can't log the incoming data becauses it went directly to disk.
        // 
        // [[QLog log] logOption:kLogOptionNetworkData withFormat:@"receive %@", operation.responseContent];
        
        // Just to keep things sane, we set the file name extension based on the MIME type.
        NSString *  type;
        NSString *  extension;
        type = operation.responseMIMEType;
        assert(type != nil);
        if ([type isEqual:@"image/png"]) {
            extension = @"png";
        } else {
            assert([type isEqual:@"image/jpeg"]);
            extension = @"jpg";
        }
        
        // Move the file to the gallery's photo directory, and if that's successful, set localPhotoPath 
        // to point to it.  We automatically rename the file to avoid conflicts.  Conflicts do happen 
        // in day-to-day operations (specifically, in the case where we update a photo while actually 
        // displaying that photo).
        
        // 这里在移动下载下来的缓存文件到存放图片的目录时,如果这个图片正在使用的话(比如正在查看),可能会有冲突,导致移动不成功.
        // 所以这里设置了一个循环,去检查有没有移动成功,如果没有移动成功就尝试下一次,直到移动成功.或者如果连续100次移动不成功,就放弃了.
        NSString *  fileName;
        NSError *   error;
        BOOL        success;
        NSUInteger  fileCounter = 0;
        do {
            fileName = [NSString stringWithFormat:@"Photo-%@-%zu.%@", self.photoID, (size_t) fileCounter, extension];
            assert(fileName != nil);
            
            success = [[NSFileManager defaultManager] moveItemAtPath:self.photoGetFilePath
                                                              toPath:[self.photoGalleryContext.photosDirectoryPath stringByAppendingPathComponent:fileName]
                                                               error:&error];
            if ( success ) {
                self.photoGetFilePath = nil;
                break;
            }
            fileCounter += 1;
            if (fileCounter > 100) {
                break;
            }
        } while (YES);

        // On success, update localPhotoPath to point to the newly downloaded photo 
        // and then delete the previous photo (if any).
        
        if (success) {
            NSString *  oldLocalPhotoPath;
            
            oldLocalPhotoPath = [[self.localPhotoPath copy] autorelease];
            
            [[QLog log] logWithFormat:@"%s big photo %@ photo get commit '%@'",__PRETTY_FUNCTION__, self.photoID, fileName];
            self.localPhotoPath = fileName;
            assert(self.photoGetError == nil);
            
            if (oldLocalPhotoPath != nil) { //说明原来就有这个图片,被新图片替换了
                [[QLog log] logWithFormat:@"%s big photo %@ photo cleanup '%@'",__PRETTY_FUNCTION__, self.photoID, oldLocalPhotoPath];
                (void) [[NSFileManager defaultManager]
                        removeItemAtPath:[self.photoGalleryContext.photosDirectoryPath stringByAppendingPathComponent:oldLocalPhotoPath]
                        error:NULL];
            }
        } else {
            assert(error != nil);
            [[QLog log] logWithFormat:@"%s photo %@ photo get commit failed %@",__PRETTY_FUNCTION__, self.photoID, error];
            self.photoGetError = error;
        }
    }
    
    // Clean up.    
    self.photoGetOperation = nil;
    if (self.photoGetFilePath != nil) { //新下载的大图片还在临时目录下
        (void) [[NSFileManager defaultManager] removeItemAtPath:self.photoGetFilePath error:NULL];
        self.photoGetFilePath = nil;
    }
}

//Foundation 框架提供的表示属性依赖的机制
+ (NSSet *)keyPathsForValuesAffectingPhotoImage
{
    return [NSSet setWithObject:@"localPhotoPath"];
}
// 大图数据
- (UIImage *)photoImage
{
    UIImage *   result;
    
    // Note that we don't retain the photo here.  Photos are large, and holding on to them here 
    // is probably a mistake.  It's likely that the caller is going to retain the photo anyway 
    // (by putting it into an image view, say).
    
    if (self.localPhotoPath == nil) {   //大图还没有被下载下来
        result = nil;
    } else {
        result = [UIImage imageWithContentsOfFile:[self.photoGalleryContext.photosDirectoryPath stringByAppendingPathComponent:self.localPhotoPath]];
        if (result == nil) {
            [[QLog log] logWithFormat:@"photo %@ photo data bad", self.photoID];
        }
    }
    return result;
}

//Foundation 框架提供的表示属性依赖的机制
+ (NSSet *)keyPathsForValuesAffectingPhotoGetting
{
    return [NSSet setWithObject:@"photoGetOperation"];
}
//返回, 获取大图的操作是否在进行
- (BOOL)photoGetting
{
    return (self.photoGetOperation != nil);
}

// PhotoDetailViewController 的 viewDidDisappear 中调用
// Tell the model object is no longer needs to keep the photo image up-to-date.
- (void)deassertPhotoNeeded
{
    assert(self->_photoNeededAssertions != 0);
    self->_photoNeededAssertions -= 1;
}

// Updates the photo is response to a change in the photo's XML entity.
- (void)updatePhoto
{
    [[QLog log] logWithFormat:@"%s photo %@ update photo",__PRETTY_FUNCTION__, self.photoID];

    // We only fetch the photo is someone is actively looking at it.  Otherwise 
    // we just nix our record of the photo and fault it in as per usual the next 
    // time that someone asserts that they need it.

    if (self->_photoNeededAssertions == 0) {
    
        // No one is actively looking at the photo.  If we have the photo downloaded, just forget about it.    
        if (self.localPhotoPath != nil) {
            [[QLog log] logWithFormat:@"photo %@ photo delete old photo '%@'", self.photoID, self.localPhotoPath];
            [[NSFileManager defaultManager] removeItemAtPath:[self.photoGalleryContext.photosDirectoryPath stringByAppendingPathComponent:self.localPhotoPath]
                                                       error:NULL];
            self.localPhotoPath = nil;
        }
        
    } else {

        // If we're already getting the photo, stop that get (it may be getting from the old path).
        if (self.photoGetOperation != nil) {
            [[NetworkManager sharedManager] cancelOperation:self.photoGetOperation];
            self.photoGetOperation = nil;
        }
        
        // Someone is actively looking at the photo.  We start a new download, which 
        // will download the new photo to a new file.  When that completes, it will 
        // change localPhotoPath to point to the new file and then delete the old 
        // file.
        // 
        // Note that we don't trigger a KVO notification on photoImage at this point. 
        // Instead we leave the user looking at the old photo; it's better than nothing (-:
        
        [self startPhotoGet];
    }
}

@end
