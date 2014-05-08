#import "QHTTPOperation.h"

// kQHTTPOperationErrorDomain 已经在.h 文件中声明为了extern 存储类型
NSString * kQHTTPOperationErrorDomain = @"kQHTTPOperationErrorDomain";

@interface QHTTPOperation ()

//注意这些 property 都是线程安全的 atomic

// Read/write versions of public properties
@property (copy,   readwrite) NSURLRequest *        lastRequest;
@property (copy,   readwrite) NSHTTPURLResponse *   lastResponse;

// Internal properties
@property (retain, readwrite) NSURLConnection *     connection;
//一般为 C primitive properties 指定为 assign
@property (assign, readwrite) BOOL                  firstData;        //用来标识,是否已经初始化了 dataAccumulator
@property (retain, readwrite) NSMutableData *       dataAccumulator;  //用来保存陆续到来的网络回应数据

#if ! defined(NDEBUG)
@property (retain, readwrite) NSTimer *             debugDelayTimer;
#endif

@end




@implementation QHTTPOperation
#pragma mark - NS_DESIGNATED_INITIALIZER and finalise

// any thread
- (id)initWithRequest:(NSURLRequest *)request
{
    assert(request != nil);
    assert([request URL] != nil);
    // Because we require an NSHTTPURLResponse, we only support HTTP and HTTPS URLs.
    assert([[[[request URL] scheme] lowercaseString] isEqual:@"http"] || [[[[request URL] scheme] lowercaseString] isEqual:@"https"]);
    
    self = [super init];
    if (self != nil) {
        
#if TARGET_OS_EMBEDDED || TARGET_IPHONE_SIMULATOR
        static const NSUInteger kPlatformReductionFactor = 4;
#else
        static const NSUInteger kPlatformReductionFactor = 1;
#endif
        
        self->_request = [request copy];
        self->_defaultResponseSize = 1 * 1024 * 1024 / kPlatformReductionFactor; // default is 1 MB, ignored if responseOutputStream is set
        self->_maximumResponseSize = 4 * 1024 * 1024 / kPlatformReductionFactor; // default is 4 MB, ignored if responseOutputStream is set
        self->_firstData = YES; //初始化一个开关符,表示是第一次接受网络数据,用于控制是否初始化 self.dataAccumulator
    }
    return self;
}

- (id)initWithURL:(NSURL *)url
{
    assert(url != nil);
    return [self initWithRequest:[NSURLRequest requestWithURL:url]];
}

- (void)dealloc
{
#if ! defined(NDEBUG)
    [self->_debugError release];
    [self->_debugDelayTimer invalidate];
    [self->_debugDelayTimer release];
#endif
    // any thread
    [self->_request release];
    [self->_acceptableStatusCodes release];
    [self->_acceptableContentTypes release];
    [self->_responseOutputStream release];
    assert(self->_connection == nil);               // should have been shut down by now
    [self->_dataAccumulator release];
    [self->_lastRequest release];
    [self->_lastResponse release];
    [self->_responseBody release];
    [super dealloc];
}

#pragma mark - Properties

@synthesize request = _request;
@synthesize authenticationDelegate = _authenticationDelegate;
@synthesize acceptableContentTypes = _acceptableContentTypes;
@synthesize acceptableStatusCodes = _acceptableStatusCodes;
@synthesize responseOutputStream = _responseOutputStream;
@synthesize defaultResponseSize   = _defaultResponseSize;
@synthesize maximumResponseSize = _maximumResponseSize;
@synthesize lastRequest     = _lastRequest;
@synthesize lastResponse    = _lastResponse;
@synthesize responseBody    = _responseBody;

@synthesize connection      = _connection;
@synthesize firstData       = _firstData;
@synthesize dataAccumulator = _dataAccumulator;



