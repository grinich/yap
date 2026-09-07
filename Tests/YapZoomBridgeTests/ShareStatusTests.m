#import "WHZoomShareStatus.h"

static void Check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

int main(void) {
    @autoreleasepool {
        Check(WHZoomLocalShareUpdateForStatus(ZoomSDKShareStatus_SelfBegin, 0, 42) == WHZoomLocalShareUpdateActive,
              @"SelfBegin activates Stop/Switch controls even before owner metadata arrives");
        Check(WHZoomLocalShareUpdateForStatus(ZoomSDKShareStatus_SelfBegin, 17, 42) == WHZoomLocalShareUpdateActive,
              @"SelfBegin remains authoritative when its owner metadata differs");
        Check(WHZoomLocalShareUpdateForStatus(ZoomSDKShareStatus_SelfBegin, 0, 0) == WHZoomLocalShareUpdateActive,
              @"SelfBegin does not depend on the local user getter being ready");
        Check(WHZoomLocalShareUpdateForStatus(ZoomSDKShareStatus_SelfEnd, 0, 42) == WHZoomLocalShareUpdateIdle,
              @"SelfEnd clears controls without requiring source metadata");
        Check(WHZoomLocalShareUpdateForStatus(ZoomSDKShareStatus_Resume, 42, 42) == WHZoomLocalShareUpdateActive,
              @"known local Resume restores active sharing");
        Check(WHZoomLocalShareUpdateForStatus(ZoomSDKShareStatus_Resume, 17, 42) == WHZoomLocalShareUpdateUnchanged &&
              WHZoomLocalShareUpdateForStatus(ZoomSDKShareStatus_Resume, 0, 0) == WHZoomLocalShareUpdateUnchanged,
              @"remote or unknown Resume must not claim local sharing");
        for (NSNumber *status in @[@(ZoomSDKShareStatus_None), @(ZoomSDKShareStatus_OtherBegin),
                                    @(ZoomSDKShareStatus_OtherEnd), @(ZoomSDKShareStatus_ViewOther),
                                    @(ZoomSDKShareStatus_Pause)]) {
            Check(WHZoomLocalShareUpdateForStatus(status.integerValue, 42, 42) == WHZoomLocalShareUpdateUnchanged,
                  @"unrelated or paused share status preserves the last authoritative local state");
        }
        Check(WHZoomShareSourceMatches(42, 9, 42, 0), @"a window source can include its containing display");
        Check(!WHZoomShareSourceMatches(41, 9, 42, 0), @"the previous window cannot confirm a new selection");
        Check(WHZoomShareSourceMatches(0, 9, 0, 9), @"the exact display can confirm display sharing");
        Check(!WHZoomShareSourceMatches(42, 9, 0, 9), @"a window on the selected display is not entire-display confirmation");
        Check(!WHZoomShareSourceMatches(0, 0, 0, 0) && !WHZoomShareSourceMatches(42, 9, 42, 9),
              @"missing or ambiguous requested identifiers cannot confirm a source");
        puts("PASS: SDK 7.1.5 self-share status, owner-checked resume, and exact source confirmation mapping");
    }
    return 0;
}
