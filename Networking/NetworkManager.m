#import "NetworkManager.h"
#import "QHTTPOperation.h"
#import "Logging.h"

@interface NetworkManager ()

@property (nonatomic, retain, readonly ) NSThread *             networkRunLoopThread;  //This thread runs all of our network operation run loop callbacks.
@property (nonatomic, retain, readonly ) NSOperationQueue *     queueForNetworkTransfers;
@property (nonatomic, retain, readonly ) NSOperationQueue *     queueForNetworkManagement;
@property (nonatomic, retain, readonly ) NSOperationQueue *     queueForCPU;

@end


// 本类主要管理网络操作相关的环境
//   最主要的方法是 , 添加一个 Operation 到 Queue, 并在 Operation 完成以后,调用 target 的 action
//
//   - (void)addOperation:(NSOperation *)operation toQueue:(NSOperationQueue *)queue finishedTarget:(id)target action:(SEL)action
//      toQueue 的值为本类 3 个 NSOperationQueue 类型的 property 中的一个.
//          1) queueForNetworkTransfers     { QReachabilityOperation, QHTTPOperation }
//          2) queueForNetworkManagement    { RetryingHTTPOperation }
//          3) queueForCPU                  { GalleryParseoperation,MakeThumbnailOperation}
//      所有的 operation, 都是在对应的 Queue 上完成的, 对于不同的 operation, 拥有不通的 MaxConcurrentOperationCount 值, 意思是 "并行队列" or "串行队列"
//      其他的具体网络操作类负载调用本类的 addOperation:toQueue:finishedTarget:action: 方法,向上面3个 NSOperationQueue 类型的 property 之一添加 operation
//          o 而添加 Operation 时,会创建一个 KVO 的监控, 监控新添加的 Opration 的 isFinished 属性,表示如果操作完成,就通知本类回调响应的处理,即,启用相应的回调函数.
//              创建 KVO 时,把对应的 queue 传入,这样再操作完成时,我们就知道是那个 queue 里的 operation 完成了.
//                  我们没有在 map 中保存 queue 的数据,不能通过 map 知道 operation 是那个 queue 的,所以这里要传入 queue
//          o 添加 Operation 时, 通过测试 其他网络操作类是否有 setRunLoopThread 方法,并设置为本类的 networkRunLoopThread 属性,
//              等到对应的 operation 完成以后,由本类的 networkRunLoopThread 线程处理对应的 target action 回调的目的,这样可以避免 main 线程的堵塞.

// 监控到isFinished 消息后,启用 target action 回调 主要涉及到4个对象:
//  1) operation
//  2) thread
//  3) target
//  4) action
//  这4个对象的关系是: operatin 被添加到了不通的 queue 中,所以在不同的 thread 上运行, 并在 Operation 完成后调用 target 的 action 方法.
//      意思是说, 把任务分摊到不通的线程上执行,等到执行完毕以后,再调用回调函数

//  这4个对象是以字典的形式,全部以 operatin 为 key 保存到对应的字典中
//  总共有 3 CFMutableDictionaryRef 字典 property
//          1) _runningOperationToTargetMap
//          2) _runningOperationToActionMap
//          3) _runningOperationToThreadMap
//
// 本 App 常住线程就两个,一个为 main thread,两一个为本类生成的 networkRunLoopThread.
// 还有其他的线程,会在本类的 NSOperationQueue 中加入 Operation 后,由 GCD 生成,并在 Operation 执行完毕以后自动退出.
//
// --- main thread
// --- self->_networkRunLoopThread
// -------- NSOperationQueue .......



@implementation NetworkManager

@synthesize networkRunLoopThread = _networkRunLoopThread;
@synthesize queueForNetworkTransfers  = _queueForNetworkTransfers;
@synthesize queueForNetworkManagement = _queueForNetworkManagement;
@synthesize queueForCPU               = _queueForCPU;