#pragma mark - Methods
// We write our own settings for many properties because we want to bounce
// sets that occur in the wrong state.  And, given that we've written the
// setter anyway, we also avoid KVO notifications when the value doesn't change.
// 我们为很多 properties 手写 setter 方法,因为我们想确保 setter 不会遇到错误的 connection 状态,并且调用 KVO 通知那些值做了改变.



//关闭对 authenticationDelegate 的自动 KVO 通知
+ (BOOL)automaticallyNotifiesObserversOfAuthenticationDelegate
{
    return NO;
}

- (id<QHTTPOperationAuthenticationDelegate>)authenticationDelegate
{
    return self->_authenticationDelegate;
}

- (void)setAuthenticationDelegate:(id<QHTTPOperationAuthenticationDelegate>)newValue
{
    if (self.state != kQRunLoopOperationStateInited) {
        assert(NO);
    } else {
        if (newValue != self->_authenticationDelegate) {
            [self willChangeValueForKey:@"authenticationDelegate"];
            self->_authenticationDelegate = newValue;
            [self didChangeValueForKey:@"authenticationDelegate"];
        }
    }
}


//关闭对 acceptableStatusCodes 的自动 KVO 通知
+ (BOOL)automaticallyNotifiesObserversOfAcceptableStatusCodes
{
    return NO;
}

// 可以接受的 HTTP 回应 状态码,默认是200...299
- (NSIndexSet *)acceptableStatusCodes
{
    return [[self->_acceptableStatusCodes retain] autorelease];
}

- (void)setAcceptableStatusCodes:(NSIndexSet *)newValue
{
    if (self.state != kQRunLoopOperationStateInited) {
        assert(NO);
    } else {
        if (newValue != self->_acceptableStatusCodes) {
            [self willChangeValueForKey:@"acceptableStatusCodes"];
            [self->_acceptableStatusCodes autorelease];
            self->_acceptableStatusCodes = [newValue copy];
            [self didChangeValueForKey:@"acceptableStatusCodes"];
        }
    }
}



//关闭对 acceptableContentTypes 的自动 KVO 通知
+ (BOOL)automaticallyNotifiesObserversOfAcceptableContentTypes
{
    return NO;
}
//检查 接收到的网络数据类型 MIMEType 是否可用,默认为 nil,表示所有的都可用
- (NSSet *)acceptableContentTypes
{
    return [[self->_acceptableContentTypes retain] autorelease];
}

- (void)setAcceptableContentTypes:(NSSet *)newValue
{
    if (self.state != kQRunLoopOperationStateInited) {
        assert(NO);
    } else {
        if (newValue != self->_acceptableContentTypes) {
            [self willChangeValueForKey:@"acceptableContentTypes"];
            [self->_acceptableContentTypes autorelease];
            self->_acceptableContentTypes = [newValue copy];
            [self didChangeValueForKey:@"acceptableContentTypes"];
        }
    }
}



//关闭对 responseOutputStream 的自动 KVO 通知
+ (BOOL)automaticallyNotifiesObserversOfResponseOutputStream
{
    return NO;
}

- (NSOutputStream *)responseOutputStream
{
    return [[self->_responseOutputStream retain] autorelease];
}

- (void)setResponseOutputStream:(NSOutputStream *)newValue
{
    if (self.dataAccumulator != nil) {
        assert(NO);
    } else {
        if (newValue != self->_responseOutputStream) {
            [self willChangeValueForKey:@"responseOutputStream"];
            [self->_responseOutputStream autorelease];
            self->_responseOutputStream = [newValue retain];
            [self didChangeValueForKey:@"responseOutputStream"];
        }
    }
}


//关闭对 defaultResponseSize 的自动 KVO 通知
+ (BOOL)automaticallyNotifiesObserversOfDefaultResponseSize
{
    return NO;
}

- (NSUInteger)defaultResponseSize
{
    return self->_defaultResponseSize;
}

