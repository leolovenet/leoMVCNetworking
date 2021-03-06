#import <Foundation/Foundation.h>

@interface NetworkManager : NSObject
{
    NSThread *                      _networkRunLoopThread;
    NSOperationQueue *              _queueForNetworkManagement;
    NSOperationQueue *              _queueForNetworkTransfers;
    NSOperationQueue *              _queueForCPU;
    CFMutableDictionaryRef          _runningOperationToTargetMap;
    CFMutableDictionaryRef          _runningOperationToActionMap;
    CFMutableDictionaryRef          _runningOperationToThreadMap;
    NSUInteger                      _runningNetworkTransferCount;
}

// Returns the network manager singleton.
//
// Can be called from any thread.
+ (NetworkManager *)sharedManager;

// Returns a mutable request that's configured to do an HTTP GET operation
// for the specified URL.  This sets up any request properties that should be
// common to all network requests, most notably the user agent string.
//
// Can be called from any thread.
- (NSMutableURLRequest *)requestToGetURL:(NSURL *)url;

// networkInUse is YES if any network transfer operations are in progress;
// you can only call the getter from the main thread.
// 在applicationDidFinishLaunch中添加监控,即在 main thread上监控,根据此属性,决定application's networkActivityIndicatorVisible的值,用于判断在系统状态条上是否现实网络使用的 loading 图标.
@property (nonatomic, assign, readonly ) BOOL  networkInUse;  // observable, always changes on main thread

// Operation dispatch

// We have three operation queues to separate our various operations.  There are a bunch of 
// important points here:
//
// o There are separate network management, network transfer and CPU queues, so that network 
//   operations don't hold up CPU operations, and vice versa.
//
// o 网络管理队列的"宽度"(即, NSOperationQueue 的 maxConcurrentOperationCount 的值) 是不受限制的.
//   这样网络管理操作总是在运行.
//   这样做没有关系,因为网络管理队列是所有 RunLoop 的基础.而消耗的资源很少.
// o The width of the network management queue (that is, the maxConcurrentOperationCount value) 
//   is unbounded, so that network management operations always proceed.  This is fine because 
//   network management operations are all run loop based and consume very few real resources.
//
// o 网络传输队列的"宽度"(即, NSOperationQueue 的 maxConcurrentOperationCount 的值) 是被设定为固定的值.
//   这样控制着我们能够同时运行 network operation 的总数量.
// o The width of the network transfer queue is set to some fixed value, which controls the total 
//   number of network operations that we can be running simultaneously.
//
// o CPU 操作队列的"宽度"(即, NSOperationQueue 的 maxConcurrentOperationCount 的值) ,没有被设置,即,这意味着
//   我们对于没有可以使用的 CPU 核开启一个 CPU operation. 这防止我们设置过多的 CPU operation,也获得不了并行操作的好处.
// o The width of the CPU operation queue is left at the default value, which typically means
//   we start one CPU operation per available core (which on iOS devices means one).  This 
//   prevents us from starting lots of CPU operations that just thrash the scheduler without 
//   getting any concurrency benefits.
//
// o When you queue an operation you must supply a target/action pair that is called when 
//   the operation completes without being cancelled.
//   
//
// o The target/action pair is called on the thread that added the operation to the queue.
//   You have to ensure that this thread runs its run loop.
//
// o If you queue a network operation and that network operation supports the runLoopThread 
//   property and the value of that property is nil, this sets the run loop thread of the operation 
//   to the above-mentioned internal networking thread.  This means that, by default, all 
//   network run loop callbacks run on this internal networking thread.  The goal here is to 
//   minimise main thread latency.
// 
//   It's worth noting that this is only true for network operation run loop callbacks, and is
//   /not/ true for target/action completions.  These are called on the thread that queued 
//   the operation, as described above.
//
// o If you cancel an operation you must do so using -cancelOperation:, lest things get 
//   very confused.
//
// o Both -addXxxOperation:finishedTarget:action: and -cancelOperation: can be called from 
//   any thread.
//
// o If you always cancel the operation on the same thread that you used to queue the operation 
//   (and therefore the same thread that will run the target/action completion), you can be 
//   guaranteed that, after -cancelOperation: returns, the target/action completion will 
//   never be called.
//
// o To simplify clean up, -cancelOperation: does nothing if the supplied operation is nil 
//   or if it's not currently queued.
//
// We don't do any prioritisation of operations, although that would be a relatively 
// simple extension.  For example, you could have one network transfer queue for gallery XML 
// files and another for thumbnail downloads, and tweak their widths appropriately.  And 
// don't forget, within a queue, a client can affect the priority of an operation using 
// -[NSOperation setThreadPriority:] and -[NSOperation setQueuePriority:].

- (void)addNetworkManagementOperation:(NSOperation *)operation finishedTarget:(id)target action:(SEL)action;
- (void)addNetworkTransferOperation:(NSOperation *)operation finishedTarget:(id)target action:(SEL)action;
- (void)addCPUOperation:(NSOperation *)operation finishedTarget:(id)target action:(SEL)action;
- (void)cancelOperation:(NSOperation *)operation;

@end