+ (NetworkManager *)sharedManager
{
    static NetworkManager * sNetworkManager;
    // This can be called on any thread, so we synchronise.  We only do this in 
    // the sNetworkManager case because, once sNetworkManager goes non-nil, it can 
    // never go nil again.
    if (sNetworkManager == nil) {
        @synchronized (self) {
            sNetworkManager = [[NetworkManager alloc] init];
            assert(sNetworkManager != nil);
        }
    }
    return sNetworkManager;
}

- (id)init
{
    // any thread, but serialised by +sharedManager
    self = [super init];
    if (self != nil) {

        // Create the network management queue.  We will run an unbounded number of these operations 
        // in parallel because each one consumes minimal resources.
        self->_queueForNetworkManagement = [[NSOperationQueue alloc] init];
        assert(self->_queueForNetworkManagement != nil);
        [self->_queueForNetworkManagement setMaxConcurrentOperationCount:NSIntegerMax];
        assert(self->_queueForNetworkManagement != nil);

        // Create the network transfer queue.  We will run up to 4 simultaneous network requests.
        self->_queueForNetworkTransfers = [[NSOperationQueue alloc] init];
        assert(self->_queueForNetworkTransfers != nil);
        [self->_queueForNetworkTransfers setMaxConcurrentOperationCount:4];
        assert(self->_queueForNetworkTransfers != nil);

        // Create the CPU queue.  In contrast to the network queues, we leave 
        // maxConcurrentOperationCount set to the default, which means on current iOS devices 
        // the CPU operations are serialised.  There's no point bouncing a single CPU between 
        // threads for this stuff.
        self->_queueForCPU = [[NSOperationQueue alloc] init];
        assert(self->_queueForCPU != nil);
        
        // Create two dictionaries to store the target and action for each queued operation. 
        // Note that we retain the operation and the target but there's no need to retain the action selector.
        // the SEL type isn't an object reference, it's basically a constant string pointer. so you can't retain them.
        // 为每一个队列操作常见对应的 target 和 action 字典数据
        // 注意, 我们 retain 了 opertion 和 target , 但是 action selector 这里并不需要 retain
        //  SEL 类型不是一个对象的引用,基本上,它就是一个 常量字符串指针,所以不能够 retain
        self->_runningOperationToTargetMap = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        assert(self->_runningOperationToTargetMap != NULL);
        self->_runningOperationToActionMap = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, NULL);
        assert(self->_runningOperationToActionMap != NULL);
        self->_runningOperationToThreadMap = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        assert(self->_runningOperationToThreadMap != NULL);
        
        // 我们运行所有的 网络回调函数 在一个独立的线程里,这样它就不会为主线程的延迟贡献力量了,现在创建和配置这个线程.
        // We run all of our network callbacks on a secondary thread to ensure that they don't 
        // contribute to main thread latency.  Create and configure that thread.
        // NSThread 是 Objective-C 对 pthread 的一个封装。通过封装，在 Cocoa 环境中，可以让代码看起来更加亲切。
        // 例如，开发者可以利用 NSThread 的一个子类来定义一个线程，在这个子类的中封装需要在后台线程运行的代码。
        // 下面是直接的在 thread 上面调用 本类的一个方法, 而此方法是一个 无限 runloop,
        self->_networkRunLoopThread = [[NSThread alloc] initWithTarget:self selector:@selector(networkRunLoopThreadEntry) object:nil];
        assert(self->_networkRunLoopThread != nil);

        [self->_networkRunLoopThread setName:@"networkRunLoopThread"];
        if ( [self->_networkRunLoopThread respondsToSelector:@selector(setThreadPriority:)] ) {
            [self->_networkRunLoopThread setThreadPriority:0.3];
        }

        [self->_networkRunLoopThread start];
    }
    return self;
}

- (void)dealloc
{
    // This object lives for the entire life of the application.  Getting it to support being 
    // deallocated would be quite tricky (particularly from a threading perspective), so we 
    // don't even try.
    assert(NO);
    [super dealloc];
}

