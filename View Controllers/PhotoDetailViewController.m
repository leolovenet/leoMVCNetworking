#import "PhotoDetailViewController.h"
#import "QImageScrollView.h"
#import "PhotoGallery.h"
#import "Photo.h"
#import "Logging.h"


@implementation PhotoDetailViewController

- (id)initWithPhoto:(Photo *)photo photoGallery:(PhotoGallery *)photoGallery
{
    assert(photo != nil);
    assert(photoGallery != nil);
    self = [super initWithNibName:@"PhotoDetailViewController" bundle:nil];
    if (self != nil) {
        self->_photo        = [photo retain];
        self->_photoGallery = [photoGallery retain];

        [self.photo addObserver:self forKeyPath:@"displayName"  options:NSKeyValueObservingOptionInitial context:&self->_photo];
    }
    return self;
}

- (void)dealloc
{
    [self.photo removeObserver:self forKeyPath:@"displayName"];

    [self->_scrollView release];
    [self->_loadingLabel release];

    [self->_photo release];
    [self->_photoGallery release];

    [super dealloc];
}

#pragma mark * Keeping everything up-to-date

@synthesize photo        = _photo;
@synthesize photoGallery = _photoGallery;

- (void)photoWasDeleted
    // If the underlying photos was deleted while we're displaying it (typically 
    // because a sync ran), we just pop ourselves off the view controller stack.
{
    if ([self.navigationController.viewControllers containsObject:self]) {
        [self.navigationController popToViewController:self animated:NO];
        [self.navigationController popViewControllerAnimated:YES];
    }
}

- (void)contextChanged:(NSNotification *)note
    // This notification is issued by the NSManagedObjectContext that controls the photo 
    // object we're displaying.  If that phono object is deleted (as can happen if a sync 
    // occurs while we're on screen), we call -photoWasDeleted (which pops us off the 
    // navigation controller stack).
{
    NSSet * deletedObjects;
    
    deletedObjects = [[note userInfo] objectForKey:NSDeletedObjectsKey];
    if (deletedObjects != nil) {
        assert([deletedObjects isKindOfClass:[NSSet class]]);
        
        if ([deletedObjects containsObject:self.photo]) {
            [self photoWasDeleted];
        }
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == &self->_photo) {
    
        // Called when various properties of our photo change.  We update our UI 
        // accordingly.
    
        assert(object == self.photo);
        if ([keyPath isEqual:@"displayName"]) {
        
            // Sync the photo name into the navigation item title.
            
            self.title = self.photo.displayName;
        } else if (self.isViewLoaded) {
            if ([keyPath isEqual:@"photoImage"]) {
                UIImage *   image;
            
                // If the photo changed, update our UI.  All of the hard work is done 
                // by the QImageScrollView class.
                
                image = self.photo.photoImage;
                self.scrollView.image = image;
                self.scrollView.hidden = (image == nil);
                self.loadingLabel.hidden = (image != nil);
            } else if ([keyPath isEqual:@"photoGetting"]) {
            
                // Update our loading label as the photo hits the network.
            
                if (self.photo.photoGetting) {
                    self.loadingLabel.text = @"Loading…";
                } else {
                    // This assert isn't valid because if we get bad photo data we don't 
                    // detect that at the time of the get, we detect that when we try to 
                    // create a UIImage from the file on disk.  In that case photoImage 
                    // will be nil but photoGetError will also be nil.  This doesn't materially 
                    // affect our code; we still want to display "Load failed".
                    //
                    // assert( (self.photo.photoImage != nil) || (self.photo.photoGetError != nil) );
                    self.loadingLabel.text = @"Load failed";
                }
            } else {
                assert(NO);
            }
        }
    } else if (NO) {   // Disabled because the super class does nothing useful with it.
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark * View controller stuff

@synthesize scrollView   = _scrollView;
@synthesize loadingLabel = _loadingLabel;

- (void)viewDidLoad
{
    [super viewDidLoad];

    assert([self.scrollView isKindOfClass:[QImageScrollView class]]);
    assert(self.loadingLabel != nil);

    self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
}

- (void)viewDidUnload
{
    [super viewDidUnload];

    self.scrollView = nil;
    self.loadingLabel = nil;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    // Tell the model object that we want it to keep the photo image up-to-date.

    [self.photo assertPhotoNeeded];

    // Configure our view.  We hide the scroll view, which leaves the loading label 
    // visible.
    
    self.scrollView.hidden   = YES;
    
    [self.navigationController setToolbarHidden:YES animated:animated];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    // Add the observers here so that the initial call sees the correct size 
    // of the scroll view (that is, after the toolbar has hidden).
    
    [self.photo addObserver:self forKeyPath:@"photoImage"   options:NSKeyValueObservingOptionInitial context:&self->_photo];
    [self.photo addObserver:self forKeyPath:@"photoGetting" options:NSKeyValueObservingOptionInitial context:&self->_photo];

    // Unfortunately -[NSManagedObject isDeleted] doesn't really do what I want 
    // here, so I just watch the context directly.
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(contextChanged:) name:NSManagedObjectContextObjectsDidChangeNotification object:self.photo.managedObjectContext];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];

    // Undo the stuff we did in -viewDidAppear.
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSManagedObjectContextObjectsDidChangeNotification object:self.photo.managedObjectContext];

    [self.photo removeObserver:self forKeyPath:@"photoImage"];
    [self.photo removeObserver:self forKeyPath:@"photoGetting"];

    // We show the navigation controller's toolbar here, so that you 
    // can see the animation.
    
    [self.navigationController setToolbarHidden:NO animated:animated];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];

    // Tell the model object is no longer needs to keep the photo image up-to-date.
    
    [self.photo deassertPhotoNeeded];
}

@end
