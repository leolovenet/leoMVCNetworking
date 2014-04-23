#import "RetryingHTTPOperation.h"
#import "NetworkManager.h"
#import "Logging.h"
#import "QHTTPOperation.h"
#import "QReachabilityOperation.h"

// When one operation completes it posts the following notification.  Other operations 
// listen for that notification and, if the host name matches, expedite their retry. 
// This means that, if one request succeeds, subsequent requests will retry quickly.
// 如果一个操作完成,它 post 下面的通知. 其他的操作监听这个通知, 如果 hostName 匹配,加速他们的请求尝试
// 这意味着,如果一个请求成功, 随后的请求将非常快的开始

static NSString * kRetryingHTTPOperationTransferDidSucceedNotification = @"com.apple.dts.kRetryingHTTPOperationTransferDidSucceedNotification";
static NSString * kRetryingHTTPOperationTransferDidSucceedHostKey = @"hostName";

@interface RetryingHTTPOperation ()

// read/write versions of public properties
@property (assign, readwrite) RetryingHTTPOperationState    retryState;
@property (assign, readwrite) RetryingHTTPOperationState    retryStateClient;
@property (assign, readwrite) BOOL                          hasHadRetryableFailure;
@property (assign, readwrite) NSUInteger                    retryCount;
@property (copy,   readwrite) NSData *                      responseContent;   

// private properties
@property (copy,   readwrite) NSHTTPURLResponse *           response;
@property (retain, readwrite) QHTTPOperation *              networkOperation;  //被管理的真正执行 HTTP GET 的方法实例
@property (retain, readwrite) NSTimer *                     retryTimer;
@property (retain, readwrite) QReachabilityOperation *      reachabilityOperation;
@property (assign, readwrite) BOOL                          notificationInstalled;

- (void)startRequest;
- (void)startReachabilityReachable:(BOOL)reachable;
- (void)startRetryAfterTimeInterval:(NSTimeInterval)delay;

@end


/*
 
 本类继承自 QRunLoopOperation , 因此 本类也是一个 Operation.
 但是本类属于在 QHTTPOperation 上层的网络管理队列里执行的 Operation.直接被Model 层的PhotoGallery类调用.
    (1) 本类的实例对象将被添加到 NetworkManger 的 网络管理队列(queueForNetworkManagement) 上执行
    (2) QHTTPOperation/QReachabilityOperation 等操作是被添加到 NetworkManger 的网络传输队列(queueForNetworkTransfers),属于更下层的操作.

*/


@implementation RetryingHTTPOperation


#pragma mark - NS_DESIGNATED_INITIALIZER
- (id)initWithRequest:(NSURLRequest *)request
{
    assert(request != nil);
    
    // Certain HTTP methods are idempotent, meaning that doing the request N times is equivalent to doing it once.
    // 创建一个 http 请求是 幂等(idempotent), 意思是 实现这个请求 N 次,等于实现它一次.
    
    // As this class will automatically retry the request,
    // the requests method should be idempotent lest the automatic retries cause problems.
    // 本类将自动重新尝试请求,这请求方法应该是 幂等 的,以免自动重新尝试导致问题.
    
    // For example, you could imagine a situation where an automatically retried POST might 
    // cause a gazillion identical messages to show up on a bulletin board wall site.
    // 比如, 你可以想象这样的场景, 当一个自动重新尝试 POST,可能导致极大的完全一样的消息现实在公告墙站点上.
    
    #if ! defined(NDEBUG)
        static NSSet * sIdempotentHTTPMethods;
        
        if (sIdempotentHTTPMethods == nil) {
            @synchronized ([self class]) {
                if (sIdempotentHTTPMethods == nil) {
                    sIdempotentHTTPMethods = [[NSSet alloc] initWithObjects:@"GET", @"HEAD", @"PUT", @"DELETE", @"OPTIONS", @"TRACE", nil];
                }
            }
        }
        assert([sIdempotentHTTPMethods containsObject:[request HTTPMethod]]);
    #endif

    self = [super init];
    if (self != nil) {
        @synchronized ([self class]) {
            static NSUInteger sSequenceNumber;// 默认是0
            self->_sequenceNumber = sSequenceNumber;  // 表示第几个请求,每次新初始化一个本类对象,这个值就加1
            sSequenceNumber += 1;
        }
        self->_request = [request copy];  //初始化 NSURLRequest
        assert(self->_retryState == kRetryingHTTPOperationStateNotStarted); //应该为默认值
    }
    
    return self;
}

