#import <Foundation/Foundation.h>

// RunLoop 操作状态码
/*
enum QRunLoopOperationState {
    kQRunLoopOperationStateInited, 
    kQRunLoopOperationStateExecuting, 
    kQRunLoopOperationStateFinished
};
typedef enum QRunLoopOperationState QRunLoopOperationState;
*/
typedef NS_ENUM(NSUInteger, QRunLoopOperationState){
    kQRunLoopOperationStateInited,
    kQRunLoopOperationStateExecuting,
    kQRunLoopOperationStateFinished
};


@interface QRunLoopOperation : NSOperation
{
    QRunLoopOperationState  _state;
    NSThread *              _runLoopThread;
    NSSet *                 _runLoopModes;
    NSError *               _error;
}

//注意这些 property 都是线程安全的 atomic



// Things you can configure before queuing the operation.
// 你能在 queueing the operation之前,配置这些属性.
// IMPORTANT: Do not change these after queuing the operation; it's very likely that bad things will happen if you do.
@property (retain, readwrite) NSThread *                runLoopThread;          // default is nil, implying main thread
@property (copy,   readwrite) NSSet *                   runLoopModes;           // default is nil, implying set containing NSDefaultRunLoopMode


// Things that are only meaningful after the operation is finished.
// 这些只有在 operation 完成以后才有意义
@property (copy,   readonly ) NSError *                 error;

// Things you can only alter implicitly.
// 这些属性的值只在暗中跟随执行状态改变而改变,不能手工更改
@property (assign, readonly ) QRunLoopOperationState    state;
// 这两个属性只有 get 方法,没有 set 方法
@property (retain, readonly ) NSThread *                actualRunLoopThread;    // main thread if runLoopThread is nil, runLoopThread otherwise
@property (assign, readonly ) BOOL                      isActualRunLoopThread;  // YES if the current thread is the actual run loop thread

// set containing NSDefaultRunLoopMode if runLoopModes is nil or empty, runLoopModes otherwise
// 当 runLoopModes 属性是 nil 或空的时候,此NSSet属性包含 NSDefaultRunLoopMode,或者就是包含 runLoopModes 的NSSet.
@property (copy,   readonly ) NSSet *                   actualRunLoopModes;

@end


#pragma mark - QRunLoopOperation  Categories ,子类需要重写,调用的三个方法
@interface QRunLoopOperation (SubClassSupport)

// Override points
// A subclass will probably need to override -operationDidStart and -operationWillFinish
// to set up and tear down its run loop sources, respectively.
// These are always called on the actual run loop thread.
//
// Note that -operationWillFinish will be called even if the operation is cancelled.
//
// -operationWillFinish can check the error property to see whether the operation was successful.
// error will be NSCocoaErrorDomain/NSUserCancelledError on cancellation.
//
// -operationDidStart is allowed to call -finishWithError:

// 这些方法总是在 actualRunLoopThread 线程上被调用
// 注意, 即使 operatin 被取消, -operationWillFinish 也将被调用
// -operationWillFinish 能够检查 "错误属性" ,从而查看是否操作成功完成.
// 如果操作取消的户,错误将是  NSCocoaErrorDomain/NSUserCancelledError
// -operationDidStart 是被允许调用 -finishWithError: 方法(即,刚一开始请求,就将其取消掉)

- (void)operationDidStart;
- (void)operationWillFinish;


// Support methods
// A subclass should call finishWithError: when the operation is complete, passing nil for no error and an error otherwise.
// It must call this on the actual run loop thread.
// 一个子类应该在  operation 完成时调用 finishWithError: 方法, 如果没有错误的话,传入 nil, 或者传入错误值
// 它必须在 actualRunLoopThread 线程上调用这个方法,而不是调用 start 方法的线程.
//
// Note that this will call -operationWillFinish before returning
// 注意本方法在 returning 之前 将调用 -operationWillFinish 方法

- (void)finishWithError:(NSError *)error;

@end