- (NSMutableURLRequest *)requestToGetURL:(NSURL *)url
{
    NSMutableURLRequest *   result;
    static NSString *       sUserAgentString;

    // any thread
    assert(url != nil);

    // Create the request.
    result = [NSMutableURLRequest requestWithURL:url];
    assert(result != nil);
    
    // Set up the user agent string.
    if (sUserAgentString == nil) {
        @synchronized ([self class]) {
            sUserAgentString = [[NSString alloc] initWithFormat:@"MVCNetworking/%@", [[[NSBundle mainBundle] infoDictionary] objectForKey:(id)kCFBundleVersionKey]];
            assert(sUserAgentString != nil);
        }
    }
    
    [result setValue:sUserAgentString forHTTPHeaderField:@"User-Agent"];
    
    return result;
}

#pragma mark - Operation dispatch

// This thread runs all of our network operation run loop callbacks.
// 这个线程运行所有的网络请求操作 回调, 即, target action 的回调
// 通过在 调用 addOperation:toQueue:finishedTarget:action: 方法时,测试其他网络操作类是否有 setRunLoopThread 方法,并设置为本类的 networkRunLoopThread 属性
- (void)networkRunLoopThreadEntry
{
    assert( ! [NSThread isMainThread] );
    while (YES) {
        NSAutoreleasePool * pool;

        pool = [[NSAutoreleasePool alloc] init];
        assert(pool != nil);

        [[NSRunLoop currentRunLoop] run];
        //runloop能很好处理多个inputsource，类似cpu时间片一样的在这些source中轮询。
        //比如有多个http链接要同时下载内容，那么新开一个线程把connections全部放到这个线程的runloop中就可以了(或者直接放在MainThread的runloop中)，不要多开线程
        // 运行 run 方法会很高效的开启一个无线循环处理数据从 run loop input source 进来的事件.

        [pool drain];
    }
    //上面的循环理论上程序不死,就不会退出的,注意,上面的 runloop 不是在main线程上运行的,所以不会堵死 UI 的交互.
    assert(NO);
}

// See comment in header.
// 此方法直接放映在application Delegate 里,决定是否显示网络在使用的那个 loading 图标
- (BOOL)networkInUse
{
    assert([NSThread isMainThread]);
    
    // I base -networkInUse off the number of running operations, not the number of running 
    // network operations.  This is probably technically incorrect, but the reality is that 
    // changing it would be tricky (but not /that/ tricky) and there's some question as to 
    // whether it's the right thing to do anyway.  In an application that did extensive CPU work 
    // that was unrelated to the network then, sure, you'd only want the network activity 
    // indicator running while you were hitting the network.  But in this application 
    // all CPU activity is the direct result of networking, so leaving the network activity 
    // indicator running while this CPU activity is busy isn't too far from the mark.
    return self->_runningNetworkTransferCount != 0;
}

//涉及到 UI 的操作,都需要在 main tread 上运行
- (void)incrementRunningNetworkTransferCount
{
    BOOL    movingToInUse;
    assert([NSThread isMainThread]);

    movingToInUse = (self->_runningNetworkTransferCount == 0);
    if (movingToInUse) {
        //因为 application 的 delegate 在监控本对象的"networkInUse"的值,这里如果值改变的话,需要发出通知.
        [self willChangeValueForKey:@"networkInUse"];
    }
    self->_runningNetworkTransferCount += 1;
    if (movingToInUse) {
        [self  didChangeValueForKey:@"networkInUse"];
    }
}

//涉及到 UI 的操作,都需要在 main tread 上运行
- (void)decrementRunningNetworkTransferCount
{
    BOOL    movingToNotInUse;
    assert([NSThread isMainThread]);

    assert(self->_runningNetworkTransferCount != 0);
    movingToNotInUse = (self->_runningNetworkTransferCount == 1);
    if (movingToNotInUse) {
        //因为 application 的 delegate 在监控本对象的"networkInUse"的值,这里如果值改变的话,需要发出通知.
        [self willChangeValueForKey:@"networkInUse"];
    }
    self->_runningNetworkTransferCount -= 1;
    if (movingToNotInUse) {
        [self  didChangeValueForKey:@"networkInUse"];
    }
}

