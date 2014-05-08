#import "MakeThumbnailOperation.h"

/*
    o 本类继承自 NSOperation,  通过重写 main 方法 来定义自己的 NSOperation.
        这种方法非常简单，开发者不需要管理一些状态属性(例如isExecuting 和 isFinished )，当 main 方法返回的时候，这个NSOperation就结束了
 */


@implementation MakeThumbnailOperation

@synthesize imageData     = _imageData;
@synthesize MIMEType      = _MIMEType;
@synthesize thumbnailSize = _thumbnailSize;
@synthesize thumbnail     = _thumbnail;

/*!
 *  初始化一个 resize operation
 *
 *  @param imageData  从网络下载下来的 image
 *  @param MIMEType  HTTP 回应的 image MIMEType格式
 *
 *  @return 返回一个本类的实例
 */
- (id)initWithImageData:(NSData *)imageData MIMEType:(NSString *)MIMEType
{
    assert(imageData != nil);
    assert(MIMEType != nil);
    
    self = [super init];
    if (self != nil) {
        self->_imageData = [imageData copy];
        self->_MIMEType  = [MIMEType  copy];
        self->_thumbnailSize = 32.0f;
    }
    return self;
}

- (void)dealloc
{
    CGImageRelease(self->_thumbnail);
    [self->_MIMEType release];
    [self->_imageData release];
    [super dealloc];
}

#pragma mark - 入列后开始执行的函数
// 本方法,在本 operation 的实例添加的一个 queue 后调用执行
- (void)main
{
    // Latch thumbnailSize for performance, and also to prevent it changing out from underneath us.
    CGFloat             thumbnailSize;
    thumbnailSize = self.thumbnailSize;

    assert(self.imageData != nil);
    assert(self.MIMEType != nil);
    
    // Set up the source CGImage.
    CGDataProviderRef   provider;
    provider = CGDataProviderCreateWithCFData( (CFDataRef) self.imageData);
    assert(provider != NULL);

    CGImageRef          sourceImage;
    if ( [self.MIMEType isEqual:@"image/jpeg"] ) {
        sourceImage = CGImageCreateWithJPEGDataProvider(provider, NULL, true, kCGRenderingIntentDefault);
    } else if ( [self.MIMEType isEqual:@"image/png"] ) {
        sourceImage =  CGImageCreateWithPNGDataProvider(provider, NULL, true, kCGRenderingIntentDefault);
    } else {
        sourceImage = NULL;
    }
    
    // Render it to a bitmap context and then create an image from that context.
    
    if (sourceImage != NULL) {
        static const CGFloat kWhite[4] = {0.0f, 0.0f, 0.0f, 1.0f};
        CGColorRef      white;
        CGContextRef    context;
        CGColorSpaceRef space;

        space = CGColorSpaceCreateDeviceRGB();
        assert(space != NULL);

        white = CGColorCreate(space, kWhite);
        assert(white != NULL);

        // Create the context that's thumbnailSize x thumbnailSize.
        context = CGBitmapContextCreate(NULL, thumbnailSize, thumbnailSize, 8, 0, space, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        if (context != NULL) {
            CGRect  r;
            
            // Make sure anything we don't cover comes out white.  While the next 
            // steps ensures that we cover the entire image, there's a possibility 
            // that we're dealing with a transparent PNG.
            
            CGContextSetFillColorWithColor(context, white);
            CGContextFillRect(context, CGRectMake(0.0f, 0.0f, thumbnailSize, thumbnailSize));

            // Calculate the drawing rectangle so that the image fills the entire 
            // thumbnail.  That is, for a tall image, we scale it so that the 
            // width matches thumbnailSize and the it's centred vertically.  
            // Similarly for a wide image.

            r = CGRectZero;
            r.size.width  = CGImageGetWidth(sourceImage);
            r.size.height = CGImageGetWidth(sourceImage);
            if (r.size.height > r.size.width) {
                // tall image
                r.size.height = (r.size.height / r.size.width) * thumbnailSize;
                r.size.width  = thumbnailSize;
                r.origin.y = - ((r.size.height - thumbnailSize) / 2);
            } else {
                // wide image
                r.size.width  = (r.size.width / r.size.height) * thumbnailSize;
                r.size.height = thumbnailSize;
                r.origin.x = - ((r.size.width - thumbnailSize) / 2);
            }
            
            // Draw the source image and get then create the thumbnail from the 
            // context. 
            
            CGContextDrawImage(context, r, sourceImage);
            
            self->_thumbnail = CGBitmapContextCreateImage(context);
            assert(self->_thumbnail != NULL);
        }
        
        CGContextRelease(context);
        CGColorSpaceRelease(space);
        CGColorRelease(white);
    }

    CGImageRelease(sourceImage);
    CGDataProviderRelease(provider);
}

@end
