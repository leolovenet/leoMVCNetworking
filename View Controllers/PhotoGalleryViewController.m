#import "PhotoGalleryViewController.h"
#import "PhotoCell.h"
#import "PhotoDetailViewController.h"
#import "PhotoGallery.h"
#import "Photo.h"

#import "QLogViewer.h"
#import "QLog.h"

#pragma mark - private properties
@interface PhotoGalleryViewController () <NSFetchedResultsControllerDelegate>

@property (nonatomic, retain, readwrite) UIBarButtonItem *              stopBarButtonItem;
@property (nonatomic, retain, readwrite) UIBarButtonItem *              refreshBarButtonItem;
@property (nonatomic, retain, readwrite) UIBarButtonItem *              fixedBarButtonItem;
@property (nonatomic, retain, readwrite) UIBarButtonItem *              flexBarButtonItem;
@property (nonatomic, retain, readwrite) UIBarButtonItem *              statusBarButtonItem;
@property (nonatomic, retain, readwrite) NSFetchedResultsController *   fetcher;
@property (nonatomic, copy,   readwrite) NSDateFormatter *              dateFormatter; //表示的时间格式, 等于 self.photoGallery.standardDateFormatter

// forward declarations
- (void)setupStatusLabel;
- (void)setupSyncBarButtonItem;

@end

#pragma mark - implementation


/*
    本类继承自 UITableViewController ,本身就是 TableViewController.
 */

@implementation PhotoGalleryViewController

@synthesize stopBarButtonItem    = _stopBarButtonItem;
@synthesize refreshBarButtonItem = _refreshBarButtonItem;
@synthesize fixedBarButtonItem   = _fixedBarButtonItem;
@synthesize flexBarButtonItem    = _flexBarButtonItem;
@synthesize statusBarButtonItem  = _statusBarButtonItem;

@synthesize photoGallery         = _photoGallery;
@synthesize fetcher              = _fetcher;
@synthesize dateFormatter        = _dateFormatter;



- (id)initWithPhotoGallery:(PhotoGallery *)photoGallery
{
    // photoGallery may be nil
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        
        self->_photoGallery = [photoGallery retain];
        self.title = @"Photos";

        // Set up a raft of bar button items.
        self->_stopBarButtonItem    = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemStop target:self action:@selector(stopAction:)];
        self->_refreshBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshAction:)];
        self->_fixedBarButtonItem   = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
        self->_fixedBarButtonItem.width = 25.0f;
        self->_flexBarButtonItem    = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        
        UILabel *   statusLabel;
        statusLabel = [[[UILabel alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 240.0f, 32.0f)] autorelease];
        assert(statusLabel != nil);
        
        statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        statusLabel.textColor        = [UIColor blueColor];
        statusLabel.textAlignment    = UITextAlignmentCenter;
        statusLabel.backgroundColor  = [UIColor clearColor];
        statusLabel.font             = [UIFont systemFontOfSize:[UIFont smallSystemFontSize]];

        self->_statusBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:statusLabel];

        // Add an observer to the QLog's showViewer property to update whether we show our 
        // "Log" button in the left bar button position of the navigation bar.
        
        [[QLog log] addObserver:self forKeyPath:@"showViewer" options:NSKeyValueObservingOptionInitial context:NULL];
        
        // Add an observer for our own photoGallery property, so that we can adjust our UI 
        // when it changes.  Note that we set NSKeyValueObservingOptionPrior so that we 
        // get called before /and/ after the change, allowing us to shut down our UI before 
        // the change and bring it up again afterwards.
        // 因为指定了 NSKeyValueObservingOptionInitial 选项,导致observeValueForKeyPath:ofObject:change:context: 立即被调用
        [self addObserver:self forKeyPath:@"photoGallery" options:(NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionPrior) context:&self->_photoGallery];
    }
    return self;
}


