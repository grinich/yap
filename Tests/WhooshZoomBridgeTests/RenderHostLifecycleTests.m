#import "WHZoomRenderHost.h"

// Simulate only window visibility; AppKit still computes real ancestor clipping.
// No window is opened and the meeting SDK is not linked into this executable.
@interface WHRenderHostFixture : WHZoomRenderHost
@property(nonatomic) BOOL simulatedWindowVisible;
@end
@implementation WHRenderHostFixture
- (BOOL)isRendererWindowVisible { return self.simulatedWindowVisible; }
@end

// Supply window facts without creating an NSWindow or contacting the desktop.
// Unlike the geometry fixture above, this calls the production window predicate.
@interface WHWindowFacts : NSObject
@property(nonatomic, getter=isVisible) BOOL visible;
@property(nonatomic, getter=isMiniaturized) BOOL miniaturized;
@property(nonatomic) NSWindowOcclusionState occlusionState;
@end
@implementation WHWindowFacts
@end

@interface WHWindowReadinessFixture : WHZoomRenderHost
@property(nonatomic, strong) WHWindowFacts *windowFacts;
@end
@implementation WHWindowReadinessFixture
- (NSWindow *)window { return (NSWindow *)self.windowFacts; }
@end

static void DrainMainQueue(void) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
}
static void Check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
static void CheckOcclusionDoesNotSuspendUsableVideo(void) {
    WHWindowReadinessFixture *host = [[WHWindowReadinessFixture alloc] initWithFrame:NSMakeRect(0, 0, 540, 304)];
    WHWindowFacts *facts = [WHWindowFacts new];
    host.windowFacts = facts;
    facts.visible = YES;
    __block BOOL ready = NO;
    __block NSUInteger activations = 0;
    __block NSUInteger deactivations = 0;
    host.reconcileRenderer = ^(BOOL value) {
        if (value && !ready) activations++;
        if (!value && ready) deactivations++;
        ready = value;
    };
    [host scheduleRendererUpdate]; DrainMainQueue();
    Check(ready && activations == 1, @"visible, nonminimized video activates even when occlusion reports no visible bit");
    facts.occlusionState = NSWindowOcclusionStateVisible;
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidChangeOcclusionStateNotification object:facts];
    DrainMainQueue();
    facts.occlusionState = 0;
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidChangeOcclusionStateNotification object:facts];
    DrainMainQueue();
    Check(ready && activations == 1 && deactivations == 0, @"occlusion changes cannot churn an otherwise usable subscription");
    facts.miniaturized = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidMiniaturizeNotification object:facts];
    DrainMainQueue();
    Check(!ready && deactivations == 1, @"minimization still suspends video despite a visible window flag");
    facts.miniaturized = NO;
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidDeminiaturizeNotification object:facts];
    DrainMainQueue();
    Check(ready && activations == 2, @"restoration resumes video without requiring an occlusion-visible bit");
    facts.visible = NO;
    [host scheduleRendererUpdate]; DrainMainQueue();
    Check(!ready && deactivations == 2, @"an unordered window still suspends video");
    host.reconcileRenderer = nil;
    host.windowFacts = nil;
    [host scheduleRendererUpdate]; DrainMainQueue();
}
static void CheckLifecycleAndGeometry(void) {
        WHRenderHostFixture *host = [[WHRenderHostFixture alloc] initWithFrame:NSMakeRect(0, 0, 320, 180)];
        __block NSUInteger resizes = 0;
        __block NSUInteger subscriptions = 0;
        __block NSUInteger unsubscriptions = 0;
        __block BOOL ready = NO;
        __block NSSize renderedSize = NSZeroSize;
        host.resizeRenderer = ^(NSRect rect) {
            Check(rect.size.width > 0 && rect.size.height > 0, @"SDK must never receive zero geometry");
            resizes++;
            renderedSize = rect.size;
        };
        host.reconcileRenderer = ^(BOOL value) {
            if (value && !ready) subscriptions++;
            if (!value && ready) unsubscriptions++;
            ready = value;
        };
        [host scheduleRendererUpdate]; DrainMainQueue();
        Check(!ready && resizes == 0, @"unattached view cannot subscribe or resize");
        host.simulatedWindowVisible = YES;
        host.frame = NSZeroRect;
        [host viewDidMoveToWindow]; DrainMainQueue();
        Check(!ready && resizes == 0, @"attached zero-sized view remains inactive");
        host.frame = NSMakeRect(0, 0, 500, 281); DrainMainQueue();
        Check(ready && resizes == 1, @"nonzero attachment activates and resizes");
        [host layout]; [host layout]; DrainMainQueue();
        Check(resizes == 1, @"unchanged layout must not restart SDK geometry repeatedly");
        host.simulatedWindowVisible = NO; [host viewDidMoveToWindow]; DrainMainQueue();
        Check(!ready, @"detachment suspends video subscription");
        host.simulatedWindowVisible = YES; [host viewDidMoveToWindow]; DrainMainQueue();
        Check(ready && resizes == 1, @"same-geometry window reattachment resumes without repeating SDK resize");
        host.hidden = YES; DrainMainQueue(); Check(!ready, @"hidden view is inactive");
        host.hidden = NO; DrainMainQueue(); Check(ready, @"unhidden view activates again");
        Check(resizes == 1, @"visibility alone does not invalidate the renderer's logical geometry");

        NSUInteger activeSubscriptions = subscriptions;
        NSUInteger inactiveSubscriptions = unsubscriptions;
        for (NSValue *value in @[[NSValue valueWithSize:NSMakeSize(160, 90)],
                                 [NSValue valueWithSize:NSMakeSize(1280, 720)],
                                 [NSValue valueWithSize:NSMakeSize(640, 360)],
                                 [NSValue valueWithSize:NSMakeSize(160, 90)]]) {
            NSUInteger previousResizes = resizes;
            host.frame = (NSRect){NSZeroPoint, value.sizeValue}; DrainMainQueue();
            Check(NSEqualSizes(renderedSize, value.sizeValue), @"reused tile forwards its current gallery/focus geometry");
            Check(resizes == previousResizes + 1, @"each gallery/focus size change resizes exactly once");
            [host layout]; [host layout]; DrainMainQueue();
            Check(resizes == previousResizes + 1, @"stable focus layout does not repeat resize");
        }
        Check(subscriptions == activeSubscriptions && unsubscriptions == inactiveSubscriptions,
              @"gallery/focus geometry changes do not restart an active subscription");
        NSUInteger beforeVisibilityChange = resizes;
        host.simulatedWindowVisible = NO; [host scheduleRendererUpdate]; DrainMainQueue();
        Check(!ready, @"an unordered or minimized window suspends video");
        host.simulatedWindowVisible = YES; [host scheduleRendererUpdate]; DrainMainQueue();
        Check(ready, @"restoring window visibility resumes video");
        Check(resizes == beforeVisibilityChange, @"restoring unchanged geometry does not repeat SDK resize");

        host.simulatedWindowVisible = NO; [host scheduleRendererUpdate]; DrainMainQueue();
        host.frame = NSMakeRect(0, 0, 800, 450); DrainMainQueue();
        Check(resizes == beforeVisibilityChange, @"hidden size changes are deferred until usable attachment");
        host.simulatedWindowVisible = YES; [host viewDidMoveToWindow]; DrainMainQueue();
        Check(ready && resizes == beforeVisibilityChange + 1 && NSEqualSizes(renderedSize, NSMakeSize(800, 450)),
              @"a real geometry change while hidden is delivered once on return");

        NSUInteger beforeRoundingResidue = resizes;
        NSRect logicalBounds = host.bounds;
        host.bounds = NSMakeRect(logicalBounds.origin.x + 1e-10, logicalBounds.origin.y - 1e-10,
                                 logicalBounds.size.width + 1e-10, logicalBounds.size.height + 1e-10);
        DrainMainQueue();
        Check(resizes == beforeRoundingResidue, @"AppKit scaling residue in origin and size must not repeat SDK resize");
        host.bounds = logicalBounds; DrainMainQueue();
        Check(resizes == beforeRoundingResidue, @"returning from rounded bounds also preserves the cached geometry");
        host.bounds = NSOffsetRect(logicalBounds, 0.01, 0.01); DrainMainQueue();
        Check(resizes == beforeRoundingResidue + 1, @"real origin changes beyond the tolerance still reach the SDK");

        __block NSUInteger replacementResizes = 0;
        host.resizeRenderer = ^(NSRect rect) {
            replacementResizes++;
            Check(NSEqualSizes(rect.size, NSMakeSize(800, 450)), @"replacement renderer receives current logical geometry");
        };
        DrainMainQueue();
        Check(replacementResizes == 1, @"replacing the renderer invalidates cached geometry even at the same size");
        [host layout]; DrainMainQueue();
        Check(replacementResizes == 1, @"replacement renderer also coalesces unchanged layout");
        host.resizeRenderer = nil; host.reconcileRenderer = nil;
        [host scheduleRendererUpdate]; DrainMainQueue();
}

