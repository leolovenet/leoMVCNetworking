#import "QReachabilityOperation.h"

@interface QReachabilityOperation ()

// read/write versions of public properties
@property (assign, readwrite) NSUInteger    flags;

static void ReachabilityCallback(
    SCNetworkReachabilityRef    target,
    SCNetworkReachabilityFlags  flags,
    void *                      info
);

- (void)reachabilitySetFlags:(NSUInteger)newValue;

@end




@implementation QReachabilityOperation

@synthesize hostName         = _hostName;
@synthesize flagsTargetMask  = _flagsTargetMask;
@synthesize flagsTargetValue = _flagsTargetValue;
@synthesize flags            = _flags;



- (id)initWithHostName:(NSString *)hostName
{
    assert(hostName != nil);
    self = [super init];
    if (self != nil) {
        self->_hostName         = [hostName copy];
        //如果可以达到,或者,可以到达但是需要首先建立连接(比如提供用户名密码)
        self->_flagsTargetMask  = kSCNetworkReachabilityFlagsReachable | kSCNetworkReachabilityFlagsInterventionRequired;
        self->_flagsTargetValue = kSCNetworkReachabilityFlagsReachable; //期望的变化状态,如果网络变化状态和此值一样,就回调函数,退出本 operation
    }
    return self;
}

- (void)dealloc
{
    [self->_hostName release];
    assert(self->_ref == NULL);
    [super dealloc];
}




#pragma mark  - QRunLoopOperation (Categories)  methods  overrides 本类实例对象被调用的第一个方法
// Called by QRunLoopOperation when the operation starts.  This is our opportunity
// to install our run loop callbacks, which is exactly what we do.  The only tricky
// thing is that we have to schedule the reachability ref to run in all of the
// run loop modes specified by our client.


- (void)operationDidStart
{
    Boolean                         success;
    SCNetworkReachabilityContext    context = { 0, self, NULL, NULL, NULL };
    

    assert(self->_ref == NULL);
    //为我们的目标主机,创建一个 reachability reference
    self->_ref = SCNetworkReachabilityCreateWithName(NULL, [self.hostName UTF8String]);
    assert(self->_ref != NULL);

    // 当网络环境改变时,指定回调函数
    success = SCNetworkReachabilitySetCallback(self->_ref, ReachabilityCallback, &context);
    assert(success);

    //安排到 runloop 执行
    for (NSString * mode in self.actualRunLoopModes) {
        success = SCNetworkReachabilityScheduleWithRunLoop(self->_ref, CFRunLoopGetCurrent(), (CFStringRef) mode);
        assert(success);
    }
}
// Called by QRunLoopOperation when the operation finishes.  We just clean up
// our reachability ref.
- (void)operationWillFinish
{
    Boolean success;
    
    if (self->_ref != NULL) {
        
        //取消 runLoop
        for (NSString * mode in self.actualRunLoopModes) {
            success = SCNetworkReachabilityUnscheduleFromRunLoop(self->_ref, CFRunLoopGetCurrent(), (CFStringRef) mode);
            assert(success);
        }
        
        //取消监控
        success = SCNetworkReachabilitySetCallback(self->_ref, NULL, NULL);
        assert(success);
        
        CFRelease(self->_ref);
        self->_ref = NULL;
    }
}




#pragma mark - callback
// Called by the system when the reachability flags change.  We just forward the flags to our Objective-C code.
static void ReachabilityCallback(
    SCNetworkReachabilityRef    target,
    SCNetworkReachabilityFlags  flags,
    void *                      info
)
{
    QReachabilityOperation *    obj;
    obj = (QReachabilityOperation *) info;
    
    assert([obj isKindOfClass:[QReachabilityOperation class]]);
    assert(target == obj->_ref);
    #pragma unused(target)
    
    [obj reachabilitySetFlags:flags];
}


// Called when the reachability flags change.  We just store the flags and then
// check to see if the flags meet our target criteria, in which case we stop the
// operation.
- (void)reachabilitySetFlags:(NSUInteger)newValue
{
    assert( [NSThread currentThread] == self.actualRunLoopThread );
    
    self.flags = newValue;
    if ( (self.flags & self.flagsTargetMask) == self.flagsTargetValue ) { //如果结果是和我们期望的值一样的话
        [self finishWithError:nil];  //导致调用本类的 - (void)operationWillFinish 函数
    }
}





@end
