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


#pragma mark - implementation AppDelegate

@implementation AppDelegate

@synthesize window        = _window;
@synthesize navController = _navController;
@synthesize galleryURLString           = _galleryURLString;
@synthesize photoGallery               = _photoGallery;
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
        // 如果之前的操作已经保存了 gallery 的 url,这里就以那个 gallery 初始化 self.photoGallery
        self.photoGallery = [[[PhotoGallery alloc] initWithGalleryURLString:self.galleryURLString] autorelease];
        assert(self.photoGallery != nil);
        
        [self.photoGallery start];
    }
    
    // Set up the main view to display the gallery (if any).  We add our Setup button to the 
    // view controller's navigation items, which seems like a bit of a layer break but it 
    // makes some sort of sense because we want the actions directed to us.
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
