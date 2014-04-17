#import <CoreData/CoreData.h>
/*
    This class manages a collection of photos from a gallery on the network at a 
    specified URL.  You construct it with the URL of the gallery.  It then attempts 
    to find a corresponding gallery cache in the caches directory.  If not is found, 
    it creates a new blank one.  Within that gallery cache there is a Core Data 
    database that holds the model objects and a "Photos" directory that stores actual 
    photos.  Thus this class owns the Core Data managed object context that's used by 
    other parts of the application, and it exports certain aspects of that context 
    to help out things like the PhotoGalleryViewController.
    
    This class takes care of downloading the XML specification of the photo 
    gallery and syncing it with our local view of the gallery held in our Core Data 
    database, adding any photos we haven't seen before and removing any photos that 
    are no longer in the gallery.
*/

enum PhotoGallerySyncState {
    kPhotoGallerySyncStateStopped, 
    kPhotoGallerySyncStateGetting, 
    kPhotoGallerySyncStateParsing, 
    kPhotoGallerySyncStateCommitting
};
typedef enum PhotoGallerySyncState PhotoGallerySyncState;

@class PhotoGalleryContext;
@class RetryingHTTPOperation;
@class GalleryParserOperation;

@interface PhotoGallery : NSObject {
    NSString *                      _galleryURLString;
    NSUInteger                      _sequenceNumber;
    
    PhotoGalleryContext *           _galleryContext;
    NSEntityDescription *           _photoEntity;
    NSTimer *                       _saveTimer;

    NSDate *                        _lastSyncDate;
    NSError *                       _lastSyncError;
    NSDateFormatter *               _standardDateFormatter;
    PhotoGallerySyncState           _syncState;
    RetryingHTTPOperation *         _getOperation;
    GalleryParserOperation *        _parserOperation;
}

#pragma mark * Start up and shut down

+ (void)applicationStartup;
    // Called by the application delegate at startup time.  This takes care of 
    // various bits of bookkeeping, including resetting the cache of photos 
    // if that debugging option has been set.

- (id)initWithGalleryURLString:(NSString *)galleryURLString;

@property (nonatomic, copy,   readonly ) NSString *                 galleryURLString;

- (void)start;
    // Starts up the gallery (finds or creates a cache database and kicks off the initial sync).

- (void)save;
- (void)stop;
    // Called by the application delegate at -applicationDidEnterBackground: and 
    // -applicationWillTerminate: time, respectively.  Note that it's safe, albeit a little 
    // weird, to call -save and -stop even if you haven't called -start.
    //
    // -stop is also called by the application delegate when it switches to a new gallery.

#pragma mark * Core Data accessors

// These properties are exported for the benefit of the PhotoGalleryViewController class, which 
// uses them to set up its fetched results controller.

@property (nonatomic, retain, readonly ) NSManagedObjectContext *   managedObjectContext;       // observable
@property (nonatomic, retain, readonly ) NSEntityDescription *      photoEntity;
    // Returns the entity description for the "Photo" entity in our database.

#pragma mark * Syncing

// These properties allow user interface controllers to learn about and control the 
// state of the syncing process.

@property (nonatomic, assign, readonly, getter=isSyncing) BOOL      syncing;                    // observable, YES if syncState > kPhotoGallerySyncStateStopped
@property (nonatomic, assign, readonly ) PhotoGallerySyncState      syncState;
@property (nonatomic, copy,   readonly ) NSString *                 syncStatus;                 // observable, user-visible sync status
@property (nonatomic, copy,   readonly ) NSDate *                   lastSyncDate;               // observable, date of last /successful/ sync
@property (nonatomic, copy,   readonly ) NSError *                  lastSyncError;              // observable, error for last sync

@property (nonatomic, copy,   readonly ) NSDateFormatter *          standardDateFormatter;      // observable, date formatter for general purpose use

- (void)startSync;
    // Force a sync to start right now.  Does nothing if a sync is already in progress.
    
- (void)stopSync;
    // Force a sync to stop right now.  Does nothing if a no sync is in progress.

@end
