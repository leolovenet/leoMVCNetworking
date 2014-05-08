#import "AppDelegate.h"
#import "PhotoGallery.h"
#import "PhotoGalleryViewController.h"
#import "SetupViewController.h"
#import "NetworkManager.h"
#import "Logging.h"


@interface AppDelegate () <SetupViewControllerDelegate>
// private properties
@property (nonatomic, copy,   readwrite) NSString *                     galleryURLString;
@property (nonatomic, retain, readwrite) PhotoGallery *                 photoGallery;
@property (nonatomic, retain, readwrite) PhotoGalleryViewController *   photoGalleryViewController;
// forward declarations
- (void)presentSetupViewControllerAnimated:(BOOL)animated;
@end



/*
 本程序的目的就是展示一组照片.
 关于展示那一组,那组里的什么照片,以及有关照片的属性信息等问题,都是向服务器发起请求一个预先定义好的 galleryURLString 构成的 URL 所代表的 xml 文件,然后分析里面的数据得到的.
 程序将获取到的数据存储到 CoreData 中. 并在 PhotoGaleryViewController 中对 CoreData 的数据做了监控,只要 CoreData 的数据发生了改变,就会更新 UI.
 这样我们就看到了手机展示那些图片.
 所以,程序一开始的时候,就让选择一个 galleryURLString, 然后会想这个 URL 发起请求,获得 xml,然后分析里面的数据,存储到 CoreData 中.
 
 
 NetworkManager 类对象为本程序的一个单例(即贯穿整个程序的存在),并且负责管理所有关于网络的操作.
 可以通过 NetworkManger 的类方法 sharedMangeer 获得此单例.
 在这个单例中保存了添加的 Operation, Operation 被添加到的 Queue, Operation 完成后调用那个 target 的那个 method 等4个主要信息.
 NetworkManger 还单纯创建了一个 theard, 用于在非 main theard 上执行网络操作,防止阻碍系统的 UI.
 所有关于网络的 Operation 都需要添加到这个单例上面去登记执行,然后单例负责在 operation 完成后启用回调函数.
 可以说,NetworkManger 是本程序对所有网络操作的一个封装,这样,使我们在编写业务逻辑时,而不必顾虑底层网络操作的种种细节,只要向 NetworkManger 的单例里丢要求(Operation),然后登记要求满足(完成)后,调用什么方法继续处理就好了.
 
 NetworkManger 类里主要包含了 NSOperation, NSOperationQueue, thread , NSRunLoop 等技术.
 
 
 在程序启动时, applicationDidFinishLaunching 方法初始化 NetworkManager 的单例.
 然后查找是否已经保存了关于一组照片的 URL 地址,如果存在就初始化 PhotoGalleryViewController 实例,
 该实例负责初始化一些获取此 URL 的 Operation ,然后添加到 NetworkManger 的单例中去.并登记操作完成后,在那个 Queue 里调用那个方法.
 这样等 get URL 相关的 xml 文件的操作完成以后,就会开启 GalleryParserOperation 操作,分析 xml,保存有用数据到 CoreData.
 
 
 [M] model 层
 [V] View 层
 [C] Control 层
 
                      self
                        |
          |----------------------------------|
          |                 PhotoGaaleryViewController:UITableViewController[C]
          |                         |                      |
 PhotoGallery[M] <--  ==  --> PhotoGallery[M]          UITableView[V]
          |                         |                      |
          |                         |                  PhotoCell[V]
          |                         |                      |
          |                         |                   Photo[M]
          |                         |
         --------------------------------------------------------------------------
          |                         |                     |                       |
    QRunLoopOperation  GalleryParserOperation    NSManagedObjectContext           |
          |                                               |                       |
   RetryingHTTPOperation                         PhotoGalleryContext              |
                                                          |                       |
                                                       CoreData                   |
                                                        |   |                     |
                                                Thunbmail  Photo
 
 
 
 
 */



#pragma mark - implementation AppDelegate

@implementation AppDelegate

