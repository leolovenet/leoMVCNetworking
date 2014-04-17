#import "PhotoCell.h"
#import "Photo.h"

@implementation PhotoCell

- (id)initWithReuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
    if (self != nil) {
    
        // Observe a bunch of our own properties so that the UI adjusts to any changes.
    
        [self addObserver:self forKeyPath:@"photo.displayName"    options:0 context:&self->_photo];
        [self addObserver:self forKeyPath:@"photo.date"           options:0 context:&self->_dateFormatter];
        [self addObserver:self forKeyPath:@"photo.thumbnailImage" options:0 context:&self->_photo];
        [self addObserver:self forKeyPath:@"dateFormatter"        options:0 context:&self->_dateFormatter];
    }
    return self;
}

- (void)dealloc
{
    // Remove our observers.
    
    [self removeObserver:self forKeyPath:@"photo.displayName"];
    [self removeObserver:self forKeyPath:@"photo.date"];
    [self removeObserver:self forKeyPath:@"photo.thumbnailImage"];
    [self removeObserver:self forKeyPath:@"dateFormatter"];

    // Clean up our memory.
    
    [self->_photo release];
    [self->_dateFormatter release];

    [super dealloc];
}

// Because we self-observe dateFormatter in order to update after a locale change, 
// we only want to fire KVO notifications if the date formatter actually changes (which 
// is infrequent in day-to-day operations.  So we override the setter and handle the 
// KVO notifications ourself.

@synthesize dateFormatter = _dateFormatter;

+ (BOOL)automaticallyNotifiesObserversOfDateFormatter
{
    return NO;
}

- (void)setDateFormatter:(NSDateFormatter *)newValue
{
    if (newValue != self->_dateFormatter) {
        [self willChangeValueForKey:@"dateFormatter"];
        [self->_dateFormatter release];
        self->_dateFormatter = [newValue retain];
        [self  didChangeValueForKey:@"dateFormatter"];
    }
}

@synthesize photo         = _photo;

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
    // Called when various properties of the photo change; updates the cell accordingly.
{
    if (context == &self->_photo) {
        assert(object == self);
        
        if ([keyPath isEqual:@"photo.displayName"]) {
            if (self.photo == nil) {
                self.textLabel.text   = nil;
            } else {
                self.textLabel.text   = self.photo.displayName;
            }

            // iOS 3 has a bug where, if you set the text of a cell's label to something longer 
            // than the existing text, it doesn't expand the label to accommodate the longer 
            // text.  The end result is that the text gets needlessly truncated.  We fix 
            // this by triggering a re-layout whenever we change the text.
            
            [self setNeedsLayout];
        } else if ([keyPath isEqual:@"photo.thumbnailImage"]) {
            if (self.photo == nil) {
                self.imageView.image  = nil;
            } else {
                self.imageView.image  = self.photo.thumbnailImage;
            }
        } else {
            assert(NO);
        }
    } else if (context == &self->_dateFormatter) {
        NSString *  dateText;

        assert(object == self);
        assert([keyPath isEqual:@"photo.date"] || [keyPath isEqual:@"dateFormatter"]);
        
        dateText = nil;
        if (self.photo != nil) {
            if (self.dateFormatter == nil) {
                // If there's no date formatter, just use the date's description.  This is 
                // somewhat lame, and you wouldn't want to run this code path in general.
                dateText = [self.photo.date description];
            } else {
                dateText = [self.dateFormatter stringFromDate:self.photo.date];
            }
        }
        self.detailTextLabel.text = dateText;
        [self setNeedsLayout];      // see comment above
    } else if (NO) {   // Disabled because the super class does nothing useful with it.
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@end
