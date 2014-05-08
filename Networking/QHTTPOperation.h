#import "QRunLoopOperation.h"

/*
    QHTTPOperation is a general purpose NSOperation that runs an HTTP request. 
    You initialise it with an HTTP request and then, when you run the operation, 
    it sends the request and gathers the response.  It is quite a complex 
    object because it handles a wide variety of edge cases, but it's very 
    easy to use in simple cases:

    1. create the operation with the URL you want to get
    
    op = [[[QHTTPOperation alloc] initWithURL:url] autorelease];
    
    2. set up any non-default parameters, for example, set which HTTP 
       content types are acceptable
    
    op.acceptableContentTypes = [NSSet setWithObject:@"text/html"];
    
    3. enqueue the operation
    
    [queue addOperation:op];
    
    4. finally, when the operation is done, use the lastResponse and 
       error properties to find out how things went
       最后,当 opertaion 完成以后,用 lastResponse 和 error 属性判断执行的结果.
 
    
    As mentioned above, QHTTPOperation is very general purpose.  There are a 
    large number of configuration and result options available to you.
    
    o You can specify a NSURLRequest rather than just a URL.
    
    o You can configure the run loop and modes on which the NSURLConnection is 
      scheduled.
    
    o You can specify what HTTP status codes and content types are OK.
      
    o You can set an authentication delegate to handle authentication challenges.
    
    o You can accumulate responses in memory or in an NSOutputStream. 
    
    o For in-memory responses, you can specify a default response size 
      (used to size the response buffer) and a maximum response size 
      (to prevent unbounded memory use).
    
    o You can get at the last request and the last response, to track 
      redirects.

    o There are a variety of funky debugging options to simulator errors 
      and delays.
      
    Finally, it's perfectly reasonable to subclass QHTTPOperation to meet you 
    own specific needs.  Specifically, it's common for the subclass to 
    override -connection:didReceiveResponse: in order to setup the output 
    stream based on the specific details of the response.
    最后,你完全可以子类化 QHTTPOperation 去满足你自己的特定需求. 
    特别是, 通常对于子类重写 -connection:didReceiveResponse: 方法, 对于回应(response)的特定细节指定 output stream.
*/

@protocol QHTTPOperationAuthenticationDelegate;

extern NSString * kQHTTPOperationErrorDomain;

// positive error codes are HTML status codes (when they are not allowed via acceptableStatusCodes[default is nil, implying 200..299] )
//
// 0 is, of course, not a valid error code
//
// negative error codes are errors from the module
enum {
    kQHTTPOperationErrorResponseTooLarge = -1,
    kQHTTPOperationErrorOnOutputStream   = -2,
    kQHTTPOperationErrorBadContentType   = -3
};


@interface QHTTPOperation : QRunLoopOperation /* <NSURLConnectionDelegate> */
{
    NSURLRequest *      _request;
    NSIndexSet *        _acceptableStatusCodes;
    NSSet *             _acceptableContentTypes;
    id<QHTTPOperationAuthenticationDelegate>    _authenticationDelegate;
    NSOutputStream *    _responseOutputStream;
    NSUInteger          _defaultResponseSize;
    NSUInteger          _maximumResponseSize;
    NSURLConnection *   _connection;
    BOOL                _firstData;         // 用来标识,是否已经初始化了 dataAccumulator
    NSMutableData *     _dataAccumulator;   // 用来保存陆续到来的网络回应数据
    NSURLRequest *      _lastRequest;
    NSHTTPURLResponse * _lastResponse;      // 因为URL请求可能有重定向的情况,所以此属性保存最近一次的服务器HTTP回应头信息
    NSData *            _responseBody;      // 用于保存服务器的回应数据,是在回应数据传输完成以后,将 _dataAccumulator 的值付给 responseBody
#if ! defined(NDEBUG)
    NSError *           _debugError;
    NSTimeInterval      _debugDelay;
    NSTimer *           _debugDelayTimer;
#endif
}

- (id)initWithRequest:(NSURLRequest *)request;      // designated
- (id)initWithURL:(NSURL *)url;                     // convenience, calls +[NSURLRequest requestWithURL:]



//注意这些 property 都是线程安全的 atomic



// Things that are configured by the init method and can't be changed.
@property (copy,   readonly)  NSURLRequest *        request;
@property (copy,   readonly)  NSURL *               URL;