- (void)dealloc
{
    [self->_request release]; //释放 NSURLRequest
    [self->_acceptableContentTypes release];
    [self->_responseFilePath release];
    [self->_response release];
    [self->_responseContent release];
    
    assert(self->_networkOperation == nil); // 释放被管理的真正执行 HTTP GET的方法实例
    assert(self->_retryTimer == nil);
    assert(self->_reachabilityOperation == nil);
    
    [super dealloc];
}

#pragma mark - Properties

@synthesize request = _request;
@synthesize retryStateClient       = retryStateClient;
@synthesize hasHadRetryableFailure = _hasHadRetryableFailure;  //是否已经进行过失败重试了
@synthesize acceptableContentTypes = _acceptableContentTypes;
@synthesize responseFilePath       = _responseFilePath;
@synthesize response               = _response;
@synthesize networkOperation       = _networkOperation;  //被管理的真正执行 HTTP GET的方法实例
@synthesize retryTimer             = _retryTimer;
@synthesize retryCount             = _retryCount;
@synthesize reachabilityOperation  = _reachabilityOperation;
@synthesize notificationInstalled  = _notificationInstalled;  //如果一个下载成功后,立即通知其他此 server 的下载重新尝试的notification callback 是否已经安装了
@synthesize responseContent = _responseContent;               //URL 返回的内容


- (RetryingHTTPOperationState)retryState
{
    return self->_retryState;
}

/*!
 *  我们并不需要非得需要重写这个 setter 方法, 但是,这里是刷新更新状态的好地方.
 *  We don't really need this custom setter, but it's a great way to flush
 *  out redundant update problems.
 *  本方法在被添加到 NetworkManger 的 网络管理队列(queueForNetworkManagement) 上执行
 *  @param newState 即将赋值给self->_retryState新值
 */
- (void)setRetryState:(RetryingHTTPOperationState)newState
{
    assert([self isActualRunLoopThread]);
    assert(newState != self->_retryState);
    self->_retryState = newState;
    
    [self performSelectorOnMainThread:@selector(syncRetryStateClient) withObject:nil waitUntilDone:NO];
}

/*!
 *  在主线程上执行同步 self.retryStateClient
 *  本方法在被添加到 NetworkManger 的 网络管理队列(queueForNetworkManagement) 上执行
 */
- (void)syncRetryStateClient
{
    assert([NSThread isMainThread]);
    self.retryStateClient = self.retryState;
}

- (NSString *)responseMIMEType
{
    NSString *          result;
    NSHTTPURLResponse * response;
    
    result = nil;
    response = self.response;
    if (response != nil) {
        result = [response MIMEType];
    }
    return result;
}

#pragma mark - Utilities

/*!
 *  Sets the hasHadRetryableFailure on the main thread.
 *  这个 property 总是在 main 线程上改变. 这使 main 线程代码很容易展示 'retrying' 的用户界面.
 */
- (void)setHasHadRetryableFailureOnMainThread
{
    assert([NSThread isMainThread]);
    assert( ! self.hasHadRetryableFailure );
    
    self.hasHadRetryableFailure = YES;
}

/*!
 *
 *  Returns YES if the supplied error is fatal(致命的),
 *  that is, it can't be meaningfully retried.
 *
 *  @param error
 *
 *  @return YES or NO
 */