@synthesize window                     = _window;
@synthesize navController              = _navController;
@synthesize galleryURLString           = _galleryURLString;
@synthesize photoGallery               = _photoGallery;    //代表一组照片的 photogallery 对象.
@synthesize photoGalleryViewController = _photoGalleryViewController;

#define GALLERY_URL_STRING_KEY @"galleryURLString"
#define APPLICATON_CLEAR_SETUP @"applicationClearSetup"


#pragma mark - UIApplicationDelegate

- (void)applicationDidFinishLaunching:(UIApplication *)application
{
    #pragma unused(application)
    assert(self.window != nil);
    assert(self.navController != nil);
    
    [[QLog log] logWithFormat:@"application start"];
    
    // Tell the PhotoGallery class about application startup, which gives it the 
    // opportunity to do some on-disk garbage collection.
    [PhotoGallery applicationStartup];

    // Add an observer to the network manager's networkInUse property so that we can  
    // update the application's networkActivityIndicatorVisible property(控制这状态来的网络加载指示器的显示与否).
    // This has the side effect of starting up the NetworkManager singleton.
    // 因为启用了NSKeyValueObservingOptionInitial 选项,所以会导致立即调用本类的observeValueForKeyPath:ofObject:change:context: 方法
    [[NetworkManager sharedManager] addObserver:self forKeyPath:@"networkInUse" options:NSKeyValueObservingOptionInitial context:NULL];

    // If the "applicationClearSetup" user default is set, clear our preferences. 
    // This provides an easy way to get back to the initial state while debugging.
    NSUserDefaults * userDefaults = [NSUserDefaults standardUserDefaults];
    if ( [userDefaults boolForKey:APPLICATON_CLEAR_SETUP] ) {
        [userDefaults removeObjectForKey:APPLICATON_CLEAR_SETUP];
        [userDefaults removeObjectForKey:GALLERY_URL_STRING_KEY];
        [SetupViewController resetChoices];
    }

    // Get the current gallery URL and, if it's not nil, create a gallery object for it.
    // 从首选项里获取当前 gallery 的 url.
    self.galleryURLString = [userDefaults stringForKey:GALLERY_URL_STRING_KEY];
    if ( (self.galleryURLString != nil) && ([NSURL URLWithString:self.galleryURLString] == nil) ) {
        // nil is just fine, but a value that doesn't parse as a URL is not.
        self.galleryURLString = nil;
    }
    
    if (self.galleryURLString != nil) {
        // 如果之前的操作已经保存了 gallery 的 URL, 那么就以这个 URL 初始化 self.photoGallery
        // self.photoGallery 代表了从网络获取galleryURLString所指的 xml 后,分析数据得到的一组照片信息.
        self.photoGallery = [[[PhotoGallery alloc] initWithGalleryURLString:self.galleryURLString] autorelease];
        assert(self.photoGallery != nil);
        
        [self.photoGallery start];
    }
    
    // Set up the main view to display the gallery (if any).  We add our Setup button to the 
    // view controller's navigation items, which seems like a bit of a layer break but it 
    // makes some sort of sense because we want the actions directed to us.
    
    // 代表一组Photo对象集合的 self.photoGallery 对象,可能还没有初始化,也可能已经在上面通过 self.galleryURLString 初始化了.
    self.photoGalleryViewController = [[[PhotoGalleryViewController alloc] initWithPhotoGallery:self.photoGallery] autorelease];
    assert(self.photoGalleryViewController != nil);

    self.photoGalleryViewController.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Setup"
                                                                                                          style:UIBarButtonItemStyleBordered
                                                                                                         target:self
                                                                                                         action:@selector(setupAction:)] autorelease];
    assert(self.photoGalleryViewController.navigationItem.rightBarButtonItem != nil);
  
    [self.navController pushViewController:self.photoGalleryViewController animated:NO];
  
    self.window.rootViewController = self.navController;
    //[self.window addSubview:self.navController.view];
	[self.window makeKeyAndVisible];

    // If the user hasn't configured the app, push the setup view controller.
    if (self.galleryURLString == nil) {
        // 展示选择 galleryURLString 的界面,主要用于初始化self.photoGallery
        [self presentSetupViewControllerAnimated:NO];
    }
}