// Things you can configure before queuing the operation.
// runLoopThread and runLoopModes inherited from QRunLoopOperation
@property (copy,   readwrite) NSIndexSet *          acceptableStatusCodes;  // default is nil, implying 200..299
@property (copy,   readwrite) NSSet *               acceptableContentTypes; // default is nil, implying anything is acceptable,接收到的网络数据类型MIMEType是否可用
@property (assign, readwrite) id<QHTTPOperationAuthenticationDelegate>  authenticationDelegate;

#if ! defined(NDEBUG)
@property (copy,   readwrite) NSError *             debugError;             // default is nil
@property (assign, readwrite) NSTimeInterval        debugDelay;             // default is none
#endif

// Things you can configure up to the point where you start receiving data. 
// Typically you would change these in -connection:didReceiveResponse:, but 
// it is possible to change them up to the point where -connection:didReceiveData: 
// is called for the first time (that is, you could override -connection:didReceiveData: 
// and change these before calling super).
// 当你开始接受 data 时,你可以进行配置
// 典型的作法是,你可能会改变这些值在 -connection:didReceiveResponse: 方法里,
// 但那也是可能的,当 -connection:didReceiveData: 第一次调用的时候,改变他们的值.
// (即,你可以重写 -connection:didReceiveData: 并在 调用 super 之前改变他们)

// IMPORTANT: If you set a response stream, QHTTPOperation calls the response 
// stream synchronously.  This is fine for file and memory streams, but it would 
// not work well for other types of streams (like a bound pair).

@property (retain, readwrite) NSOutputStream *      responseOutputStream;   // defaults to nil, which puts response into responseBody
@property (assign, readwrite) NSUInteger            defaultResponseSize;    // default is 1 MB, ignored if responseOutputStream is set
@property (assign, readwrite) NSUInteger            maximumResponseSize;    // default is 4 MB, ignored if responseOutputStream is set
                                                                            // defaults are 1/4 of the above on embedded

// Things that are only meaningful after a response has been received;
@property (assign, readonly, getter=isStatusCodeAcceptable)  BOOL statusCodeAcceptable;
@property (assign, readonly, getter=isContentTypeAcceptable) BOOL contentTypeAcceptable;



// Things that are only meaningful after the operation is finished.
// error property inherited from QRunLoopOperation
@property (copy,   readonly)  NSURLRequest *        lastRequest;       
@property (copy,   readonly)  NSHTTPURLResponse *   lastResponse;       

@property (copy,   readonly)  NSData *              responseBody;   

@end


#pragma mark - Categories NSURLConnectionDelegate 

@interface QHTTPOperation (NSURLConnectionDelegate)

// QHTTPOperation implements all of these methods, so if you override them 
// you must consider whether or not to call super.
//
// These will be called on the operation's run loop thread.


// Routes the request to the authentication delegate if it exists, otherwise just returns NO.
- (BOOL)connection:(NSURLConnection *)connection canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)protectionSpace;

// Routes the request to the authentication delegate if it exists, otherwisejust cancels the challenge.
- (void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;

// Latches the request and response in lastRequest and lastResponse.
- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response;

// Latches the response in lastResponse.
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response;

// If this is the first chunk of data, it decides whether the data is going to be
// routed to memory (responseBody) or a stream (responseOutputStream) and makes the
// appropriate preparations.  For this and subsequent data it then actually shuffles
// the data to its destination.
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data;

// Completes the operation with either no error (if the response status code is acceptable)
// or an error (otherwise).
- (void)connectionDidFinishLoading:(NSURLConnection *)connection;

// Completes the operation with the error.
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error;

@end



#pragma mark - Protocol QHTTPOperationAuthenticationDelegate
@protocol QHTTPOperationAuthenticationDelegate <NSObject>
@required
// These are called on the operation's run loop thread and have the same semantics as their 
// NSURLConnection equivalents.  It's important to realise that there is no 
// didCancelAuthenticationChallenge callback (because NSURLConnection doesn't issue one to us).  
// Rather, an authentication delegate is expected to observe the operation and cancel itself 
// if the operation completes while the challenge is running.

// 这些在 operation runLoop 线程[NetworkManger 的 网络传输队列(queueForNetworkTransfers)]上被调用,跟在 NSURLConnection 上调用具有同等的意义.
// 很重要的一点是, 认识到这些方法不是  didCancelAuthenticationChallenge 方法的回调函数. (因为 NSURLConnection 不会向我们发起回调)
// 当然了, 如果operation在challenge在运行的时候完成, 认证委托(authentication delegate)是被期望具有监控 operation 和可以 cancel 他自己的能力.

- (BOOL)httpOperation:(QHTTPOperation *)operation canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)protectionSpace;
- (void)httpOperation:(QHTTPOperation *)operation didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;

@end