- (BOOL)shouldRetryAfterError:(NSError *)error
{
    BOOL    shouldRetry;
    
    //如果错误是我们标记的错误的话(包括,1.返回内容太长 2. 返回内如输出到文件错误 3. 返回内容 content type 不对 ),就需要判断了.
    if ( [[error domain] isEqual:kQHTTPOperationErrorDomain] ) {
        // We can easily understand the consequence(result) of coming directly from QHTTPOperation.
        
        if ( [error code] > 0 ) { //正整数是 server 返回的 HTML status codes
            // The request made it to the server, which failed it.  We consider that to be fatal.
            // It might make sense to handle error 503 "Service Unavailable" as a
            // special case here but, realistically(现实中), how common is that?
            shouldRetry = NO;
        } else {
            switch ( [error code] ) {
                default:
                    assert(NO);     // what is this error?
                    // fall through
                case kQHTTPOperationErrorResponseTooLarge:   //1.返回内容太长
                case kQHTTPOperationErrorOnOutputStream:     //2.返回内如输出到文件错误
                case kQHTTPOperationErrorBadContentType: {   //3.返回内容 content type 不对
                    shouldRetry = NO;   // all of these conditions are unlikely to fail
                } break;
            }
        }
    } else {

        // We treat all other errors are retryable.  Most errors are likely to be from 
        // the network, and that's exactly what we want to retry.  Clearly this is going to 
        // need some refinement based on real world experience.
        // 我们对待所有其他的错误是可以重新尝试请求的.
        // 对于大部分的错误看起来像从网络来的, 而这些正是我们想重新尝试的.
        // 从现实世界的经验来看,这里的处理显然地需要一些精加工
        shouldRetry = YES;
    }
    return shouldRetry;
}


/*!
 *  获取下次进行重新请求是多长时间以后
    这不是一个加密的系统, 所以我们不关心取模偏差, 我们的随机时间间隔,只是通过使用随机数取模一个延迟毫秒数
    然后把这个毫秒数转换成 NSTimeInterval 类型
 
    This isn't a crypto system, so we don't care about mod bias, so we just calculate
    the random time interval by taking the random number, mod'ing it by the number
    of milliseconds of the delay range, and then converting that number of milliseconds
    to an NSTimeInterval.
 
 *
 *  @param rangeIndex 第几次进行 重新请求尝试
 *
 *  @return 直到下次请求的时间间隔
 */
- (NSTimeInterval)retryDelayWithinRangeAtIndex:(NSUInteger)rangeIndex
    // Helper method for -shortRetryDelay and -randomRetryDelay.
{
    // First retry is after one second;
    // next retry  is after one minute;
    // next retry  is after one hour;
    // next retry (and all subsequent retries) is after six hours.
    static const NSUInteger kRetryDelays[] = { 1, 60, 60 * 60, 6 * 60 * 60 };  //重新尝试请求的最大延迟时间

    if (rangeIndex >= (sizeof(kRetryDelays) / sizeof(kRetryDelays[0])))
    {
        rangeIndex = (sizeof(kRetryDelays) / sizeof(kRetryDelays[0])) - 1;
    }
    return ((NSTimeInterval) (((NSUInteger) arc4random()) % (kRetryDelays[rangeIndex] * 1000))) / 1000.0;
}


// Returns a random short delay (that is, within the next second).
- (NSTimeInterval)shortRetryDelay
{
    return [self retryDelayWithinRangeAtIndex:0];
}

// Returns a random delay that's based on the retryCount; the delay range grows
// rapidly(立即) with the number of retries, thereby(从而) ensuring that we don't continuously
// thrash(击打) the device doing unsuccessful retries.
- (NSTimeInterval)randomRetryDelay
{
    return [self retryDelayWithinRangeAtIndex:self.retryCount];
}


#pragma mark - Core state transitions 本类在执行后调用的第一个有意义的函数

/*!
 *  本方法"在本类的实例对象"被添加到 NetworkManger 的 queueForNetworkManagement 队列后, 在本类的实例operation开始执行,
 *  调用本类重写的父类方法operationDidStart之后,再调用本方法.
 *
 *  本方法是在 NetworkManger 的 queueForNetworkManagement 队列里执行的.
 */
