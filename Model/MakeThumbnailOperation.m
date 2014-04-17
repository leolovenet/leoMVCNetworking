#import "MakeThumbnailOperation.h"

@implementation MakeThumbnailOperation

- (id)initWithImageData:(NSData *)imageData MIMEType:(NSString *)MIMEType
    // See comment in header.
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

@synthesize imageData     = _imageData;
@synthesize MIMEType      = _MIMEType;

@synthesize thumbnailSize = _thumbnailSize;

@synthesize thumbnail     = _thumbnail;

- (void)main
{
    CGDataProviderRef   provider;
    CGImageRef          sourceImage;
    CGFloat             thumbnailSize;

    // Latch thumbnailSize for performance, and also to prevent it changing out from underneath us.
    
    thumbnailSize = self.thumbnailSize;

    assert(self.imageData != nil);
    assert(self.MIMEType != nil);
    
    // Set up the source CGImage.
    
    provider = CGDataProviderCreateWithCFData( (CFDataRef) self.imageData);
    assert(provider != NULL);
    
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