#pragma mark - add Operation

//添加一个 Operation 到 Queue, 并在 Operation 完成以后,调用 target 的 action.
// Core code to enqueue an operation on a queue.
- (void)addOperation:(NSOperation *)operation toQueue:(NSOperationQueue *)queue finishedTarget:(id)target action:(SEL)action
{
    // any thread
    assert(operation != nil);
    assert(target != nil);
    assert(action != nil);

    // In the debug build, apply our debugging preferences to any operations 
    // we enqueue.
#if ! defined(NDEBUG) 
        // 根据程序设置里的设定, 设定operation的选项
        // While, in theory, networkErrorRate should only apply to network operations, we
        // apply it to all operations if they support the -setDebugError: method.
        if ( [operation respondsToSelector:@selector(setDebugError:)] ) {
            static NSInteger    sOperationCount;
            NSInteger           networkErrorRate;
            
            networkErrorRate = [[NSUserDefaults standardUserDefaults] integerForKey:@"networkErrorRate"];
            if (networkErrorRate != 0) {
                sOperationCount += 1;
                if ( (sOperationCount % networkErrorRate) == 0) {
                    [(id)operation setDebugError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil]];
                }
            }
        }
    
        if ( [operation respondsToSelector:@selector(setDebugDelay:)] ) {
            NSTimeInterval operationDelay = [[NSUserDefaults standardUserDefaults] doubleForKey:@"operationDelay"];
            if (operationDelay > 0.0) {
                [(id)operation setDebugDelay:operationDelay];
            }
        }
#endif

    // Update our networkInUse property;
    // because we can be running on any thread, we do this update on the main thread.
    if (queue == self.queueForNetworkTransfers) { //如果有人使用网络传输队列,就要在系统状态条上现实网络使用 loading 图标.
        // 设计到 UI 操作的都要在 main thread.
        [self performSelectorOnMainThread:@selector(incrementRunningNetworkTransferCount) withObject:nil waitUntilDone:NO];
    }
    
    // Atomically enter the operation into our target and action maps.
    // 这里为什么要 synchronized ? 因为对核心关键 map 数据的操作,有可能会和 cancel 动作有竞争关系.
    @synchronized (self) {
        assert( CFDictionaryGetCount(self->_runningOperationToTargetMap) == CFDictionaryGetCount(self->_runningOperationToActionMap) );
        assert( CFDictionaryGetCount(self->_runningOperationToTargetMap) == CFDictionaryGetCount(self->_runningOperationToThreadMap) );
        assert( CFDictionaryGetValue(self->_runningOperationToTargetMap, operation) == NULL );      // shouldn't already be in our map
        assert( CFDictionaryGetValue(self->_runningOperationToActionMap, operation) == NULL );      // shouldn't already be in our map
        assert( CFDictionaryGetValue(self->_runningOperationToThreadMap, operation) == NULL );      // shouldn't already be in our map
        
        // Add the operations to , triggering a KVO notification of networkInUse if required.
        // 全部以 operation 为可以 来创建 dictionary
        // 这样在消息传递时,只要传入operation 就可以获取其他对应数据
        CFDictionarySetValue(self->_runningOperationToTargetMap, operation, target);
        CFDictionarySetValue(self->_runningOperationToActionMap, operation, action);
        CFDictionarySetValue(self->_runningOperationToThreadMap, operation, [NSThread currentThread]);

        assert( CFDictionaryGetCount(self->_runningOperationToTargetMap) == CFDictionaryGetCount(self->_runningOperationToActionMap) );
        assert( CFDictionaryGetCount(self->_runningOperationToTargetMap) == CFDictionaryGetCount(self->_runningOperationToThreadMap) );
    }
    
    // Observe the isFinished property of the operation.  We pass the queue parameter as the 
    // context so that, in the completion routine, we know what queue the operation was sent 
    // to (necessary to decide what thread to run the target/action on).
    //
    // 注册 operation 的 isFinished 属性的 KVO 的监控.
    // 我们传入参数 queue 作为 context, 这样在消息到达后,我们就可以知道那个 queue 里的操作发来的通知.
    // 我们总共有三个 queue:
    //     1) queueForNetworkTransfers
    //     2) queueForNetworkManagement
    //     3) queueForCPU
    
    // NSOperationQueue 的介绍说明查看 QRunLoopOperation.m 的注释
    [operation addObserver:self forKeyPath:@"isFinished" options:0 context:queue];
    
    // Queue the operation.  When the operation completes,  [self operationDone] is called.
    // 将这个operation入列,入列后, operation 立即执行
    [queue addOperation:operation];
}