- (void)applicationDidEnterBackground:(UIApplication *)application
    // When we enter the background make sure to push all of our state 
    // out to disk.
{
    #pragma unused(application)
    [[QLog log] logWithFormat:@"application entered background"];
    if (self.photoGallery != nil) {
        [self.photoGallery save];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)applicationWillTerminate:(UIApplication *)application
    // Likewise, on iOS 3, and in exceptional circumstances on iOS 4, 
    // save our state when we are being terminated.
{
    #pragma unused(application)
    [[QLog log] logWithFormat:@"application will terminate"];
    if (self.photoGallery != nil) {
        [self.photoGallery stop];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}


#pragma mark - Custom methods

- (IBAction)setupAction:(id)sender
    // Called when the user taps the Setup button.  It just calls through 
    // to -presentSetupViewControllerAnimated:.
{
    #pragma unused(sender)
    [self presentSetupViewControllerAnimated:YES];
}

- (void)presentSetupViewControllerAnimated:(BOOL)animated
    // Presents the setup view controller.
{
    SetupViewController *   vc;
    
    vc = [[[SetupViewController alloc] initWithGalleryURLString:self.galleryURLString] autorelease];
    assert(vc != nil);
    
    vc.delegate = self;
    
    [vc presentModallyOn:self.navController animated:animated];
}

#pragma mark - protocal: SetupViewControllerDelegate method
- (void)setupViewController:(SetupViewController *)controller didChooseString:(NSString *)string
    // A setup view controller delegate callback, called when the user chooses 
    // a gallery URL string.  We respond by reconfiguring the app to display that 
    // gallery.
{
    assert(controller != nil);
    #pragma unused(controller)
    assert(string != nil);
    
    // Disconnect the view controller from the current gallery.
    self.photoGalleryViewController.photoGallery = nil;
    
    // Shut down and dispose of the current gallery.
    if (self.photoGallery != nil) {
        [self.photoGallery stop];
        self.photoGallery = nil;
    }

    // Apply the change.
    if ( [string length] == 0 ) {
        string = nil;
    }
    self.galleryURLString = string;
    if (self.galleryURLString != nil) {
        
        // Create a new gallery for the specified URL.
        self.photoGallery = [[[PhotoGallery alloc] initWithGalleryURLString:self.galleryURLString] autorelease];
        assert(self.photoGallery != nil);
        
        [self.photoGallery start];
        
        // Point the main view controller at the new gallery.
        self.photoGalleryViewController.photoGallery = self.photoGallery;
        
        // Save the user's choice.
        [[NSUserDefaults standardUserDefaults] setObject:self.galleryURLString forKey:GALLERY_URL_STRING_KEY];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:GALLERY_URL_STRING_KEY];
    }
    
  [self.navController dismissViewControllerAnimated:YES completion:NULL];

}

- (void)setupViewControllerDidCancel:(SetupViewController *)controller
    // A setup view controller delegate callback, called when the user cancels. 
    // We just dismiss the view controller.
{
    assert(controller != nil);
    #pragma unused(controller)
    [self.navController dismissViewControllerAnimated:YES completion:NULL];
}


#pragma mark - implement the KVO observing method

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
// When the network manager's networkInUse property changes, update the
// application's networkActivityIndicatorVisible property accordingly.
{
  if ([keyPath isEqual:@"networkInUse"]) {
    assert(object == [NetworkManager sharedManager]);
    #pragma unused(change)
    assert(context == NULL);
    assert( [NSThread isMainThread] );
    [UIApplication sharedApplication].networkActivityIndicatorVisible = [NetworkManager sharedManager].networkInUse;
      
      
  } else if (NO) {   // Disabled because the super class does nothing useful with it.
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  }
}

@end
