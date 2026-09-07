#import <Foundation/Foundation.h>

/// Main-thread, non-sliding grace for a native renderer changing containers.
/// The caller must revalidate its session and element in the deferred action.
@interface WHZoomVideoDetachGrace : NSObject
- (BOOL)scheduleIdentifier:(NSString *)identifier action:(dispatch_block_t)action;
- (BOOL)cancelIdentifier:(NSString *)identifier;
- (BOOL)hasPendingIdentifier:(NSString *)identifier;
- (void)detachImmediately:(NSString *)identifier action:(dispatch_block_t)action;
@end