// Starts the HTTP request.  This might be the first request or a retry.
- (void)startRequest
{
    assert([self isActualRunLoopThread]);//继承自父类 QRunLoopOperation的方法,确保是在正确的线程上执行的这个动作
    assert( (self.retryState == kRetryingHTTPOperationStateGetting) || (self.retryState == kRetryingHTTPOperationStateRetrying) );
    assert(self.networkOperation == nil);

    [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"%s http %zu request start", __PRETTY_FUNCTION__ ,(size_t) self->_sequenceNumber];
    
    // Create the network operation. 再创建一个 operation    
    self.networkOperation = [[[QHTTPOperation alloc] initWithRequest:self.request] autorelease];
    assert(self.networkOperation != nil);
    
    // Copy our properties over to the network operation.
    [self.networkOperation setQueuePriority:[self queuePriority]];
    self.networkOperation.acceptableContentTypes = self.acceptableContentTypes;
    self.networkOperation.runLoopThread = self.runLoopThread;
    self.networkOperation.runLoopModes  = self.runLoopModes;
    
    // If we're downloading to a file, set up an output stream that points to that file. 
    // 
    // Note that we pass NO to the append parameter; if we wanted to support resumeable 
    // downloads, we could do it here (but we'd have to mess around with etags and so on).
    //
    if (self.responseFilePath != nil) {
        self.networkOperation.responseOutputStream = [NSOutputStream outputStreamToFileAtPath:self.responseFilePath append:NO];
        assert(self.networkOperation.responseOutputStream != nil);
    }

    //添加到队列,开始网络下载
    //本例是在 NetworkManger的网络管理队列(queueForNetworkManagement) 里执行,
    //而下面将 self.networkOperation 添加到 NetworkManger的网络传输队列(queueForNetworkTransfers) 里执行.
    [[NetworkManager sharedManager] addNetworkTransferOperation:self.networkOperation finishedTarget:self action:@selector(networkOperationDone:)];
    //到此本网络管理队列(queueForNetworkManagement)里的一个本类实例对象 operation 需要等待self.networkOperation添加到NetworkManger的网络传输队列(queueForNetworkTransfers)
    //里的self.networkOperation完成后(可能不成功),  然后在[本线程]上调用[本类]的networkOperationDone:方法, networkOperationDone:方法会有两种情况:
    //        (1) 如果请求顺利完成,本类的networkOperationDone:方法调用父类的 [self finishWithError:nil],
    //                    然后再间接调用本类的- (void)operationWillFinish,至此,本 operation 顺利完成返回
    //        (2) 如果请求没有完成,首先根据返回的错判断是否重试.能够重试的话,根据 指数后退算法 延迟尝试,否则直接返回退出.本 operation 顺利完成返回.
    
}


/*!
 *  当QHTTPOperation网络操作队列完成后调用.即,self.networkOperation 已经完成,资源(这里是图片或者 XML 配置文件)已经被下载下来了.
 *  Called when the network operation finishes.  We look at the error to decide how to proceed.
 *  本方法是为startRequest的回调方法,和startRequest在同一线程里执行,即,在 NetworkManger 的网络管理队列(queueForNetworkManagement)内执行.
 *
 *  @param  参数就是本次请求的self.networkOperation,原本保存在了 Networkmanger 的 map 里,等待请求完成以后,最后回调时传入.
 */
