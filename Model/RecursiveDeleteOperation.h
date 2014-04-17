#import <Foundation/Foundation.h>

// 递归删除操作, NSOperatino 的子类
@interface RecursiveDeleteOperation : NSOperation
{
    NSArray *   _paths;
    NSError *   _error;
}

// 初始化方法, 通过一个数组初始化
// Configures the operation with the array of paths to delete.
- (id)initWithPaths:(NSArray *)paths;

// properties specified at init time
@property (copy,   readonly ) NSArray *     paths;

// properties that are valid after the operation is finished
@property (copy,   readonly ) NSError *     error;

@end