- (void)addNetworkManagementOperation:(NSOperation *)operation finishedTarget:(id)target action:(SEL)action
{
    // 检测是否为 QRunLoopOperation 类(或子类),如果是,则调用operation的 setRunLoopThread 设置为 self.networkRunLoopThread
    // 这样回调函数就会在 networkRunLoopThread 线程上运行了,否则会在 main thread 上运行,有可能堵塞 UI.
    if ([operation respondsToSelector:@selector(setRunLoopThread:)]) { //这里用到了QHTTPOperation 的方法.所以要引入那个H文件
        if ( [(id)operation runLoopThread] == nil ) { // 确保只设置一次 runLoop
            [ (id)operation setRunLoopThread:self.networkRunLoopThread];
        }
    }
    [self addOperation:operation toQueue:self.queueForNetworkManagement finishedTarget:target action:action];
}


- (void)addNetworkTransferOperation:(NSOperation *)operation finishedTarget:(id)target action:(SEL)action
{
    // 检测是否为 QRunLoopOperation 类(或子类),如果是,则调用operation的 setRunLoopThread 设置为 self.networkRunLoopThread
    // 这样回调函数就会在 networkRunLoopThread 线程上运行了,否则会在 main thread 上运行,有可能堵塞 UI.
    if ([operation respondsToSelector:@selector(setRunLoopThread:)]) { //这里用到了QHTTPOperation 的方法.所以要引入那个H文件
        if ( [(id)operation runLoopThread] == nil ) { // 确保只设置一次 runLoop
            [ (id)operation setRunLoopThread:self.networkRunLoopThread];
        }
    }
    [self addOperation:operation toQueue:self.queueForNetworkTransfers finishedTarget:target action:action];
}


- (void)addCPUOperation:(NSOperation *)operation finishedTarget:(id)target action:(SEL)action
{
    [self addOperation:operation toQueue:self.queueForCPU finishedTarget:target action:action];
}