- (void)networkOperationDone:(QHTTPOperation *)operation
{
    assert([self isActualRunLoopThread]);
    assert( (self.retryState == kRetryingHTTPOperationStateGetting) || (self.retryState == kRetryingHTTPOperationStateRetrying) );
    assert(operation == self.networkOperation);//这是同一个对象才对
    
    self.networkOperation = nil;  //请求已经完成(或成功,或失败),并不需要在留着QHTTPOperation的实例

    if (operation.error == nil) {  // The request was successful; let's complete the operation.
        
        [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@" %s http %zu request success",__PRETTY_FUNCTION__, (size_t) self->_sequenceNumber];
    
        self.response = operation.lastResponse;        //NSHTTPURLResponse
        self.responseContent = operation.responseBody; //NSData
        
        ////这将导致调用,本类的 - (void)operationWillFinish
        [self finishWithError:nil];     // this changes state to kRetryingHTTPOperationStateFinished

    } else {  // Something went wrong.  Deal with the error.
                
        [[QLog log] logOption:kLogOptionNetworkDetails
                   withFormat:@"%s http %zu request error %@", __PRETTY_FUNCTION__, (size_t) self->_sequenceNumber, operation.error];
    
        //根据返回的错误,判断是否可以进行重新请求尝试
        if ( ! [self shouldRetryAfterError:operation.error] ) {
            // If the error is fatal, we just fail the overall operation.
            //这将导致调用,本类的 - (void)operationWillFinish
            [self finishWithError:operation.error];

        } else { //继续重新尝试请求
            
            // If this is our first retry, tell our client that we are in retry mode.
            if (self.retryState == kRetryingHTTPOperationStateGetting) {
                [self performSelectorOnMainThread:@selector(setHasHadRetryableFailureOnMainThread) withObject:nil waitUntilDone:NO];
            }

            // If our notification callback isn't installed, install it.
            //
            // This notification is broadcast if any download succeeds.  If it fires, we 
            // trigger a very quick retry because, if one transfer succeeds, it's likely that 
            // other transfers will succeed as well.
            if ( ! self.notificationInstalled ) {
                [[NSNotificationCenter defaultCenter] addObserver:self
                                                         selector:@selector(transferDidSucceed:)
                                                             name:kRetryingHTTPOperationTransferDidSucceedNotification
                                                           object:nil];
                self.notificationInstalled = YES;
            }
            
            // If the reachability operation is not running (this can happen the first time we fail 
            // and if a subsequent reachability-based retry fails), start it up.  Given that reachability 
            // only tells us about the state of our local machine, the operation could have failed for 
            // reasons that reachability knows nothing about.  So before we use a reachability 
            // check to trigger a retry, we want to make sure that the host is first /unreachable/, 
            // and then wait for it to become reachability.  So, let's start with that first part.
            
            if (self.reachabilityOperation == nil) {
                [self startReachabilityReachable:NO];
            }
        
            // Start a time-based retry.
            self.retryState = kRetryingHTTPOperationStateWaitingToRetry;
            [self startRetryAfterTimeInterval:[self randomRetryDelay]];
        }
        
        
    }
}

// Called when kRetryingHTTPOperationTransferDidSucceedNotification is posted.
// We see if this notification is relevant to us and, if so, pass it on to code
// running on our run loop.
- (void)transferDidSucceed:(NSNotification *)note
{
    // Can't look at state at this point, but it is safe to look at request because 
    // that's immutable.

    assert( [[note name] isEqual:kRetryingHTTPOperationTransferDidSucceedNotification] );
    assert( [[[note userInfo] objectForKey:kRetryingHTTPOperationTransferDidSucceedHostKey] isKindOfClass:[NSString class]] );

    // If the successful transfer was to /our/ host, we pass the notification off to 
    // our run loop thread.
    
    if ( [[[note userInfo] objectForKey:kRetryingHTTPOperationTransferDidSucceedHostKey] isEqual:[[self.request URL] host]] ) {

        // This raises the question of what happens if the operation changes state (most critically, 
        // if it finishes) while waiting for this selector to be performed.  It turns out that's OK. 
        // The perform will retain self while it's in flight, and if it is delivered in an inappropriate 
        // context (after, say, the operation has finished), it will be ignored based on the retryState.
        
        [self performSelector:@selector(transferDidSucceedOnRunLoopThread) onThread:self.actualRunLoopThread withObject:nil waitUntilDone:NO];
    }
}


/*!
 *  本方法运行在  QRunLoopOperation 的 actualRunLoopThread 上运行
 *
 *  Called on our run loop when a kRetryingHTTPOperationTransferDidSucceedNotification
 *  notification relevant to us is posted.  We check whether a fast retry is in order.
 */