//这个方法应该不会被执行
- (void)dealloc
{
    // There's no intrinsic(本质的) reason why this class shouldn't support -dealloc,
    // but in this application the following code never runs, and so is untested, 
    // and hence has a leading assert.
    
    assert(NO);
    
    // Remove all our KVO observers.
    if (self->_photoGallery != nil) {
        [self->_photoGallery removeObserver:self forKeyPath:@"syncing"];
        [self->_photoGallery removeObserver:self forKeyPath:@"syncStatus"];
        [self->_photoGallery removeObserver:self forKeyPath:@"standardDateFormatter"];
    }
    [self removeObserver:self forKeyPath:@"photoGallery"];
    [[QLog log] removeObserver:self forKeyPath:@"showViewer"];

    // Release our ivars.
    [self->_stopBarButtonItem release];
    [self->_refreshBarButtonItem release];
    [self->_fixedBarButtonItem release];
    [self->_flexBarButtonItem release];
    [self->_statusBarButtonItem release];

    [self->_photoGallery release];
    if (self->_fetcher != nil) {
        self->_fetcher.delegate = nil;
        [self->_fetcher release];
    }
    [self->_dateFormatter release];

    [super dealloc];
}



// Starts the fetch results controller that provides the data for our table.
// 在本类的observeValueForKeyPath:ofObject:change:context: 方法中被调用
// 从 core data 中获取数据,并设置NSFetchedResultsController,并设置其delegate为self
- (void)startFetcher
{
    BOOL                            success;
    NSError *                       error;
    NSFetchRequest *                fetchRequest;
    NSSortDescriptor *              sortDescriptor;

    assert(self.photoGallery != nil);
    assert(self.photoGallery.managedObjectContext != nil);
    
    sortDescriptor = [[[NSSortDescriptor alloc] initWithKey:@"date" ascending:YES] autorelease];
    assert(sortDescriptor != nil);
    
    fetchRequest = [[[NSFetchRequest alloc] init] autorelease];
    assert(fetchRequest != nil);

    [fetchRequest setEntity:self.photoGallery.photoEntity];
    [fetchRequest setFetchBatchSize:20];
    //[fetchRequest setSortDescriptors:[NSArray arrayWithObject:sortDescriptor]];
    [fetchRequest setSortDescriptors:@[sortDescriptor]];
    
    
    assert(self.fetcher == nil);
    self.fetcher = [[[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest
                                                        managedObjectContext:self.photoGallery.managedObjectContext
                                                          sectionNameKeyPath:nil
                                                                   cacheName:nil] autorelease];
    assert(self.fetcher != nil);
    
    self.fetcher.delegate = self;
    
    success = [self.fetcher performFetch:&error];
    if ( ! success ) {
        [[QLog log] logWithFormat:@"%s viewer fetch failed %@", __PRETTY_FUNCTION__, error];
    }
}

// Forces a reload of the table if the view is loaded.
- (void)reloadTable
{
    if (self.isViewLoaded) {
        [self.tableView reloadData];
    }
}

#pragma mark -  implement the KVO observing method

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == &self->_stopBarButtonItem) {
        //根据 photoGallery 是否在运行,来决定在状态条上显示 "开始按钮" 或 "取消按钮"
        
        // Set up the Refresh/Stop button in the toolbar based on the syncing state of the photo gallery.
        assert([keyPath isEqual:@"syncing"]);
        assert(object == self.photoGallery);
        
        [self setupSyncBarButtonItem];

    } else if (context == &self->_statusBarButtonItem) {
        //根据 photoGallery 的运行状态,来决定在状态条上显示什么提示文字.
        // { Not updated / Waiting for network / Updating… / Update cancelled / Update failed }
    
        // Set the status label in the toolbar based on the syncing status from the the photo gallery.
        assert([keyPath isEqual:@"syncStatus"]);
        assert(object == self.photoGallery);
        
        [self setupStatusLabel];

    } else if (context == &self->_photoGallery) {  // mode 层的 photoGallery 发生改变了
        assert([keyPath isEqual:@"photoGallery"]);
        assert(object == self);  //自己监控自己
        
        if ( (change != nil) && [[change objectForKey:NSKeyValueChangeNotificationIsPriorKey] boolValue] ) { //值改变之前的通知
            if (self.photoGallery != nil) {
                
                // The gallery is about to go away.  Remove our observers and shut down the fetched results 
                // controller that provides the data for our table.
            
                [self.photoGallery removeObserver:self forKeyPath:@"syncing"];
                [self.photoGallery removeObserver:self forKeyPath:@"syncStatus"];
                [self.photoGallery removeObserver:self forKeyPath:@"standardDateFormatter"];

                self.fetcher.delegate = nil;
                self.fetcher = nil;
            }
            
        } else {   //值改变之后的通知
            
            if (self.photoGallery == nil) {
            
                // There's no new gallery.  We call -setupStatusLabel and -setupSyncBarButtonItem directly, 
                // and these methods configure us to display the placeholder UI.
                
                //设置状态条上的状态描述文字.
                [self setupStatusLabel];
                //设置为刷新按钮/停止按钮,在状态条上
                [self setupSyncBarButtonItem];
                
            } else {
                // Install a bunch of KVO observers to track various chunks of state and update our UI accordingly.
                // Note that these have NSKeyValueObservingOptionInitial set, so our
                // -observeValueForKeyPath:xxx method is called immediately to set up the initial state.
                // 使用NSKeyValueObservingOptionInitial 选项,将导致立即调用本方法一次
                [self.photoGallery addObserver:self forKeyPath:@"syncing"               options:NSKeyValueObservingOptionInitial context:&self->_stopBarButtonItem];
                [self.photoGallery addObserver:self forKeyPath:@"syncStatus"            options:NSKeyValueObservingOptionInitial context:&self->_statusBarButtonItem];
                [self.photoGallery addObserver:self forKeyPath:@"standardDateFormatter" options:NSKeyValueObservingOptionInitial context:&self->_dateFormatter];
            
                // Set up the fetched results controller that provides the data for our table.
                [self startFetcher];
            }

            // And reload the table to account for any possible change.

            [self reloadTable];
        }
    } else if (context == &self->_dateFormatter) {
        //当时区,或者时间格式发生了改变,tables上显示的时间字符串也要相应的改变.
    
        // Called when the standardDateFormatter property of the gallery changes (which typically
        // happens when the user changes their locale or time zone settings).  We apply this change 
        // to ourselves and then reload the table so that all our cells pick up the new formatter.
        assert([keyPath isEqual:@"standardDateFormatter"]);
        assert(object == self.photoGallery);
        
        self.dateFormatter = self.photoGallery.standardDateFormatter;
        [self reloadTable];

    } else if ( (context == NULL) && [keyPath isEqual:@"showViewer"] ) {  //Qlog view
    
        // Called when the showViewer property of QLog changes (typically because the user has 
        // toggled the setting in the Settings application).  We set the left bar button position 
        // of our navigation item accordingly.
        assert(object == [QLog log]);
        if ( [QLog log].showViewer ) {
            self.navigationItem.leftBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Log" style:UIBarButtonItemStyleBordered target:self action:@selector(showLogAction:)] autorelease];
            assert(self.navigationItem.leftBarButtonItem != nil);
        } else {
            self.navigationItem.leftBarButtonItem = nil;
        }
      
        
    } else if (NO) {   // Disabled because the super class does nothing useful with it.
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
    
}

