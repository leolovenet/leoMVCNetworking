#import "QRunLoopOperation.h"

/*
    Theory of Operation
    -------------------
    Some critical points:
    
     1. By the time we're running on the run loop thread, we know that all further state 
        transitions happen on the run loop thread.  That's because there are only three 
        states (inited, executing, and finished) and run loop thread code can only run 
        in the last two states and the transition from executing to finished is 
        always done on the run loop thread.

     2. -start can only be called once.  So run loop thread code doesn't have to worry 
        about racing with -start because, by the time the run loop thread code runs, 
        -start has already been called.
        -start 只能被调用一次. 所以 run loop thread 代码不必太担心关于调用 -starg 方法的竞争关系, 当 run loop thread 代码运行的时候,
        -start 已经被调用过了.
        
     3. -cancel can be called multiple times from any thread.  Run loop thread code 
        must take a lot of care with do the right thing with cancellation.
        
        -cancel 可以被从任意线程调用多次. Run Loop thread 代码必须仔细照顾好 cancellation 操作.
    
    Some state transitions:

     1. init -> dealloc
     2. init -> cancel -> dealloc
XXX  3. init -> cancel -> start -> finish -> dealloc
     4. init -> cancel -> start -> startOnRunLoopThreadThread -> finish dealloc
!!!  5. init -> start -> cancel -> startOnRunLoopThreadThread -> finish -> cancelOnRunLoopThreadThread -> dealloc
XXX  6. init -> start -> cancel -> cancelOnRunLoopThreadThread -> startOnRunLoopThreadThread -> finish -> dealloc
XXX  7. init -> start -> cancel -> startOnRunLoopThreadThread -> cancelOnRunLoopThreadThread -> finish -> dealloc
 
     8. init -> start -> startOnRunLoopThreadThread -> finish -> dealloc         // 这种是正常执行情况
     9. init -> start -> startOnRunLoopThreadThread -> cancel -> cancelOnRunLoopThreadThread -> finish -> dealloc    //这种是正常取消操作情况
 
!!! 10. init -> start -> startOnRunLoopThreadThread -> cancel -> finish -> cancelOnRunLoopThreadThread -> dealloc
    11. init -> start -> startOnRunLoopThreadThread -> finish -> cancel -> dealloc

    Markup:
        XXX means that the case doesn't happen.
        !!! means that the case is interesting.
        
    Described:
    
     1. It's valid to allocate an operation and never run it.
        分配一个 operation, 但并不运行它是合法的.
 
     2. It's also valid to allocate an operation, cancel it, and yet never run it.
        分配一个 operation ,然后取消它,并不执行,也是合法的.
 
     3. While it's valid to cancel an operation before it starting it, this case doesn't 
        happen because -start always bounces to the run loop thread to maintain the invariant 
        that the executing to finished transition always happens on the run loop thread.
        在一个 operation starting 以前取消它是合法的. 
        但上面的这个情况不会发生,因为 -start 方法总是跳到 run loop thread 去执行startOnRunLoopThreadThread,直到任务结束, 状态转换都是在 run loop thread 中改变
 
     4. In this -startOnRunLoopThread detects the cancellation and finishes immediately.
        在 -startOnRunLoopThread 方法里检测是否取消 指导完成操作.
 
     5. Because the -cancel can happen on any thread, it's possible for the -cancel 
        to come in between the -start and the -startOnRunLoop thread.  In this case 
        -startOnRunLoopThread notices isCancelled and finishes straightaway.  And
        -cancelOnRunLoopThread detects that the operation is finished and does nothing.
        因为 -cancel 可以在任何线程里被调用. 
        -cancel 很可能来自调用 -start 的线程和运行 -startOnRunLoop 线程之间.
        在这种情况下, -startOnRunLoopThread 方法注意到 isCancelled ,然后直接 finishes.
        -cancelOnRunLoopThread 方法检测 operation 如果完成了的话,不做任何事情.
 
     6. This case can never happen because -performSelecton:onThread:xxx 
        callbacks happen in order, -start is synchronised with -cancel, and -cancel 
        only schedules if -start has run.
        这种情况永远不会发生,  - performSelecton:onThread: 和 callback 是按顺序调用的, -start 是和 -cancel 同步的.
        -cancel 只有在 -start 已经运行了的情况下才真正调用.
 
     7. This case can never happen because -startOnRunLoopThread will finish immediately
        if it detects isCancelled (see case 5).
        这个情况永远不会发生, 因为如果 -startOnRunLoopThread 检测到 isCancelled 将会立即 finish.
 
     8. This is the standard run-to-completion case.   这个是正常执行情况.
 
     9. This is the standard cancellation case.  -cancelOnRunLoopThread wins the race 
        with finish, and it detects that the operation is executing and actually cancels. 
        这个是标准的取消操作情况.  -cancelOnRunLoopThread 赢得了执行finish 这个operation 的竞争, 然后它检测操作还在运行, 然后cancel它.最后调用 finish 方法.
 
    10. In this case the -cancelOnRunLoopThread loses the race with finish, but that's OK 
        because -cancelOnRunLoopThread already does nothing if the operation is already 
        finished.
        在这种情况下, -cancelOnRunLoopThread 失去了执行 finish 这个 operation 的权利.但是这并没有关系.
        因为如果这个 operatin 已经执行 finished 的话, -cancelOnRunLoopThread 不用做任何事情.
 
    11. Cancellating after finishing still sets isCancelled but has no impact 
        on the RunLoop thread code.
        在 Operation finished 以后,仍然执行 cancel 设置 isCancelled,对这个 runloop thread没有冲突
*/