- (void)setDefaultResponseSize:(NSUInteger)newValue
{
    if (self.dataAccumulator != nil) {
        assert(NO);
    } else {
        if (newValue != self->_defaultResponseSize) {
            [self willChangeValueForKey:@"defaultResponseSize"];
            self->_defaultResponseSize = newValue;
            [self didChangeValueForKey:@"defaultResponseSize"];
        }
    }
}




//关闭对 maximumResponseSize 的自动 KVO 通知
+ (BOOL)automaticallyNotifiesObserversOfMaximumResponseSize
{
    return NO;
}

- (NSUInteger)maximumResponseSize
{
    return self->_maximumResponseSize;
}

- (void)setMaximumResponseSize:(NSUInteger)newValue
{
    if (self.dataAccumulator != nil) {
        assert(NO);
    } else {
        if (newValue != self->_maximumResponseSize) {
            [self willChangeValueForKey:@"maximumResponseSize"];
            self->_maximumResponseSize = newValue;
            [self didChangeValueForKey:@"maximumResponseSize"];
        }
    }
}





- (NSURL *)URL
{
    return [self.request URL];
}


//检查上一次请求回应的 Status Code 是否大于0,且在可以接受范围内(默认为200...299)
- (BOOL)isStatusCodeAcceptable
{
    NSIndexSet *    acceptableStatusCodes;
    NSInteger       statusCode;
    
    assert(self.lastResponse != nil);
    
    acceptableStatusCodes = self.acceptableStatusCodes; //默认为nil,暗指 200...299
    if (acceptableStatusCodes == nil) { //如果是默认空值,那么创建一个
        acceptableStatusCodes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(200, 100)];
    }
    assert(acceptableStatusCodes != nil);
    
    statusCode = [self.lastResponse statusCode];
    return (statusCode >= 0) && [acceptableStatusCodes containsIndex: (NSUInteger) statusCode];
}


//检查 接收到的网络数据类型 MIMEType 是否可用,默认为 nil,表示所有的都可用
- (BOOL)isContentTypeAcceptable
{
    NSString *  contentType;
    
    assert(self.lastResponse != nil);
    contentType = [self.lastResponse MIMEType];
    return (self.acceptableContentTypes == nil) || ((contentType != nil) && [self.acceptableContentTypes containsObject:contentType]);
}


#pragma mark  - QRunLoopOperation (Categories)  methods  overrides 本类实例对象被调用的第一个方法
/*!
 *   此方法重写父类的方法,在本类的实例 operation 被添加到 NSOperationQueue 后,默认调用父类的 start 函数,然后再间接的调用本方法
 *   本方法对象在 model/RetryingHTTPOperation.m 的 - (void)startRequest 中被创建,并入 Queue,详细描述查看那个方法
 *
 *   本方法是在 NetworkManger 的 网络传输队列(queueForNetworkTransfers)里执行的.
 *
 *   Called by QRunLoopOperation when the operation starts.  This kicks of an asynchronous NSURLConnection.
 */
- (void)operationDidStart
{
    assert(self.isActualRunLoopThread);
    assert(self.state == kQRunLoopOperationStateExecuting); //在父类的 - (void)start 中改变状态,检查是否成功.
    
    assert(self.defaultResponseSize > 0);
    assert(self.maximumResponseSize > 0);
    assert(self.defaultResponseSize <= self.maximumResponseSize);
    
    assert(self.request != nil);
    
    // If a debug error is set, apply that error rather than running the connection.
#if ! defined(NDEBUG)
    if (self.debugError != nil) {
        [self finishWithError:self.debugError];
        return;
    }
#endif

    // Create a connection that's scheduled in the required run loop modes.
    assert(self.connection == nil);
    self.connection = [[[NSURLConnection alloc] initWithRequest:self.request delegate:self startImmediately:NO] autorelease];
    assert(self.connection != nil);
    
    for (NSString * mode in self.actualRunLoopModes) {
        // NetworkManger 的 网络传输队列(queueForNetworkTransfers)
        // 安排 connection 在当前线程以当前 mode 执行.
        [self.connection scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:mode];
    }
    
    // Causes the connection to begin loading data
    [self.connection start];
}