static void CheckClippingAndScrollCoalescing(void) {
    __weak WHRenderHostFixture *releasedHost = nil;
    @autoreleasepool {
    NSView *viewport = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 120)];
    viewport.clipsToBounds = YES;
    NSView *document = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 120)];
    [viewport addSubview:document];
    WHRenderHostFixture *host = [[WHRenderHostFixture alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    host.simulatedWindowVisible = YES;
    [document addSubview:host];
    __block BOOL ready = NO;
    __block NSUInteger subscriptions = 0;
    __block NSUInteger unsubscriptions = 0;
    __block NSUInteger resizes = 0;
    host.resizeRenderer = ^(NSRect rect) { resizes++; };
    host.reconcileRenderer = ^(BOOL value) {
        if (value && !ready) subscriptions++;
        if (!value && ready) unsubscriptions++;
        ready = value;
    };
    DrainMainQueue();
    Check(ready && subscriptions == 1, @"visible initial attachment activates after its first layout turn");

    viewport.bounds = NSMakeRect(250, 0, 200, 120); DrainMainQueue();
    Check(!ready && unsubscriptions == 1, @"ancestor scrolling alone suspends a completely clipped tile");
    viewport.bounds = NSMakeRect(251, 0, 200, 120);
    viewport.bounds = NSMakeRect(252, 0, 200, 120); DrainMainQueue();
    Check(unsubscriptions == 1, @"additional offscreen scroll updates do not repeatedly unsubscribe");
    viewport.bounds = NSMakeRect(50, 0, 200, 120); DrainMainQueue();
    Check(ready && subscriptions == 2 && resizes == 1, @"partially visible tile resumes without changing its logical geometry");

    NSUInteger initialSubscriptions = subscriptions;
    NSUInteger initialUnsubscriptions = unsubscriptions;
    NSUInteger initialResizes = resizes;
    viewport.bounds = NSMakeRect(300, 0, 200, 120);
    viewport.bounds = NSMakeRect(0, 0, 200, 120);
    [host layout]; [host layout]; DrainMainQueue();
    Check(ready && subscriptions == initialSubscriptions && unsubscriptions == initialUnsubscriptions && resizes == initialResizes,
          @"transient clipping within one layout turn causes no subscription or geometry churn");

    document.frame = NSMakeRect(-300, 0, 600, 120); DrainMainQueue();
    Check(!ready, @"ancestor frame movement also suspends an offscreen tile");
    document.frame = NSMakeRect(0, 0, 600, 120); DrainMainQueue();
    Check(ready, @"ancestor frame restoration resumes the visible tile");
    document.hidden = YES; DrainMainQueue();
    Check(!ready, @"ancestor hide callbacks suspend the tile");
    document.hidden = NO; DrainMainQueue();
    Check(ready, @"ancestor unhide callbacks restore the tile");

    [host removeFromSuperview];
    NSView *replacement = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 120)];
    replacement.clipsToBounds = YES;
    [replacement addSubview:host]; DrainMainQueue();
    viewport.bounds = NSMakeRect(300, 0, 200, 120); DrainMainQueue();
    Check(ready, @"the old scrolling hierarchy cannot hide a reparented tile");
    replacement.bounds = NSMakeRect(300, 0, 200, 120); DrainMainQueue();
    Check(!ready, @"reparented tile observes its new clipping ancestors");
    host.resizeRenderer = nil; host.reconcileRenderer = nil;
    [host removeFromSuperview];
    releasedHost = host;
    host = nil;
    }
    DrainMainQueue();
    Check(releasedHost == nil, @"visibility observers and queued updates do not retain a discarded tile");
}

int main(void) {
    @autoreleasepool {
        CheckOcclusionDoesNotSuspendUsableVideo();
        CheckLifecycleAndGeometry();
        CheckClippingAndScrollCoalescing();
        puts("PASS: occlusion-independent window readiness, native render-host lifecycle, gallery/focus geometry, actual ancestor clipping, scroll coalescing, reparenting, and teardown");
    }
    return 0;
}
