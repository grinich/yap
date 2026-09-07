#import <Foundation/Foundation.h>
#import "WHZoomVideoDetachGrace.h"

static void PumpFor(NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
}
static void Require(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "FAIL %s\n", message); exit(1); }
}

int main(void) {
    @autoreleasepool {
        __block NSUInteger calls = 0;
        WHZoomVideoDetachGrace *grace = [WHZoomVideoDetachGrace new];
        Require([grace scheduleIdentifier:@"reattached" action:^{ calls++; }], "initial detach scheduled");
        PumpFor(0.06);
        Require([grace cancelIdentifier:@"reattached"], "reattachment cancels pending detach");
        PumpFor(0.22);
        Require(calls == 0 && ![grace hasPendingIdentifier:@"reattached"], "reattachment retains the live subscription");

        NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
        __block NSTimeInterval firedAt = 0;
        [grace scheduleIdentifier:@"hidden" action:^{ calls++; firedAt = NSProcessInfo.processInfo.systemUptime; }];
        PumpFor(0.12);
        Require(![grace scheduleIdentifier:@"hidden" action:^{ calls += 100; }], "repeated hidden layouts do not extend the deadline");
        PumpFor(0.15);
        Require(calls == 1 && firedAt > 0 && firedAt - start < 0.29, "genuinely hidden renderer detaches at the original 200ms deadline");

        __block NSUInteger staleDetach = 0;
        __block NSUInteger immediateCleanup = 0;
        __block NSUInteger replacementDetach = 0;
        [grace scheduleIdentifier:@"removed-participant" action:^{ staleDetach++; }];
        PumpFor(0.05);
        [grace detachImmediately:@"removed-participant" action:^{ immediateCleanup++; }];
        Require(immediateCleanup == 1 && ![grace hasPendingIdentifier:@"removed-participant"], "participant removal performs cleanup immediately");
        [grace scheduleIdentifier:@"removed-participant" action:^{ replacementDetach++; }];
        PumpFor(0.24);
        Require(staleDetach == 0 && replacementDetach == 1, "old callback cannot detach a replacement with the same identifier");

        __block NSUInteger abandonedDetach = 0;
        WHZoomVideoDetachGrace *abandoned = [WHZoomVideoDetachGrace new];
        [abandoned scheduleIdentifier:@"abandoned" action:^{ abandonedDetach++; }];
        abandoned = nil;
        PumpFor(0.24);
        Require(abandonedDetach == 0, "destroying the grace owner cancels stale pending work");
        puts("PASS video detach grace: reattachment cancellation, non-sliding deadline, immediate removal, replacement identity, owner lifetime");
    }
    return 0;
}
