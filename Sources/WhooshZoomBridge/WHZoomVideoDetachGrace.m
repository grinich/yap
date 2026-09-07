#import "WHZoomVideoDetachGrace.h"

@interface WHZoomVideoDetachGrace ()
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSUUID *> *tokens;
@end

@implementation WHZoomVideoDetachGrace
- (instancetype)init {
    if ((self = [super init])) _tokens = [NSMutableDictionary dictionary];
    return self;
}
- (BOOL)scheduleIdentifier:(NSString *)identifier action:(dispatch_block_t)action {
    NSAssert(NSThread.isMainThread, @"Renderer grace must run on the main thread");
    if (self.tokens[identifier]) return NO;
    NSUUID *token = NSUUID.UUID;
    self.tokens[identifier] = token;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || ![self.tokens[identifier] isEqual:token]) return;
        [self.tokens removeObjectForKey:identifier];
        action();
    });
    return YES;
}
- (BOOL)cancelIdentifier:(NSString *)identifier {
    NSAssert(NSThread.isMainThread, @"Renderer grace must run on the main thread");
    BOOL pending = self.tokens[identifier] != nil;
    [self.tokens removeObjectForKey:identifier];
    return pending;
}
- (BOOL)hasPendingIdentifier:(NSString *)identifier { return self.tokens[identifier] != nil; }
- (void)detachImmediately:(NSString *)identifier action:(dispatch_block_t)action {
    [self cancelIdentifier:identifier];
    action();
}
@end