/*!
 *  Called by QRunLoopOperation when the operation has finished.  We do various bits of tidying up.
 */
- (void)operationWillFinish
{
    assert(self.isActualRunLoopThread);
    assert(self.state == kQRunLoopOperationStateExecuting);

    // It is possible to hit this state of the operation is cancelled while 
    // the debugDelayTimer is running.  In that case, hey, we'll just accept 
    // the inevitable and finish rather than trying anything else clever.
#if ! defined(NDEBUG)
        if (self.debugDelayTimer != nil) {
            [self.debugDelayTimer invalidate];
            self.debugDelayTimer = nil;
        }
#endif

    [self.connection cancel];
    self.connection = nil;

    //  If we have an output stream, close it at this point.
    //  We might never have actually opened this stream but,
    //  AFAICT(As Far As I Can Tell), closing an unopened stream doesn't hurt.
    //  关闭输出到文件的 output stream, 这个 output stream 可能从来没有调用 open 方法打开,但是我们调用 close 也没有关系.
    if (self.responseOutputStream != nil) {
        [self.responseOutputStream close];
    }
}


// We override -finishWithError: just so we can handle our debug delay.
- (void)finishWithError:(NSError *)error
{
      // If a debug delay was set, don't finish now but rather start the debug delay timer 
    // and have it do the actual finish.  We clear self.debugDelay so that the next 
    // time this code runs its doesn't do this again.
    //
    // We only do this in the non-cancellation case.  In the cancellation case, we 
    // just stop immediately.
    
#if ! defined(NDEBUG)
        if (self.debugDelay > 0.0) {
            if ( (error != nil) && [[error domain] isEqual:NSCocoaErrorDomain] && ([error code] == NSUserCancelledError) ) {
                self.debugDelay = 0.0;
            } else {
                assert(self.debugDelayTimer == nil);
                self.debugDelayTimer = [NSTimer timerWithTimeInterval:self.debugDelay
                                                               target:self
                                                             selector:@selector(debugDelayTimerDone:)
                                                             userInfo:error
                                                              repeats:NO];
                assert(self.debugDelayTimer != nil);
                for (NSString * mode in self.actualRunLoopModes) {
                    [[NSRunLoop currentRunLoop] addTimer:self.debugDelayTimer forMode:mode];
                }
                self.debugDelay = 0.0;
                return;
            }
        } 
#endif

    [super finishWithError:error]; //这将导致调用 [self operationWillFinish]
}



#pragma mark -  For Debug

#if ! defined(NDEBUG)

@synthesize debugError      = _debugError;
@synthesize debugDelay      = _debugDelay;
@synthesize debugDelayTimer = _debugDelayTimer;

- (void)debugDelayTimerDone:(NSTimer *)timer
{
    NSError *   error;
    
    assert(timer == self.debugDelayTimer);

    error = [[[timer userInfo] retain] autorelease];
    assert( (error == nil) || [error isKindOfClass:[NSError class]] );
    
    [self.debugDelayTimer invalidate];
    self.debugDelayTimer = nil;
    
    [self finishWithError:error];
}

#endif


#pragma mark - NSURLConnectionDelegate  Callbacks

/*!
 *  如果我们实现了  connection:willSendRequestForAuthenticationChallenge: 方法, 本方法就不会被掉用了.
 *  这个方法,在调用  connection:didReceiveAuthenticationChallenge: 之前调用.
 *  允许 delegate 在尝试对一个受保护的区域进行认证之前,进行检测.
 *  如果本方法返回 YES 的话,表明 delegate 可以在后面调用的 connection:didReceiveAuthenticationChallenge: 方法里处理认证请求.
 *  如果本方法返回 NO 的话,系统尝试用 user keychain 进行认证.
 *
 *  如果 deleget 没有实现本方法的话:
 *      1. 受保护的区域对使用客户端证书认证(client certificate authentication)或服务器信任认证(server trust authentication),系统的行为就像你使本方法返回 NO.
 *      2. 对于其他的认证方式,就像本方法返回 YES.
 *
 *  本方法是在 NetworkManger 的 网络传输队列(queueForNetworkTransfers)里执行的.
 *
 *  Routes the request to the "authentication delegate" if it exists, otherwise just returns NO.
 *
 *  @param connection  发送这个消息的NSURLConnection 对象
 *  @param protectionSpace 生成认证请求的受保护区域.
 *
 *  @return YES / No
 */