- (void)transferDidSucceedOnRunLoopThread
{
    [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu other transfer succeeeded", (size_t) self->_sequenceNumber];

    // If some other transfer to the same host succeeded, radically reduce our retry delay.
    if (self.retryState == kRetryingHTTPOperationStateWaitingToRetry) {
        assert(self.retryTimer != nil);
        
        [self.retryTimer invalidate];
        self.retryTimer = nil;
        
        [self startRetryAfterTimeInterval:[self shortRetryDelay]];
    }
}


/*!
 *  设定指定的delay时间后,调用我们的 重新请求尝试方法retryTimerDone
 *  Schedules a retry to occur after the specified delay.
 *
 *  @param delay 延迟时间
 */
- (void)startRetryAfterTimeInterval:(NSTimeInterval)delay
{
    assert(self.retryState == kRetryingHTTPOperationStateWaitingToRetry);
    assert(self.retryTimer == nil);

    [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"%s http %zu retry wait start %.3f",__PRETTY_FUNCTION__, (size_t) self->_sequenceNumber, delay];

    self.retryTimer = [NSTimer timerWithTimeInterval:delay target:self selector:@selector(retryTimerDone:) userInfo:nil repeats:NO];
    assert(self.retryTimer != nil);
    for (NSString * mode in self.actualRunLoopModes) {
        [[NSRunLoop currentRunLoop] addTimer:self.retryTimer forMode:mode];
    }
}

/*!
 *  当 retryTimer 时间到了,进行再此的请求尝试
 *  Called when the retry timer expires.  It just starts the actual retry.
 *  @param timer
 */
- (void)retryTimerDone:(NSTimer *)timer
{
    assert([self isActualRunLoopThread]);
    assert(timer == self.retryTimer);
    #pragma unused(timer)

    [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu retry wait done", (size_t) self->_sequenceNumber];

    [self.retryTimer invalidate];
    self.retryTimer = nil;
    
    assert(self.retryState == kRetryingHTTPOperationStateWaitingToRetry);
    self.retryState = kRetryingHTTPOperationStateRetrying;
    self.retryCount += 1;

    //开始重新的请求尝试
    [self startRequest];
}



#pragma mark - ReachabilityReachable operation
/*!
 *  本方法,是在第一次尝试 GET HTTP 请求失败后,回调函数 - (void)networkOperationDone:(QHTTPOperation *)operation 上初始化调用的.
 *
 *  根据传入的参数,开启一个 reachability operation 等到请求的 host 是否变为可用或者不可用
 *  Starts a reachability operation waiting for the host associated with this request
 *  to become unreachable or reachabel (depending on the "reachable" parameter).
 *  @param reachable 是等待请求的主机变为可用(YES),还是等到变为不可用(NO)
 */
- (void)startReachabilityReachable:(BOOL)reachable
{
    [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu %sreachable start", (size_t) self->_sequenceNumber, reachable ? "" : "un" ];

    assert(self.reachabilityOperation == nil);
    self.reachabilityOperation = [[[QReachabilityOperation alloc] initWithHostName:[[self.request URL] host]] autorelease];
    assert(self.reachabilityOperation != nil);

    // In the reachable case the default mask and value is fine.
    // In the unreachable case we have to customise them.
    if ( ! reachable ) {
        self.reachabilityOperation.flagsTargetMask  = kSCNetworkReachabilityFlagsReachable;//当可到达状态改变时,和下面的结果做对比
        self.reachabilityOperation.flagsTargetValue = 0; //期望变为的结果,不可达
    }

    [self.reachabilityOperation setQueuePriority:[self queuePriority]];
    self.reachabilityOperation.runLoopThread = self.runLoopThread;
    self.reachabilityOperation.runLoopModes  = self.runLoopModes;

    [[NetworkManager sharedManager] addNetworkManagementOperation:self.reachabilityOperation
                                                   finishedTarget:self
                                                           action:@selector(reachabilityOperationDone:)];
}


// Called when the reachability operation finishes.  If we were looking for the
// host to become unreachable, we respond by scheduling a new operation waiting
// for the host to become reachable.  OTOH(On the Other Hand), if we've found that the host has
// become reachable (and this must be a transition because we only schedule
// such an operation if the host is current unreachable), we force a fast retry.
- (void)reachabilityOperationDone:(QReachabilityOperation *)operation
{
    assert([self isActualRunLoopThread]);
    assert(self.retryState >= kRetryingHTTPOperationStateWaitingToRetry);
    assert(operation == self.reachabilityOperation);
    self.reachabilityOperation = nil; //删除已经完成的 operation
    
    assert(operation.error == nil);     // ReachabilityOperation can never actually fail

    if ( ! (operation.flags & kSCNetworkReachabilityFlagsReachable) ) { // 如果网络不可到达
    
        // We've know that the host is not unreachable.  Schedule a reachability operation to 
        // wait for it to become reachable.
        [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu unreachable done (0x%zx)", (size_t) self->_sequenceNumber, (size_t) operation.flags];

        [self startReachabilityReachable:YES];
        
    } else { // 如果网络可到达
    
        // Reachability has flipped from being unreachable to being reachable.  We respond by 
        // radically shortening the retry delay (although not too short, we want to give the 
        // system time to settle after the reachability change).
        [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu reachable done (0x%zx)", (size_t) self->_sequenceNumber, (size_t) operation.flags];

        if (self.retryState == kRetryingHTTPOperationStateWaitingToRetry) {
            assert(self.retryTimer != nil);
            [self.retryTimer invalidate];
            self.retryTimer = nil;
            
            [self startRetryAfterTimeInterval:[self shortRetryDelay] + 3.0];
        }
    }
}

#pragma mark - overwrite parent method
/*!
 *  此方法重写父类的方法,在本类的 operation 被添加到 NSOperationQueue 后,默认调用父类的 start 函数,然后再间接的调用本方法
    本方法对象在 model/PhotoGallery.m 的 - (void)startGetOperation 中被创建,并入 Queue
    本方法是在 NetworkManger 的 queueForNetworkManagement 队列里执行的.
 *   Called by QRunLoopOperation when the operation starts.  We just kick off the initial HTTP request.
 */
- (void)operationDidStart
{
    assert([self isActualRunLoopThread]);
    assert(self.retryState == kRetryingHTTPOperationStateNotStarted); //从默认初始值开始
    
    [super operationDidStart]; //其实就是个编码习惯,这句可以没有,就是检查执行方法的线程是否是正确的
    
    [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"%s http %zu start %@", __PRETTY_FUNCTION__, (size_t) self->_sequenceNumber, [self.request URL]];
    
    self.retryState = kRetryingHTTPOperationStateGetting;//改变状态
    [self startRequest];
}

/*!
 *   Called by QRunLoopOperation when the operation finishes.  We just clean up our various operations and callbacks.
 */
- (void)operationWillFinish
{
    assert([self isActualRunLoopThread]);

    [super operationWillFinish];
    
    //删除 http get 的 Operation
    if (self.networkOperation != nil) {
        [[NetworkManager sharedManager] cancelOperation:self.networkOperation];
        self.networkOperation = nil;
    }

    //删除延迟重试的计划
    if (self.retryTimer != nil) {
        [self.retryTimer invalidate];
        self.retryTimer = nil;
    }
    
    if (self.reachabilityOperation != nil) {
        [[NetworkManager sharedManager] cancelOperation:self.reachabilityOperation];
        self.reachabilityOperation = nil;
    }
    
    //删除 立即重新尝试请求 的通知监控
    if (self.notificationInstalled) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:kRetryingHTTPOperationTransferDidSucceedNotification object:nil];
        self.notificationInstalled = NO;
    }
    self.retryState = kRetryingHTTPOperationStateFinished;

    if (self.error == nil) {
        [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"%s http %zu success", __PRETTY_FUNCTION__, (size_t) self->_sequenceNumber];
        
        
        // We were successful.
        //Broadcast a notification to that effect so that other transfers who are delayed waiting to retry know that now is a good time.
        [[NSNotificationCenter defaultCenter] postNotificationName:kRetryingHTTPOperationTransferDidSucceedNotification 
            object:nil 
            userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[[self.request URL] host], kRetryingHTTPOperationTransferDidSucceedHostKey, nil]
        ];
        
    } else {
        [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu error %@", (size_t) self->_sequenceNumber, self.error];
    }
}

@end