#pragma mark - View controller stuff


- (void)viewDidLoad
{
    [super viewDidLoad];
    
    // Configure the table view itself.
    self.tableView.rowHeight = kThumbnailSize + 3.0f;

    /*
    // If our view got unloaded, and hence our fetcher got nixed(cancel), we reestablish it on the reload.
    //  iOS 6.0 以后,Views are no longer purged under low-memory conditions, so this method is never called.
    if ( (self.photoGallery != nil) && (self.fetcher == nil) ) {
        [self startFetcher];
    }
    */
}

/*
 iOS 6.0 以后,Views are no longer purged under low-memory conditions,所以这个消息永远也不会被调用了.
- (void)viewDidUnload
{
    [super viewDidUnload];
    
    // There no point having a fetched results controller around if the view is unloaded.
    
    self.fetcher.delegate = nil;
    self.fetcher = nil;
}
*/


#pragma mark - Table view callbacks

// Returns YES if there are no photos to display.  The table view callbacks use this extensively(largely)
// to determine whether to show a placeholder ("No photos") or real content.
- (BOOL)hasNoPhotos
{
    BOOL        result = YES;
    NSArray *   sections;
    NSUInteger  sectionCount;
    
    if (self.fetcher != nil) {
        sections = [self.fetcher sections];
        sectionCount = [sections count];
        if (sectionCount > 0) {
            if ( (sectionCount > 1) || ([[sections objectAtIndex:0] numberOfObjects] != 0) ) {
                result = NO;
            }
        }
    }
    
    return result;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv
{
    NSInteger   result;
    
    assert(tv == self.tableView);
    #pragma unused(tv)
    if ( [self hasNoPhotos] ) {
        result = 1;                                 // if there's no photos, there's 1 section with 1 row that is the placeholder UI
    } else {
        result = [[self.fetcher sections] count];   // if there's photos, base this off(依靠) the fetcher results controller
    }
    return result;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section
{
    #pragma unused(tv)
    #pragma unused(section)

    assert(tv == self.tableView);

    NSInteger   result;
    if ( [self hasNoPhotos] ) {
        result = 1;                                 // if there's no photos, there's 1 section with 1 row that is the placeholder UI
    } else {
        NSArray *   sections;                       // if there's photos, base this off the fetcher results controller

        sections = [self.fetcher sections];
        assert(sections != nil);
        assert(section >= 0);
        assert( (NSUInteger) section < [sections count] );
        result = [[sections objectAtIndex:section] numberOfObjects];
    }
    return result;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    #pragma unused(tv)
    #pragma unused(indexPath)

    assert(tv == self.tableView);
    assert(indexPath != NULL);

    UITableViewCell *   result;
    if ( [self hasNoPhotos] ) {
        
        // There are no photos to display; return a cell that simple says "No photos".
        
        result = [self.tableView dequeueReusableCellWithIdentifier:@"cell"];
        if (result == nil) {
            result = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"cell"] autorelease];
            assert(result != nil);
            
            result.textLabel.text = @"There are No Photos";
            result.textLabel.textColor = [UIColor purpleColor];
            result.textLabel.textAlignment = UITextAlignmentCenter;
        }
        result.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        PhotoCell *     cell;
        Photo *         photo;

        // Return a cell that displays the appropriate photo.  Note that we just tell 
        // the cell what photo to display, and it takes care of displaying the right 
        // stuff (via the miracle of KVO).

        photo = [self.fetcher objectAtIndexPath:indexPath];
        assert([photo isKindOfClass:[Photo class]]);
        
        cell = (PhotoCell *) [self.tableView dequeueReusableCellWithIdentifier:@"PhotoCell"];
        if (cell != nil) {
            assert([cell isKindOfClass:[PhotoCell class]]);
        } else {
            cell = [[[PhotoCell alloc] initWithReuseIdentifier:@"PhotoCell"] autorelease];
            
            assert(cell != nil);
            assert(cell.selectionStyle == UITableViewCellSelectionStyleDefault);
            
            cell.accessoryType  = UITableViewCellAccessoryDisclosureIndicator;
        }
        cell.photo = photo;
        cell.dateFormatter = self.dateFormatter;
        
        result = cell;
    }

    return result;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    #pragma unused(tv)
    #pragma unused(indexPath)

    assert(tv == self.tableView);
    assert(indexPath != NULL);
    // assert(indexPath.section == 0);
    // assert(indexPath.row < ?);

    if ( [self hasNoPhotos] ) {
        [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
    } else {
        Photo *                         photo;
        PhotoDetailViewController *     vc;

        // Push a photo detail view controller to display the bigger version of the photo.

        photo = [self.fetcher objectAtIndexPath:indexPath];
        assert([photo isKindOfClass:[Photo class]]);
        
        vc = [[[PhotoDetailViewController alloc] initWithPhoto:photo photoGallery:self.photoGallery] autorelease];
        assert(vc != nil);
        
        [self.navigationController pushViewController:vc animated:YES];
    }
}

#pragma mark - Fetched results controller callbacks

// A delegate callback called by the fetched results controller when its content changes.
// If anything interesting happens (that is, an insert, delete or move), we respond by reloading the entire table.
// This is rather a heavy-handed approach, but I found it difficult to correctly handle the updates.
// Also, the insert, delete and move aren't on the critical performance path (which is scrolling through the list loading thumbnails),
// so I can afford to(支付的起) keep it simple.
- (void)controller:(NSFetchedResultsController *)controller
   didChangeObject:(id)anObject
       atIndexPath:(NSIndexPath *)indexPath
     forChangeType:(NSFetchedResultsChangeType)type
      newIndexPath:(NSIndexPath *)newIndexPath
{
    assert(controller == self.fetcher);
    #pragma unused(controller)
    #pragma unused(anObject)
    #pragma unused(indexPath)
    #pragma unused(newIndexPath)

    switch (type) {
        case NSFetchedResultsChangeInsert: {
            [self reloadTable];
        } break;
        case NSFetchedResultsChangeDelete: {
            [self reloadTable];
        } break;
        case NSFetchedResultsChangeMove: {
            [self reloadTable];
        } break;
        case NSFetchedResultsChangeUpdate: {
            // do nothing
        } break;
        default: {
            assert(NO);
        } break;
    }
}

#pragma mark - UI wrangling

// Set the status label in the toolbar based on the syncing status from the the photoGallery.
- (void)setupStatusLabel
{
    assert(self.statusBarButtonItem != nil);

    UILabel *  statusLabel = (UILabel *) self.statusBarButtonItem.customView; //在 initWithPhotoGallery: 中初始化为 UILabel*
    assert([statusLabel isKindOfClass:[UILabel class]]);

    if (self.photoGallery == nil) {
        statusLabel.text = @"Tap Setup to configure"; //程序第一次开始运行时的提示文字
    } else {
        statusLabel.text = self.photoGallery.syncStatus;
    }
}

// Set up the Refresh/Stop button in the toolbar based on the syncing state of the photo gallery.
- (void)setupSyncBarButtonItem
{
    assert(self.fixedBarButtonItem != nil);
    assert(self.statusBarButtonItem != nil);
    assert(self.flexBarButtonItem != nil);
    assert(self.stopBarButtonItem != nil);

    if ( (self.photoGallery != nil) && self.photoGallery.isSyncing ) {
        self.toolbarItems = [NSArray arrayWithObjects:self.fixedBarButtonItem, self.statusBarButtonItem, self.flexBarButtonItem, self.stopBarButtonItem, nil];
    } else {
        self.refreshBarButtonItem.enabled = (self.photoGallery != nil);
        self.toolbarItems = [NSArray arrayWithObjects:self.fixedBarButtonItem, self.statusBarButtonItem, self.flexBarButtonItem, self.refreshBarButtonItem, nil];
    }
}


#pragma mark - Actions

- (void)showLogAction:(id)sender
    // Called when the user taps the Log button.  It just presents the log 
    // view controller.
{
    #pragma unused(sender)
    QLogViewer *            vc;
    
    vc = [[[QLogViewer alloc] init] autorelease];
    assert(vc != nil);
    
    [vc presentModallyOn:self animated:YES];
}



- (IBAction)stopAction:(id)sender
    // Called when the user taps the Stop button.  It just passes the command 
    // on to the photo gallery.
{
    #pragma unused(sender)
    [self.photoGallery stopSync];
}

- (IBAction)refreshAction:(id)sender
    // Called when the user taps the Refresh button.  It just passes the command 
    // on to the photo gallery.
{
    #pragma unused(sender)
    [self.photoGallery startSync];
}

@end