- (BOOL)connection:(NSURLConnection *)connection canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)protectionSpace
{
    BOOL    result;
    
    assert(self.isActualRunLoopThread);
    assert(connection == self.connection);
    #pragma unused(connection)
    assert(protectionSpace != nil);
    #pragma unused(protectionSpace)
    
    result = NO;
    if (self.authenticationDelegate != nil) {
        result = [self.authenticationDelegate httpOperation:self canAuthenticateAgainstProtectionSpace:protectionSpace];
    }
    return result;
}

/*!
   o 如果我们实现了  connection:willSendRequestForAuthenticationChallenge: 方法, 本方法就不会被掉用了.
 
   o 这个方法给 delegate 一个机会去决定,遇到进行认证的请求时采取怎样的动作.
       进行认证时可能采取的动作:
            provide credentials
            continue without providing credentials
            cancel the authentication challenge and the download
 
    o delegate 可以通过向 challenge 发送 previousFailureCount 方法,获取之前已经进行了的身份验证次数.
    
    o 如果之前的失败认证次数是 0 ,并且 proposedCredential 方法返回值为 nil, 那么 delegate 可以创建一个新的 NSURLCredential 对象,
        该credential对象为指定的证书(credential)提供信息,
        并且将 credential 和 challenge 作为[chanllenge sender]向 useCredential:forAuthenticationChallenge: 调用的参数
    
    o 如果 proposedCredential 方法返回的不为 nil,
        那么返回的要不然是和 URL 对应的证书,
        要不然是共享证书存储(shared credentail storage)
      可以被作为 feedback 提供给 user .
    
    o delegate 可以在任何时间向 [chanllenge sender] 发送
        continueWithoutCredentialForAuthenticationChallenge:
        cancelAuthenticationChallenge: 
      消息,来放弃将来的身份验证尝试.
 
    o 如果 delegate 实现了本方法,那么 download 将会悬挂起来,除非向 [challenge sender] 发送下面之一的方法:
        (1) useCredential:forAuthenticationChallenge:
        (2) continueWithoutCredentialForAuthenticationChallenge:
        (3) cancelAuthenticationChallenge:.
 
    o 如果 delegate 没有实现本方法,那么这个方法默认的实现将被使用.
        (1) 若关于 request 的一个验证过了的证书(credentail)被作为 URL 的一部分提供, 或者从 NSURLCredentialStorage 获得一个可用的证书,
            那么 [challenge sender] 将使用该证书并调用 useCredential:forAuthenticationChallenge: .
        (2) 如果身份认证没有证书(credential)或证书认证失败,然后 [challenge sender] 会被发送  continueWithoutCredentialForAuthenticationChallenge: 方法

 
 *  @param connection
 *  @param challenge
 */
- (void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
    // See comment in header.
{
    assert(self.isActualRunLoopThread);
    assert(connection == self.connection);
    #pragma unused(connection)
    assert(challenge != nil);
    #pragma unused(challenge)
    
    if (self.authenticationDelegate != nil) {
        [self.authenticationDelegate httpOperation:self didReceiveAuthenticationChallenge:challenge];
    } else {
        if ( [challenge previousFailureCount] == 0 ) {  //第一次进行身份认证尝试

            //Attempt to continue downloading a request without providing a credential for a given challenge.
            [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge];
            
        } else {
            [[challenge sender] cancelAuthenticationChallenge:challenge]; //取消认证,Cancels a given authentication challenge.
        }
    }
}

// 当连接加载一个 request 去 load 数据的时候遇到错误,会调用此方法
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    assert(self.isActualRunLoopThread);
    assert(connection == self.connection);
#pragma unused(connection)
    assert(error != nil);
    
    [self finishWithError:error];  //这个导致调用本类的 - (void)operationWillFinish 方法
}

