#import "RecursiveDeleteOperation.h"

@interface RecursiveDeleteOperation ()

// read/write versions of public properties
@property (copy,   readwrite) NSError *     error;

@end


@implementation RecursiveDeleteOperation

@synthesize paths = _paths;
@synthesize error = _error;

- (id)initWithPaths:(NSArray *)paths
    // See comment in header.
{
    assert(paths != nil);
    self = [super init];
    if (self != nil) {
        self->_paths = [paths copy];
        assert(self->_paths != nil);
    }
    return self;
}

- (void)dealloc
{
    [self->_paths release];
    [self->_error release];
    [super dealloc];
}

//因为是简单的添加到 NSOperationQueue 中的 operation ,这里只是简单的重写 main 函数就可以了.
- (void)main
{
    BOOL                success;
    NSFileManager *     fileManager;
    NSError *           error;
    
    fileManager = [NSFileManager defaultManager];
    assert(fileManager != nil);
    
    success = YES;  // necessary when self.paths is empty, which is a wacky corner case but I decided to allow it
    for (NSString * path in self.paths) {
        success = [fileManager removeItemAtPath:path error:&error];
        if ( ! success ) {
            break;
        }
    }
    
    if ( ! success ) {
        self.error = error;
    }
}

@end
