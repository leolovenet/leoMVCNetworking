#import <UIKit/UIKit.h>

int main(int argc, char **argv)
{
    int                 retVal;
    NSAutoreleasePool * pool;
    
    pool = [[NSAutoreleasePool alloc] init];
    assert(pool != nil);
    
    retVal = UIApplicationMain(argc, argv, nil, nil);
    
    [pool drain];

    return retVal;
}