#pragma mark - NSURLConnectionDataDelegate Protocol
/*!
 *  Handling Redirects
 *  Sent when the connection determines that it must change URLs in order to continue loading a request.
 *
 *  Latches the request and response in lastRequest and lastResponse.
    将上一次的 request 和 respose 栓在一起,并存入 lastRequest 和  lastResponse 中.
 *  @param connection
 *  @param request
 *  @param response
 *
 *  @return NSURLRequest
 */
- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response
{
    #pragma unused(connection)
    assert(self.isActualRunLoopThread);
    assert(connection == self.connection);
    assert( (response == nil) || [response isKindOfClass:[NSHTTPURLResponse class]] );

    self.lastRequest  = request;
    self.lastResponse = (NSHTTPURLResponse *) response;
    return request;
}

/*
 response 的例子:
 <NSHTTPURLResponse: 0x3a6740> { URL: http://leo-macbook-pro.local:8888/TestGallery/index2.xml } 
 { 
 status code: 200, headers {
 "Accept-Ranges" = bytes;
 Connection = "keep-alive";
 "Content-Length" = 3751;
 "Content-Type" = "text/xml";
 Date = "Thu, 24 Apr 2014 04:52:54 GMT";
 Etag = "\"4ca5ca74-ea7\"";
 "Last-Modified" = "Fri, 01 Oct 2010 11:48:04 GMT";
 Server = "nginx/1.4.4";
 }
 }
*/

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    #pragma unused(connection)
    assert(self.isActualRunLoopThread);
    assert(connection == self.connection);
    assert([response isKindOfClass:[NSHTTPURLResponse class]]);

    self.lastResponse = (NSHTTPURLResponse *) response;
    
    // We don't check the status code here because we want to give the client an opportunity 
    // to get the data of the error message.  Perhaps we /should/ check the content type 
    // here, but I'm not sure whether that's the right thing to do.
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    BOOL    success;
    
    assert(self.isActualRunLoopThread);
    assert(connection == self.connection);
    #pragma unused(connection)
    assert(data != nil);
    
    // If we don't yet have a destination for the data, calculate one.
    // Note that, even if there is an output stream, we don't use it for error responses.
    success = YES;
    if (self.firstData) { // 初始化类实例时,在方法initWithRequest中标识为 YES
        assert(self.dataAccumulator == nil);
        
        //如果请求回应流 没有指定输出到文件,而是保存内存对象 self.dataAccumulator中
        //或者
        //返回的 HTTP 回应状态码为不可接受状态,我们就不输出到文件里,而是保存内存对象 self.dataAccumulator中
        if ( (self.responseOutputStream == nil) || ! self.isStatusCodeAcceptable ) {
            long long   length;
            
            assert(self.dataAccumulator == nil);
            
            length = [self.lastResponse expectedContentLength]; //期望获得的数据长度
            if (length == NSURLResponseUnknownLength) {
                length = self.defaultResponseSize; //如果没有检测到期望长度,采用默认长度(默认1M)
            }
            if (length <= (long long) self.maximumResponseSize) {
                self.dataAccumulator = [NSMutableData dataWithCapacity:(NSUInteger)length];//并不是真正的分配内存, lenght 为 0
            } else {//大余最大默认长度(4M) 的错误
                [self finishWithError:[NSError errorWithDomain:kQHTTPOperationErrorDomain code:kQHTTPOperationErrorResponseTooLarge userInfo:nil]];
                success = NO;
            }
        }
        
        // If the data is going to an output stream, open it.
        // 如果输出到文件中
        if (success) {
            if (self.dataAccumulator == nil) {
                assert(self.responseOutputStream != nil);
                [self.responseOutputStream open];
            }
        }
        
        self.firstData = NO;
    }
    
    
    // Write the data to its destination.
    // 要不然输出到文件,要不然 self.dataAccumulator
    if (success) {
        if (self.dataAccumulator != nil) { //输出到内存,而不是文件
            if ( ([self.dataAccumulator length] + [data length]) <= self.maximumResponseSize ) {
                [self.dataAccumulator appendData:data];
            } else {  //太大了
                [self finishWithError:[NSError errorWithDomain:kQHTTPOperationErrorDomain code:kQHTTPOperationErrorResponseTooLarge userInfo:nil]];
            }
        } else { //输出到文件里,而不是内存
            NSUInteger      dataOffset;  //用来记录每次写入了多少
            NSUInteger      dataLength;  //用来记录从网络接收到的数据总长度
            const uint8_t * dataPtr;     //保存刚刚接受到的数据的指针,一个执行 const 对象的指针,本身的值可以被改变指向不通的地址,但是不能通过指针改变其所指向的变量的值.
            NSError *       error;
            NSInteger       bytesWritten;//用来记录写入操作每次实际向文件写入了多少

            assert(self.responseOutputStream != nil);

            dataOffset = 0;
            dataLength = [data length];
            dataPtr    = [data bytes];  //新接受到的数据的指针
            error      = nil;
            
            
            //有可能不是将收到的网络数据,一次性的全部写入到文件.而是查看bytesWritten值,慢慢的写入,直到全部写入完成
            do {
                if (dataOffset == dataLength) {
                    break;
                }
                //这次写入到文件多少
                bytesWritten = [self.responseOutputStream write:&dataPtr[dataOffset] maxLength:dataLength - dataOffset];
                if (bytesWritten <= 0) {//写入到文件遇到错误, 为0的话,说明达到了初始化时的 capacity
                    error = [self.responseOutputStream streamError];
                    if (error == nil) {
                        error = [NSError errorWithDomain:kQHTTPOperationErrorDomain code:kQHTTPOperationErrorOnOutputStream userInfo:nil];
                    }
                    break;
                } else { //写成功
                    dataOffset += bytesWritten;
                }
            } while (YES);
            
            if (error != nil) {//遇到错误,就不用继续,直接 cancel 这个 operation
                [self finishWithError:error];
            }
        }
    }
}


