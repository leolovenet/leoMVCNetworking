#import "QRunLoopOperation.h"

/*
    RetryingHTTPOperation is a run loop based concurrent operation that initiates 
    an HTTP request and handles retrying the request if it fails.  There are a bunch 
    of important points to note:
    RetryingHTTPOperation 是一个基于 run loop 的并行操作. 他初始化一个 HTTP 请求,并且在请求失败后,重新尝试.
    这里有一些需要注意的地方:
      
    o You should only use this class for idempotent requests, that is, requests that 
      won't cause problems if they are retried.  See RFC 2616 for more info on this topic.
      <http://www.ietf.org/rfc/rfc2616.txt>
      你应该只用本类进行一些幂等的请求,即, 多次同样的请求不会导致问题.
    
    o It only retries requests where the result is likely to change.  For example, 
      there's no point retrying after an HTTP 404 status code.  The (private) method 
      -shouldRetryAfterError: controls what will and won't be retried.
      它只有像在请求结果改变的时候重新尝试请求.比如,如果收到一个 HTTP 404 的回应代码后,就不会重新尝试获取.
      私有方法 -shouldRetryAfterError: 控制着什么时候 尝试或者不尝试 重新获取.

    o The fundamental retry mechanism is a random expotential back-off algorithm. 
      After a failure it choose a random delay between the 0 and the max delay. 
      Each failure increases the maximum delay up to some overall limit.  The current 
      max delay sequence is one second, one minute, one hour, and six hours. 
      You can tweak this by changing kRetryDelays.
      基础的重试机制是一个随机的 指数后退算法. 当一个请求失败, 它在0 和 max dely 之间选择一个随机的延迟.
      每次的尝试失败,会增加 延迟 直到最大延迟限制. 当前的最大延迟是 1 秒, 1分, 1个小时, 6个小时.
      你可以改变这个值,通过 kRetryDelays.

    o In addition to this it does a fast retry if one of the following things happens:
      当下面的这些情况下,会进行 快速重新尝试:
 
      - The reachability status of the host associated with the request changes from 
        unreachable to reachable.  The change from unreachable to reachable indicates 
        that the local network environment has changed sufficiently to justify a 
        fresh retry.
        关于目的主机的 reachability 状态从 unreachable 改变到 reachable.
        这个改变,标志这本地网络环境改变已经足以进行一个新的重新尝试.
 
      - Some other request to that host succeeds, which is a good indication that 
        other requests will succeed as well.
        一些到这个主机的其他请求成功了. 这是一个号的标志,剩下的请求也将会成功.

 
    o The operation runs out of the run loop associated with the actualRunLoopThread 
      inherited from QRunLoopOperation.  If you observe any properties, expect them 
      to be changed by that thread.
      运行这个 operation 的 runloop 跟继承自 QRunLoopOperation 的 actualRunLoopThread
      如果你在监控任何 properties , 期望他们改变的话,在那个线程上运行.
 
    o The exception is the hasHadRetryableFailure property.  This property is always 
      changed by the main thread.  This makes it easy for main thread code to display a 'retrying' user interface.
      这里例外是 hasHadRetryableFailure property.这个 property 总是在 main 线程上改变. 
      这使 main 线程代码很容易展示 'retrying' 的用户界面.
 
*/

@class QHTTPOperation;
@class QReachabilityOperation;

typedef NS_ENUM(NSInteger, RetryingHTTPOperationState) {
    kRetryingHTTPOperationStateNotStarted,
    kRetryingHTTPOperationStateGetting,
    kRetryingHTTPOperationStateWaitingToRetry,
    kRetryingHTTPOperationStateRetrying,
    kRetryingHTTPOperationStateFinished
};

@interface RetryingHTTPOperation : QRunLoopOperation
{
    NSUInteger                  _sequenceNumber;
    NSURLRequest *              _request;
    NSSet *                     _acceptableContentTypes;
    NSString *                  _responseFilePath;
    NSHTTPURLResponse *         _response;        //因为URL请求可能有重定向的情况,所以此属性保存最近一次的服务器HTTP回应头信息,从 QHTTPOperation的lastResponse获得
    NSData *                    _responseContent; //和上面对应的,请求回应得到的数据.从 QHTTPOperation的responseBody获得
    RetryingHTTPOperationState  _retryState;
    RetryingHTTPOperationState  _retryStateClient;
    QHTTPOperation *            _networkOperation;
    BOOL                        _hasHadRetryableFailure;
    NSUInteger                  _retryCount;
    NSTimer *                   _retryTimer;
    QReachabilityOperation *    _reachabilityOperation;
    BOOL                        _notificationInstalled;
}

// Initialise the operation to run the specified HTTP request.
- (id)initWithRequest:(NSURLRequest *)request;



//注意这些 property 都是线程安全的 atomic


// Things that are configured by the init method and can't be changed.
// 这个属性是被 init 方法配置的, 并且不能修改
@property (copy,   readonly)  NSURLRequest *                request;

// Things you can configure before queuing the operation.
// runLoopThread and runLoopModes inherited from QRunLoopOperation
// 这些属性是可以修改的,在加入到 queue 之前 , runLoopThread  和  runLoopModes 从 QRunLoopOperation 继承
@property (copy,   readwrite) NSSet *                       acceptableContentTypes; // default is nil, implying anything is acceptable
@property (retain, readwrite) NSString *                    responseFilePath;       // defaults to nil, which puts response into responseContent

// Things that change as part of the progress of the operation.
// 这些是被作为  operation 进程的一部,并且随状态值的变化而变化. 所以是只读.
@property (assign, readonly ) RetryingHTTPOperationState    retryState;             // observable, always changes on actualRunLoopthread
// retryStateClient 属性被 Model 层 PhotoGallery 在 main thread 上访问这个属性,用于判断在 UI 的状态条上表明什么文字. 所以这个属性值的更改也必须在主线程上面.
@property (assign, readonly ) RetryingHTTPOperationState    retryStateClient;       // observable, always changes on /main/ thread
// hasHadRetryableFailure 属性被 Model 层 Photo 在 main thread 上访问,用于判断 thumbnail 的 placehoder 是否需要更新placehoder,表示图片获取在重新尝试. 所以这个属性值的更改也必须在主线程上面.
@property (assign, readonly ) BOOL                          hasHadRetryableFailure; // observable, always changes on /main/ thread
@property (assign, readonly ) NSUInteger                    retryCount;             // observable, always changes on actualRunLoopthread

// Things that are only meaningful after the operation is finished.
// 这些只有在 operation  完成后才有意义.
// error property inherited from QRunLoopOperation
@property (copy,   readonly ) NSString *                    responseMIMEType;       // MIME type of responseContent
@property (copy,   readonly ) NSData *                      responseContent;        // responseContent (nil if response content went to responseFilePath)

@end
