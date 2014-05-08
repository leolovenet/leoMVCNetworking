#import "PhotoCell.h"
#import "Photo.h"

@implementation PhotoCell


@synthesize dateFormatter = _dateFormatter;
@synthesize photo         = _photo;

//初始化这个 Cell
- (id)initWithReuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
    if (self != nil) {
    
        // Observe a bunch of our own properties so that the UI adjusts to any changes.
        // 本类对象在初始化时, photo property 为 nil.
        
        // 在 Controller 层的 PhotoGalleryViewController.m 中,对其属性 self.photoGallery 进行了监控,
        // 当得知自己的 self.photogallery 内Core Data中的数据发生了变化时(从网络获得数据后新加,或者更新), 系统会调用PhotoGalleryViewController.m类
        // 实现的 NSFetchedResultsControllerDelegate 协议方法 – controller:didChangeObject:atIndexPath:forChangeType:newIndexPath:,在此方法中,会重新加载 tableView,
        // 从而调用 PhotoGalleryViewController.m 类 tableView:cellForRowAtIndexPath: 生成新的 tableview
        // 对于新生成的 tableview 就需要重新创建本类的实例,填充 tablecell ,展示每个 photo 对象.
        
        // 在创建本类实例时,会把从 Core Data 中获得的 photo 对象赋值给本类的 self.photo.
        // 而下面的代码添加对self.photo三个属性的监控,这样赋值操作,会使本类得到通知,调用本类的observeValueForKeyPath:ofObject:change:context:方法,
        // 在此方法中,会将self.imageView.image  = self.photo.thumbnailImage;
        
        // 如果是初次访问 Photo 类的 self.photo.thumbnailImage 方法,它会暂时将一个 placeholder 的图片返回,并启用异步的加载 operation ,
        // 从网络请求 thumbnail,如果下载成功完成,会紧接着启用 resize operation. 将刚刚下载的 thumbnailImage 重新设置尺寸,
        // 完成后将结果存入 CoreData ,并赋值给self.photo.thumbnailImage.
        // 此时,本类监控 self.photo.thumbnailImage,得到通知,重新赋值 Image,更新 UI.

        [self addObserver:self forKeyPath:@"photo.displayName"    options:0 context:&self->_photo];
        [self addObserver:self forKeyPath:@"photo.date"           options:0 context:&self->_dateFormatter];
        [self addObserver:self forKeyPath:@"photo.thumbnailImage" options:0 context:&self->_photo];
        
        //监控自己的 dateFormatter 属性的改变,此值在PhotoViewcontroller.m 生成 table 时赋值,当此值可能由于时区,或时间格式发生了改变时,UI 也应该发生改变.
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

//关闭对 dateFormatter 的自动 KVO 通知
+ (BOOL)automaticallyNotifiesObserversOfDateFormatter
{
    return NO;
}

- (void)setDateFormatter:(NSDateFormatter *)newValue
{
    if (newValue != self->_dateFormatter) {  //只有在 date formatter 的值真正发生改变的时候
        [self willChangeValueForKey:@"dateFormatter"];
        [self->_dateFormatter release];
        self->_dateFormatter = [newValue retain];
        [self  didChangeValueForKey:@"dateFormatter"];
    }
}


// Called when various properties of the photo change; updates the cell accordingly.
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == &self->_photo) {
        assert(object == self);
        
        if ([keyPath isEqual:@"photo.displayName"]) {

            //本类实例在初始化时,photo 属性为 nil.
            if (self.photo == nil) {                
                self.textLabel.text   = nil;
            } else {
                self.textLabel.text   = self.photo.displayName;
            }

            // iOS 3 has a bug where, if you set the text of a cell's label to something longer 
            // than the existing text, it doesn't expand the label to accommodate(make fit for) the longer
            // text.  The end result is that the text gets needlessly(without need) truncated.  We fix
            // this by triggering a re-layout whenever we change the text.
            //[self setNeedsLayout];
            
        } else if ([keyPath isEqual:@"photo.thumbnailImage"]) {
            
            //本类实例在初始化时,photo 属性为 nil.
            if (self.photo == nil) {
                self.imageView.image  = nil;
            } else {
                
                // 如果是初次方法Photo 类的 self.photo.thumbnailImage 方法,它会暂时将一个 placeholder 的图片返回,并启用异步的加载 operation ,
                // 从网络请求 thumbnail, 如果下载成功完成,会紧接着启用 resize operation. 将刚刚下载的 thumbnailImage 重新设置尺寸,
                // 完成后将结果存入 CoreData ,并赋值给self.photo.thumbnailImage.
                // 此时,本类监控 self.photo.thumbnailImage,得到通知,重新赋值 Image,更新 UI.
                self.imageView.image  = self.photo.thumbnailImage;
            }
        
        } else {
            assert(NO);
        }
        
    } else if (context == &self->_dateFormatter) {  //当时区或时间格式放生改变,更改 UI 上的时间字符串

        assert(object == self);
        assert([keyPath isEqual:@"photo.date"] || [keyPath isEqual:@"dateFormatter"]);
        
        NSString *  dateText = nil;
        if (self.photo != nil) { //本 Cell 不是空的 Cell 时
            if (self.dateFormatter == nil) {
                // If there's no date formatter, just use the date's description.  This is 
                // somewhat lame, and you wouldn't want to run this code path in general.
                dateText = [self.photo.date description];
            } else {
                dateText = [self.dateFormatter stringFromDate:self.photo.date];
            }
        }
        self.detailTextLabel.text = dateText;
        
        //[self setNeedsLayout];      // see comment above
        
    } else if (NO) {   // Disabled because the super class does nothing useful with it.
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@end