// delegate 收到的最后一个消息
- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    assert(self.isActualRunLoopThread);
    assert(connection == self.connection);
    #pragma unused(connection)
    
    assert(self.lastResponse != nil);

    // Swap the data accumulator over to the response data so that we don't trigger a copy.
    assert(self->_responseBody == nil);
    self->_responseBody = self->_dataAccumulator; // NSMutableData -> NSData
    self->_dataAccumulator = nil;
    
    // Because we fill out(填写) _dataAccumulator lazily, an empty body will leave _dataAccumulator set to nil.
    // That's not what our clients expect, so we fix it here.
    if (self->_responseBody == nil) {
        self->_responseBody = [[NSData alloc] init];
        assert(self->_responseBody != nil);
    }
    
    if ( ! self.isStatusCodeAcceptable ) { //如果返回的网络请求回应是 不正常的,不为我们可以接受的, self.acceptableStatusCodes 默认为nil,暗指 200...299
        [self finishWithError:[NSError errorWithDomain:kQHTTPOperationErrorDomain code:self.lastResponse.statusCode userInfo:nil]];
    } else if ( ! self.isContentTypeAcceptable ) { //检查 接收到的网络数据类型 MIMEType 是否可用,默认为 nil,表示所有的都可用
        [self finishWithError:[NSError errorWithDomain:kQHTTPOperationErrorDomain code:kQHTTPOperationErrorBadContentType userInfo:nil]];
    } else {
        [self finishWithError:nil];
    }
}

@end