/*
    首先本类是个 NSOperation 的子类, 可以被添加到 NSOperationQueue 里执行,也可以直接手工调用 start 方法执行.
 
        注意要点:
            o NSOperation 类是一个 abstract 类,用于封装一个单一的任务. 因为是 abstract 的类,所以不能直接使用,得通过子类去执行任务(像本类一样)
 
            o An operation object is a single-shot object—that is, it executes its task once and cannot be used to execute it again. 
              一个 NSOperation 对象只能执行它的任务一次,不能够被再此执行.(幂等操作是否可以被多次执行?)
        
            o NSOperation 对象要么被添加到NSOperationQueue去执行,要么手工调用它的 start 方法执行.
                    手工执行一个Operation需要自己担负更大的责任,因为执行一个没有准备好的 Operation,会导致异常.
                    isReady 对象方法返回 Operation 是否准备好了.
 
            o 一个 NSOperationQueue 要么直接通过在其他的线程上执行它的 operation, 或者使用 libdispatch(即 GCD)分离出一个新的线程
                总之结果就是, operation 总是在一个分离的线程里执行,直到它们结束或被取消,而不管它们被设计为并发的,或者非并发.
                Note: In iOS 4 and later, operation queues use Grand Central Dispatch to execute operations.
 
            o NSOperationQueue 有两种不同类型的队列：主队列 和 自定义队列。主队列运行在主线程之上，而自定义队列在后台执行
                    (本类被 NetworkMangeer 管理是否设定runLoopThread. 然后决定在那个线程运行)
 
            o 在两种类型中，这些队列所处理的任务都使用 NSOperation 的子类来表述 (就是本类).
 
            o 你可以通过重写 main 或者 start 方法 来定义自己的 operations 
                    前一种方法非常简单，开发者不需要管理一些状态属性(例如isExecuting 和 isFinished )，当 main 方法返回的时候，这个 operation 就结束了.
                    这种方式使用起来非常简单，但是灵活性相对重写 start 来说要少一些
 
            o 如果你希望拥有更多的控制权，以及在一个operation中可以执行异步任务，那么就重写 start 方法 (本类就是这样,没有重写main方法)：
                    这种情况下，你必须手动管理operation的状态 (本类通过 state 属性值间接管理)
                    为了让操作队列能够捕获到操作的改变，需要将状态的属性以配合 KVO 的方式进行实现 (本类在改变 state 属性值时发出通知)
                    若果你不是使用operation状态默认的setter来设置它们的话，你需要在合适的时候发送合适的 KVO 消息。
                        (犹如本类,就是通过改变本类的state属性,来间接改变isFinished等返回值,并发出通知)
 
            o 你可以通过 maxConcurrentOperationCount 属性来控制一个特定队列中可以有多少个 operation 参与并发执行 (看 NetworkManager 类的 ini 方法,就是设置了此值)
 
 
         ► 1) Concurrent Versus Non-Concurrent Operations 并发 与 非并发
         如果你计划手工执行一个 Operation 对象(手工调用Operation 对象的 start 方法) ,而不是把它添加到一个 queue ,那么你可以设计你的 Operation 以并发的方式 或者 非并发的方式执行.
         Operation 对象默认是 非并发的.
         在非并发operation中, Operation的任务是同步执行的. 即, operation对象不创建另一个独立的线程去执行那个任务.
         这样, 当你在代码中调用一个非并发 Operation 的 start 方法时,这个 Operation 立即在你当前的线程里执行. 当这个 start 方法 reuturn 的时候, 这个任务就被执行完了.
         跟同步运行的非并发 Operation 相比, 并发 Operation 是异步的运行.换句话说,当您调用一个并发 Operation 的 start 方法时, 这个方法可能立即就 return,  即使对应的任务没有完成.这种可能发生在这种情况下,
         (1) 当 Operation 对象创建了一个新的线程去执行对应的任务.
         (2) 这个 Operation 对象调用了一个异步函数.
         
         
         定义一个并发 operation 需要做更多的工作,因为,你不得不监控你任务的运行状态, 并用 KVO 通知的方式报告状态的改变.
         但是,当你想确保手工执行的 Operation 不堵塞运行线程的话,那么定义并发 Operation 还是很有用的.
         
         ► 2) 如果你定义一个 operation 为并发的形式的话. 你必须重写:
         - (BOOL) isConcurrent 方法,并返回 YES.
         - (void) start  方法, 并用它去初始化你的操作. 并且,你重写的 start 方法不能调用 [super start]
         此时,你若不是自己手工掉用 - (void)start 方法执行这个 Operation 的话, 你不必重写 - (void)main 方法.
         - (BOOL) isFinished
         - (BOOL) isExecuting
 

    总结:
        本类是在 start 方法内调用执行异步方法,并发 Operation
        本类不用手工调用 start 方法, 最终会被 NetworkManageer 调用以下方法
            - (void)addOperation:(NSOperation *)operation toQueue:(NSOperationQueue *)queue finishedTarget:(id)target action:(SEL)action
        添加到 NetworkManageer 对应的 队列属性里. 目前有三个队列属性:  
            [1] queueForNetworkTransfers 
            [2] queueForNetworkManagement 
            [3] queueForCPU
 
        添加到 NSOperationQueue 里的 operation 会使用 GCD 执行(iOS 4 和以后, operation queues 用 GCD 执行 operation).
        operation 执行完毕以后, 会在执行本类实例对象入 Queue 时操作的 thread 上向当时指定好的 target 上发送当时指定好的 seletor.
 
        例如,我们在main thread上执行get http 请求,添加一个 RetringHTTPOperatin(继承自本类) 对象,
        到 NetworkManger 类里的 queueForNetworkManagement (网络管理)队列中,
        并指定好了回执 target 的 selecter ,当做此operation完成后的回调函数.
        那么 NetworkManger 会记录当时执行这个入列操作的 thread(本例为main thread),
        并当operation在queueForNetworkManagement中执行完成以后,
        在此thread(本例为main thread)上向target发送selecter方法.
        具体的实例可以查看 RetryingHTTPOperation.m 的 - (void)startGetOperation 方法里的代码.
 
        这种逻辑是可以嵌套的,比如,在 RetringHTTPOperatin 中在向 Networkmanger 的 queueForNetworkTransfers(网络传输队列) 入列一个 QHTTPOperation(同样继承自本类) 操作,
        并等待QHTTPOperation完成以后, 在执行 RetringHTTPOperatin 的 Networkmanger 的 queueForNetworkManagement(网络管理队列) 中执行一个回调函数.
 
        继承自本类的类有:
            QHTTPOperation
            QReachabilityOperation
            RetryingHTTPOperation
 
*/