#pragma mark - KVO observing method

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    // any thread
    if ( [keyPath isEqual:@"isFinished"] ) {
        // we have 3 CFMutableDictionaryRef
        //          1) _runningOperationToTargetMap
        //          2) _runningOperationToActionMap
        //          3) _runningOperationToThreadMap
    
        NSOperation *       operation;
        operation = (NSOperation *) object;
        assert([operation isKindOfClass:[NSOperation class]]);
        assert([operation isFinished]);

        // 通过添加监控时传入进来的参数获取 OperationQueue
        NSOperationQueue *  queue;
        queue = (NSOperationQueue *) context;
        assert([queue isKindOfClass:[NSOperationQueue class]]);

        // 因为这里是 operate 完成调用前,最后一个方法,所以要删除 Observer
        [operation removeObserver:self forKeyPath:@"isFinished"];
        
        //任何对核心 map 数据的操作都要,采用原子级别的锁定
        NSThread *          thread; // get from self->_runningOperationToThreadMap dictionary
        @synchronized (self) {
            assert( CFDictionaryGetCount(self->_runningOperationToTargetMap) == CFDictionaryGetCount(self->_runningOperationToActionMap) );
            assert( CFDictionaryGetCount(self->_runningOperationToTargetMap) == CFDictionaryGetCount(self->_runningOperationToThreadMap) );

            thread = (NSThread *) CFDictionaryGetValue(self->_runningOperationToThreadMap, operation);
            if (thread != nil) {
                // 如果 thread 不为空的话,下面要用它执行 oprationDone 消息, 所以 ratain 一下.
                [thread retain];
            }
        }//锁定结束
        
        if (thread != nil) {
            //在调用addOperation:toQueue:finishedTarget:action:的 thread 上执行本类的 operationDone 操作
            //主要作用是从 _runningOperationTo*** map 中删除已经添加的数据(因为也是在那个线程上向 map 添加的数据),并调用添加operation时指定的回调函数.
            [self performSelector:@selector(operationDone:) onThread:thread  withObject:operation waitUntilDone:NO];
            
            [thread release];

            if (queue == self.queueForNetworkTransfers) {
                //跟 UI 相关的操作需要到main 线程中执行
                [self performSelectorOnMainThread:@selector(decrementRunningNetworkTransferCount) withObject:nil waitUntilDone:NO];
            }
        }
    } else if (NO) {   // Disabled because the super class does nothing useful with it.
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}


//跟调用 addOperation:toQueue:finishedTarget:action: 的 thread 上执行操作
//主要作用是从 _runningOperationTo*** map 中删除已经添加的数据.也是在那个thread上向 map 添加的数据
//通过监控 operation 的 isFinished 消息,调用本操作
- (void)operationDone:(NSOperation *)operation
    // Called by the operation queue when the operation is done.
    // We find the corresponding target/action and call it on this thread.
{
    id          target;
    SEL         action;
    NSThread *  thread;

    // any thread
    assert(operation != nil);
    // Find the target/action, if any, in the map and then remove it.
    // 在一次,这里为什么  synchronized ? 因为对核心关键map数据的操作,有可能会和 cancel动作有竞争关系.
    @synchronized (self) {//锁定操作开始
        assert( CFDictionaryGetCount(self->_runningOperationToTargetMap) == CFDictionaryGetCount(self->_runningOperationToActionMap) );
        assert( CFDictionaryGetCount(self->_runningOperationToTargetMap) == CFDictionaryGetCount(self->_runningOperationToThreadMap) );

        target =        (id)  CFDictionaryGetValue(self->_runningOperationToTargetMap, operation);
        action =        (SEL) CFDictionaryGetValue(self->_runningOperationToActionMap, operation);
        thread = (NSThread *) CFDictionaryGetValue(self->_runningOperationToThreadMap, operation);
        assert( (target != nil) == (action != nil) );
        assert( (target != nil) == (thread != nil) );

        // We need target to persist across the remove /and/ after we leave the @synchronized 
        // block, so we retain it here.  We need to test target for nil because -cancelOperation: 
        // might have pulled it out from underneath us.
        // 需要保持 target 到后面,并调用它执行 action 的代码, 所以这里需要 retain 一下. 我们还需要测试 target 是否为 nil,
        // 因为下面的 -cancelOperation: 可能赢得了竞争锁,已经从OperationMap里删除了.
        if (target != nil) {
            [target retain];
            assert( thread == [NSThread currentThread] );//这里应该是同一个线程

            CFDictionaryRemoveValue(self->_runningOperationToTargetMap, operation);
            CFDictionaryRemoveValue(self->_runningOperationToActionMap, operation);
            CFDictionaryRemoveValue(self->_runningOperationToThreadMap, operation);
        }
        assert( CFDictionaryGetCount(self->_runningOperationToTargetMap) == CFDictionaryGetCount(self->_runningOperationToActionMap) );
        assert( CFDictionaryGetCount(self->_runningOperationToTargetMap) == CFDictionaryGetCount(self->_runningOperationToThreadMap) );
    }//锁定操作结束
    
    // If we removed the operation, call the target/action.  However, we still have to 
    // test isCancelled here because -cancelOperation: might have cancelled it but 
    // not yet pulled it out of the map.
    //
    // 当测试 isCanceled, 注意这里没有竞争关系, 我们知道,执行到这一步时,operation 已经从 map(特别是在已经执行完@synchronized block后)中被移除了,
    // 所以,没有人可以在此时调用 operation 的 -cancelOperation:方法取消此operation了, 所以, operation 最终的命运,要么已经 cancelled ,要么 not cancelled,
    // 这是在我们进入@synchronized block 前就决定好了的.
    //
    // Note that there's no race condition testing isCancelled here.  We know that the 
    // operation is out of the map at this point (specifically, at the point we leave 
    // the @synchronized block), so no one can call -cancelOperation: on the operation. 
    // So, the final fate of the operation, cancelled or not, is determined before 
    // we enter the @synchronized block.
    if (target != nil) { //如果 Operation顺利完成, 没有被 cancel 动作删除掉
        if ( ! [operation isCancelled] ) { //确保 operation 没有被cancel,然后执行回调函数,不然就不用执行回调函数了.
            //调用 target/action,  operation 为 actin 的一个参数将被 target 执行
            [target performSelector:action withObject:operation];
        }
        [target release];
    }
}

