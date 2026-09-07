#import <Foundation/Foundation.h>
#import "WHZoomCloudRecordingPolicy.h"

static void Require(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "FAIL %s\n", message); exit(1); }
}
static BOOL State(NSDictionary *payload, NSString *state) { return [payload[@"state"] isEqualToString:state]; }
static BOOL Control(NSDictionary *payload) { return [payload[@"canControl"] boolValue]; }

int main(void) {
    @autoreleasepool {
        // Recording activity remains visible to people who cannot control it.
        NSDictionary *guest = WHZoomCloudRecordingPayload(ZoomSDKRecordingStatus_Start, ZoomSDKError_NoPermission, YES, NO);
        Require(State(guest, @"recording") && !Control(guest) && guest[@"unavailableReason"] != nil,
                "attendee sees the actual active recording without recording authority");
        NSDictionary *pausedGuest = WHZoomCloudRecordingPayload(ZoomSDKRecordingStatus_Pause, ZoomSDKError_NoPermission, YES, NO);
        Require(State(pausedGuest, @"paused") && !Control(pausedGuest), "paused status survives loss of control role");
        NSDictionary *disconnected = WHZoomCloudRecordingPayload(ZoomSDKRecordingStatus_Start, ZoomSDKError_Success, NO, YES);
        Require(State(disconnected, @"recording") && !Control(disconnected), "connection loss cannot erase known recording activity");

        // Connecting is progress, not loss of authority. It is never success and
        // no conflicting command may run even when the host retains authority.
        NSDictionary *connecting = WHZoomCloudRecordingPayload(ZoomSDKRecordingStatus_Connecting, ZoomSDKError_Success, YES, YES);
        Require(State(connecting, @"connecting") && Control(connecting), "connecting preserves host authority");
        NSDictionary *lostRole = WHZoomCloudRecordingPayload(ZoomSDKRecordingStatus_Connecting, ZoomSDKError_Success, YES, NO);
        Require(State(lostRole, @"connecting") && !Control(lostRole), "actual connecting role loss is distinguishable");
        for (NSInteger value = WHZoomCloudRecordingActionStart; value <= WHZoomCloudRecordingActionResume; value++) {
            Require(WHZoomCloudRecordingCommandError((WHZoomCloudRecordingAction)value, ZoomSDKRecordingStatus_Connecting,
                ZoomSDKError_Success, YES, YES) == ZoomSDKError_WrongUsage, "connecting rejects conflicting commands");
        }

        NSDictionary *eligible = WHZoomCloudRecordingPayload(ZoomSDKRecordingStatus_Stop, ZoomSDKError_Success, YES, YES);
        NSDictionary *ineligible = WHZoomCloudRecordingPayload(ZoomSDKRecordingStatus_Stop, ZoomSDKError_NoPermission, YES, YES);
        Require(State(eligible, @"stopped") && Control(eligible), "eligible host can offer a new recording");
        Require(State(ineligible, @"unavailable") && !Control(ineligible), "start capability failure is not an enabled recording control");
        Require(WHZoomCloudRecordingCommandError(WHZoomCloudRecordingActionStart, ZoomSDKRecordingStatus_Stop,
            ZoomSDKError_NoPermission, YES, YES) == ZoomSDKError_NoPermission, "SDK permission errors survive start validation");
        Require(WHZoomCloudRecordingCommandError(WHZoomCloudRecordingActionStart, ZoomSDKRecordingStatus_Stop,
            ZoomSDKError_Success, YES, NO) == ZoomSDKError_NoPermission, "recording privilege never grants an attendee host controls");

        // Losing permission to START cannot prevent stopping an existing cloud
        // recording. Each actual control call is still authorized by the SDK.
        Require(WHZoomCloudRecordingCommandError(WHZoomCloudRecordingActionStop, ZoomSDKRecordingStatus_Start,
            ZoomSDKError_NoPermission, YES, YES) == ZoomSDKError_Success, "host can stop existing recording after start eligibility changes");
        Require(WHZoomCloudRecordingCommandError(WHZoomCloudRecordingActionPause, ZoomSDKRecordingStatus_Start,
            ZoomSDKError_NoPermission, YES, YES) == ZoomSDKError_Success, "host can pause an existing recording");
        Require(WHZoomCloudRecordingCommandError(WHZoomCloudRecordingActionResume, ZoomSDKRecordingStatus_Pause,
            ZoomSDKError_NoPermission, YES, YES) == ZoomSDKError_Success, "host can resume a paused recording");
        Require(WHZoomCloudRecordingCommandError(WHZoomCloudRecordingActionResume, ZoomSDKRecordingStatus_Start,
            ZoomSDKError_Success, YES, YES) == ZoomSDKError_WrongUsage, "resume cannot create a second active recording");
        Require(WHZoomCloudRecordingCommandError(WHZoomCloudRecordingActionStop, ZoomSDKRecordingStatus_Start,
            ZoomSDKError_Success, NO, YES) == ZoomSDKError_WrongUsage, "disconnected control cannot reach SDK mutation");

        NSDictionary *full = WHZoomCloudRecordingPayload(ZoomSDKRecordingStatus_DiskFull, ZoomSDKError_Success, YES, YES);
        NSDictionary *failed = WHZoomCloudRecordingPayload(ZoomSDKRecordingStatus_Fail, ZoomSDKError_Success, YES, YES);
        Require(State(full, @"unavailable") && !Control(full), "storage-full status cannot claim successful recording");
        Require(State(failed, @"stopped") && Control(failed), "eligible failed recording can be manually retried");
        NSDictionary *unknown = WHZoomCloudRecordingPayload((ZoomSDKRecordingStatus)999, ZoomSDKError_Success, YES, YES);
        Require(State(unknown, @"unavailable") && !Control(unknown), "unknown SDK status fails closed");
        puts("PASS cloud recording policy: activity visibility, connecting authority, command guards, role loss, storage failure, retry and unknown status");
    }
    return 0;
}