@interface QRunLoopOperation ()

// read/write versions of public properties
@property (assign, readwrite) QRunLoopOperationState    state;
@property (copy,   readwrite) NSError *                 error;          

@end


@implementation QRunLoopOperation

- (id)init
{
    self = [super init];
    if (self != nil) {
        // 确保初始化状态值
        assert(self->_state == kQRunLoopOperationStateInited);
    }
    return self;
}

- (void)dealloc
{
    assert(self->_state != kQRunLoopOperationStateExecuting);
    [self->_runLoopModes release];
    [self->_runLoopThread release];
    [self->_error release];
    [super dealloc];
}

#pragma mark - Properties

@synthesize runLoopThread = _runLoopThread;
@synthesize runLoopModes  = _runLoopModes;
@synthesize error         = _error;

// 返回运行本 operation 的 runloop 线程, 返回值要么是用户设置 self.runLoopThread 的值,要么是 main 线程
- (NSThread *)actualRunLoopThread
// Returns the effective run loop thread, that is, the one set by the user
// or, if that's not set, the main thread.
{
    NSThread *  result;
    
    result = self.runLoopThread;
    if (result == nil) {
        result = [NSThread mainThread];
    }
    return result;
}


// 当前实际运行的线程是否等于 self.actualRunLoopThread
- (BOOL)isActualRunLoopThread
    // Returns YES if the current thread is the actual run loop thread.
{
    return [[NSThread currentThread] isEqual:self.actualRunLoopThread];
}