- (void)cancelOperation:(NSOperation *)operation
{
    id          target;
    SEL         action;
    NSThread *  thread;

    // any thread
    // 任何线程都可能执行这个动作
    // 就是简单的client清理代码,我们允许 operation 可以为 nil, operation 也可以没有在 queue 里执行
    // To simplify the client's clean up code, we specifically allow the operation to be nil 
    // and the operation to not be queued.
    if (operation != nil) {
        
        // We do the cancellation outside of the @synchronized block because it might take 
        // some time.
        //这回导致调用 QRunLoopOperation.m 的 cancel 方法,cancel 方法,又会可能在本类的networkRunLoopThread线程上执行一些操作
        [operation cancel];

        // Now we pull the target/action out of the map.
        @synchronized (self) {
            assert( CFDictionaryGetCount(self->_runningOperationToTargetMap) == CFDictionaryGetCount(self->_runningOperationToActionMap) );
            assert( CFDictionaryGetCount(self->_runningOperationToTargetMap) == CFDictionaryGetCount(self->_runningOperationToThreadMap) );

            target =         (id) CFDictionaryGetValue(self->_runningOperationToTargetMap, operation);
            action =        (SEL) CFDictionaryGetValue(self->_runningOperationToActionMap, operation);
            thread = (NSThread *) CFDictionaryGetValue(self->_runningOperationToThreadMap, operation);
            assert( (target != nil) == (action != nil) );
            assert( (target != nil) == (thread != nil) );

            // We don't need to retain target here because we never actually call it, we just 
            // test it for nil.  We need to test for target for nil because -operationDone: 
            // might have won the race to pull it out.
            // 我们不需要在这里 retain target,因为我们不会调用它执行 action.
            // 我们就是简单的在这里测试它是否为 nil. 因为上面的 -operationDone: 方法有竞争关系,有可能已经从 map 中移除了
            if (target != nil) {
                CFDictionaryRemoveValue(self->_runningOperationToTargetMap, operation);
                CFDictionaryRemoveValue(self->_runningOperationToActionMap, operation);
                CFDictionaryRemoveValue(self->_runningOperationToThreadMap, operation);
            }
            assert( CFDictionaryGetCount(self->_runningOperationToTargetMap) == CFDictionaryGetCount(self->_runningOperationToActionMap) );
            assert( CFDictionaryGetCount(self->_runningOperationToTargetMap) == CFDictionaryGetCount(self->_runningOperationToThreadMap) );
        }
    }
}

@end
