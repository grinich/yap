#import "WHZoomRenderHost.h"

// Run only when a brief test window is safe. This executable links AppKit, not
// Zoom; it never connects to a meeting, reads credentials, or controls Yap.
static NSWindow *fixtureWindow;

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        [fixtureWindow orderOut:nil];
        [fixtureWindow close];
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static BOOL WaitFor(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                          untilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]
                                             inMode:NSDefaultRunLoopMode dequeue:YES];
        if (event) [NSApp sendEvent:event];
        [NSApp updateWindows];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return condition();
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        NSRect screen = NSScreen.mainScreen.visibleFrame;
        fixtureWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(NSMinX(screen) + 24, NSMaxY(screen) - 190, 240, 140)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered defer:YES];
        fixtureWindow.releasedWhenClosed = NO;
        fixtureWindow.title = @"Yap video visibility test";
        fixtureWindow.animationBehavior = NSWindowAnimationBehaviorNone;
        WHZoomRenderHost *host = [[WHZoomRenderHost alloc] initWithFrame:NSZeroRect];
        [fixtureWindow.contentView addSubview:host];
        __block BOOL ready = NO;
        __block NSUInteger resizes = 0;
        __block NSUInteger subscriptions = 0;
        __block NSUInteger unsubscriptions = 0;
        host.resizeRenderer = ^(NSRect rect) {
            Check(rect.size.width >= 1 && rect.size.height >= 1, @"real window never forwards empty geometry");
            resizes++;
        };
        host.reconcileRenderer = ^(BOOL value) {
            if (value && !ready) subscriptions++;
            if (!value && ready) unsubscriptions++;
            ready = value;
        };
        Check(host.window == fixtureWindow && !fixtureWindow.visible && !host.isReadyForRenderer,
              @"attachment to an unordered native window remains inactive");
        [fixtureWindow orderFrontRegardless];
        Check(WaitFor(^BOOL { return fixtureWindow.visible; }),
              @"native window becomes ordered and visible");
        Check(!host.isReadyForRenderer && resizes == 0, @"visible native window still rejects initial zero geometry");

        host.frame = NSMakeRect(12, 12, 216, 116);
        Check(WaitFor(^BOOL { return ready; }), @"first real nonzero layout activates the native render host");
        Check(resizes == 1 && subscriptions == 1, @"initial native attachment resizes and activates exactly once");
        [fixtureWindow miniaturize:nil];
        Check(WaitFor(^BOOL { return fixtureWindow.miniaturized && !ready; }), @"native minimization notification suspends rendering");
        Check(unsubscriptions == 1, @"minimization unsubscribes once");

        [fixtureWindow deminiaturize:nil];
        [fixtureWindow orderFrontRegardless];
        Check(WaitFor(^BOOL { return !fixtureWindow.miniaturized && ready; }), @"native restore notification resumes rendering");
        Check(resizes == 1 && subscriptions == 2, @"restoration resumes once without reapplying unchanged geometry");
        [fixtureWindow orderOut:nil];
        Check(WaitFor(^BOOL { return !fixtureWindow.visible && !ready; }), @"native order-out suspends rendering");
        [fixtureWindow orderFrontRegardless];
        Check(WaitFor(^BOOL { return ready; }), @"native order-front restores rendering");
        Check(resizes == 1 && subscriptions == 3 && unsubscriptions == 2,
              @"visibility notifications do not duplicate rendering transitions");
        host.resizeRenderer = nil; host.reconcileRenderer = nil;
        [fixtureWindow orderOut:nil];
        [fixtureWindow close];
        fixtureWindow = nil;
        puts("PASS: actual native window initial attachment, first layout, minimization, restoration, and order-out/front transitions");
    }
    return 0;
}