/*
 一个 run loop mode 是包含可以被监控的 input sources 和 timers 的集合,也是一个包含可以被通知的 run loop observers 集合.
 每次你运行你的 run loop , 你就(明确的,或隐式的)指定了一个特别的 " mode "去运行. 
 在处理 run loop 时,只有那些和指定的 "mode" 相符的 sources 才可以提交他们的事件. 
 (同样,在 run loop 处理事件时,只有那些和指定的"mode"相符的 obserers 才会被通知到).
 
 NSRunLoop defines the following run loop mode.
    extern NSString* const NSDefaultRunLoopMode;
    extern NSString* const NSRunLoopCommonModes;
 
 Additional run loop modes are defined by NSConnection and NSApplication.
    NSConnectionReplyMode
    NSModalPanelRunLoopMode
    NSEventTrackingRunLoopMode
 
*/

- (NSSet *)actualRunLoopModes
{
    NSSet * result;
    result = self.runLoopModes;
    if ( (result == nil) || ([result count] == 0) ) {
        result = [NSSet setWithObject:NSDefaultRunLoopMode];
    }
    return result;
}

#pragma mark - Core state transitions

- (QRunLoopOperationState)state
{
    return self->_state;
}

// 手动改变 operation 的 state 值(isExecuting,isFinished), 并发送 KVO 通知
// Change the state of the operation, sending the appropriate KVO notifications.
- (void)setState:(QRunLoopOperationState)newState
{
    // any thread
    @synchronized (self) {
        // The following check is really important.  The state can only go forward, and there 
        // should be no redundant changes to the state (that is, newState must never be 
        // equal to self->_state).
        // 状态值只能够增加,不能减少
        assert(newState > self->_state);

        // Transitions from executing to finished must be done on the run loop thread.
        // 改变执行状态从 executing 到 finished 必须在 actualRunLoopThread 上完成
        assert( (newState != kQRunLoopOperationStateFinished) || self.isActualRunLoopThread );

        // inited    + executing -> isExecuting
        // inited    + finished  -> isFinished
        // executing + finished  -> isExecuting + isFinished
        QRunLoopOperationState oldState = self->_state;
        if ( (newState == kQRunLoopOperationStateExecuting) || (oldState == kQRunLoopOperationStateExecuting) ) {
            [self willChangeValueForKey:@"isExecuting"];
        }
        if (newState == kQRunLoopOperationStateFinished) {
            [self willChangeValueForKey:@"isFinished"];
        }
        self->_state = newState;
        
        if (newState == kQRunLoopOperationStateFinished) {
            [self didChangeValueForKey:@"isFinished"];
        }
        
        if ( (newState == kQRunLoopOperationStateExecuting) || (oldState == kQRunLoopOperationStateExecuting) ) {
            [self didChangeValueForKey:@"isExecuting"];
        }
        
    }
}

