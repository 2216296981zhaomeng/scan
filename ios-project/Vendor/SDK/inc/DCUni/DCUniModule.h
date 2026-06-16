#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "DCUniDefine.h"

@class DCUniSDKInstance;

NS_ASSUME_NONNULL_BEGIN

@interface DCUniModule : NSObject

@property (nonatomic, strong) dispatch_queue_t uniExecuteQueue;
@property (nonatomic, strong) NSThread *uniExecuteThread;
@property (nonatomic, weak) DCUniSDKInstance *uniInstance;

@end

@interface DCUniSDKInstance : NSObject

@property (nonatomic, weak) UIViewController *viewController;
@property (nonatomic, strong) UIView *rootView;

@end

NS_ASSUME_NONNULL_END