#pragma mark - 被 start 调用,  在 runLoopThread 上运行的代码

// Starts the operation.  The actual -start method is very simple,
// deferring all of the work to be done on the run loop thread by this method.
- (void)startOnRunLoopThread
{
    // 确保是在 ActualRunLoopThread 中执行,而不是调用 start 的线程中执行
    assert(self.isActualRunLoopThread);
    assert(self.state == kQRunLoopOperationStateExecuting);

    // 测试是否取消了操作
    if ([self isCancelled]) {
        // We were cancelled before we even got running.
        // Flip the the finished state immediately.
        [self finishWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
    } else {
        [self operationDidStart];
    }
}


- (void)cancelOnRunLoopThread
    // Cancels the operation.
{
    // 确保是在 ActualRunLoopThread 中执行,而不是调用 start 的线程中执行
    assert(self.isActualRunLoopThread);

    /*
     We know that
        a) state was kQRunLoopOperationStateExecuting when we were scheduled (that's enforced by -cancel)
        b) the state can't go backwards (that's enforced by -setState), 
     
     so we know the state must either be kQRunLoopOperationStateExecuting or kQRunLoopOperationStateFinished.
     
     We also know that the transition from executing to finished always happens on the run loop thread.
     Thus, we don't need to lock here. We can look at state and, if we're executing, trigger a cancellation.
    */
    
    if (self.state == kQRunLoopOperationStateExecuting) {
        [self finishWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
    }
}

- (void)finishWithError:(NSError *)error
{
    // 确保是在 ActualRunLoopThread 中执行,而不是调用 start 的线程中执行
    assert(self.isActualRunLoopThread);
    // error may be nil

    if (self.error == nil) {
        self.error = error;
    }
    [self operationWillFinish];   //即使有错误也调用 operationWillFinish 方法
    self.state = kQRunLoopOperationStateFinished;
}


#pragma mark - Subclass override points 子类需要重写的方法

- (void)operationDidStart
{
    // 确保是在 ActualRunLoopThread 中执行,而不是调用 start 的线程中执行
    assert(self.isActualRunLoopThread);
}

- (void)operationWillFinish
{
    // 确保是在 ActualRunLoopThread 中执行,而不是调用 start 的线程中执行
    assert(self.isActualRunLoopThread);
}


#pragma mark - Overrides 重写NSOperation的方法

- (BOOL)isConcurrent
{
    // any thread
    return YES;
}

- (BOOL)isExecuting
{
    // any thread
    return self.state == kQRunLoopOperationStateExecuting;
}
 
- (BOOL)isFinished
{
    // any thread
    return self.state == kQRunLoopOperationStateFinished;
}

- (void)start
{
    // any thread 任何线程都可能执行这个操作
    assert(self.state == kQRunLoopOperationStateInited);
    /*
       We have to change the state here, otherwise isExecuting won't necessarily return true by the time we return from -start.
       Also, we don't test for cancellation here because that would 
            a) result in us sending isFinished notifications on a thread that isn't our run loop thread
            b) confuse the core cancellation code, which expects to run on our run loop thread.  
     
     Finally, we don't have to worry about races with other threads calling -start.  
            Only one thread is allowed to start us at a time.
     
      我们必须在这里改变 self.state 的值,否则在 return 之前 isExecuting 不一定会返回 true
      同样,  我们不必在这里测试是否需要 cancellation ,因为那样将会
            a) 导致我们在一个不是 run loop thread 的线程上发送 isFinished 通知
            b) 使期望运行在我们 run loop thread 线程上的核心 cancellation 代码看起来困惑.
      
        最后, 我们不必担心跟其他线程竞争调用 -start 方法的竞争关系, 因为在同一时间只允许一个线程开始操作.
     
     leo:
        这里是重写父类的该方法,因为我们是 concurrent 操作, 所以这里永远不要调用[ super start ]方法
        如果,一个 operatin 已经入列 queue 的话,就不能再手工调用这个方法. 这个方法只能被调用一次.
    */
    
    self.state = kQRunLoopOperationStateExecuting;//这里会发出 KVO 通知
    //这之前的操作都是在主线程上执行的,下面的操作,有可能在主线程,也有可能是在 NetworkManger 类的 networkRunLoopThread 线程上执行,关键要看本类有没有设置runLoopThread
    [self performSelector:@selector(startOnRunLoopThread)
                 onThread:self.actualRunLoopThread      // 或者为 main's thread run loop ,或者 自定义的
               withObject:nil
            waitUntilDone:NO                            //异步
                    modes:[self.actualRunLoopModes allObjects]];
    // modes 是用来过滤不感兴趣或者优先级低的消息的,只有模式相等, run loop 才会处理事件,调用响应的 handle
}


- (void)cancel
{
    BOOL    runCancelOnRunLoopThread;
    BOOL    oldValue;

    // any thread 任何线程都可能执行这个操作
    // We need to synchronise here to avoid state changes to isCancelled and state while we're running.
    // 我们需要在这里 synchronise, 去避免cancel掉我们正在运行的状态已经是 cancel 的情况.
    // 因为任何线程都可以执行这个方法 cancel 掉一个 operation, 而我们要 cacel 运行在 self.actualRunLoopThread
    
    
    //输给 @synchronized 指令的对象是作为"区分"受保护代码块的唯一标识符
    //如果你传入同一个对象, 其中一个线程将首先获取到锁,另一个将被堵塞,直到第一个线程完成这个 关键区段(critical section).
    @synchronized (self) {
        oldValue = [self isCancelled]; // 到这里状态应该还不是 isCancelled, 所以第一次执行这里为 False,第二个获得锁的线程执行的话,应该就为 TRUE
        
        // Call our super class so that isCancelled starts returning true immediately.
        [super cancel];
        
        // If we were the one to set isCancelled (that is, we won the race with regards 
        // other threads calling -cancel) and we're actually running (that is, we lost 
        // the race with other threads calling -start and the run loop thread finishing), 
        // we schedule to run on the run loop thread.
        
        // 如果oldValue 值为 False (那代表着,我们赢了跟其他线程调用 -cancel 的权利)
        // 并且 self.state != kQRunLoopOperationStateExecuting (那代表这,我们输了跟其他线程调用 -start 的竞争或者这个 run loop 线程已经完成了).
        runCancelOnRunLoopThread = ! oldValue && self.state == kQRunLoopOperationStateExecuting;
    }
    
    if (runCancelOnRunLoopThread) {
        [self performSelector:@selector(cancelOnRunLoopThread)
                     onThread:self.actualRunLoopThread
                   withObject:nil
                waitUntilDone:YES
                        modes:[self.actualRunLoopModes allObjects]];
    }
    
}

@end
