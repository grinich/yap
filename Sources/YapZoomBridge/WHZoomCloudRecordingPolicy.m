#import "WHZoomCloudRecordingPolicy.h"

NSDictionary *WHZoomCloudRecordingPayload(ZoomSDKRecordingStatus status, ZoomSDKError startPermission,
                                         BOOL connected, BOOL controlRole) {
    NSString *state;
    BOOL startable = connected && controlRole && startPermission == ZoomSDKError_Success;
    BOOL controllable = NO;
    switch (status) {
        case ZoomSDKRecordingStatus_Start: state = @"recording"; controllable = connected && controlRole; break;
        case ZoomSDKRecordingStatus_Pause: state = @"paused"; controllable = connected && controlRole; break;
        case ZoomSDKRecordingStatus_Connecting: state = @"connecting"; controllable = connected && controlRole; break;
        case ZoomSDKRecordingStatus_None:
        case ZoomSDKRecordingStatus_Stop:
        case ZoomSDKRecordingStatus_Fail: state = startable ? @"stopped" : @"unavailable"; controllable = startable; break;
        case ZoomSDKRecordingStatus_DiskFull: state = @"unavailable"; break;
        default: state = @"unavailable"; break;
    }
    NSMutableDictionary *payload = [@{@"state":state, @"canControl":@(controllable)} mutableCopy];
    if (!controllable) {
        if (!connected) payload[@"unavailableReason"] = @"Cloud recording controls are available when the meeting is connected.";
        else if (status == ZoomSDKRecordingStatus_DiskFull) payload[@"unavailableReason"] = @"Zoom reports that cloud recording storage is full.";
        else if (!controlRole) payload[@"unavailableReason"] = @"Only the host or a co-host can control cloud recording.";
        else if (status == ZoomSDKRecordingStatus_Connecting) payload[@"unavailableReason"] = @"Zoom is connecting to cloud recording.";
        else payload[@"unavailableReason"] = @"Zoom hasn’t enabled cloud recording for this meeting. Check the host’s recording and security settings and license.";
    }
    return payload;
}

ZoomSDKError WHZoomCloudRecordingCommandError(WHZoomCloudRecordingAction action, ZoomSDKRecordingStatus status,
                                             ZoomSDKError startPermission, BOOL connected, BOOL controlRole) {
    if (!connected) return ZoomSDKError_WrongUsage;
    if (!controlRole) return ZoomSDKError_NoPermission;
    switch (action) {
        case WHZoomCloudRecordingActionStart:
            if (startPermission != ZoomSDKError_Success) return startPermission;
            return status == ZoomSDKRecordingStatus_None || status == ZoomSDKRecordingStatus_Stop || status == ZoomSDKRecordingStatus_Fail
                ? ZoomSDKError_Success : ZoomSDKError_WrongUsage;
        case WHZoomCloudRecordingActionStop:
            return status == ZoomSDKRecordingStatus_Start || status == ZoomSDKRecordingStatus_Pause ? ZoomSDKError_Success : ZoomSDKError_WrongUsage;
        case WHZoomCloudRecordingActionPause:
            return status == ZoomSDKRecordingStatus_Start ? ZoomSDKError_Success : ZoomSDKError_WrongUsage;
        case WHZoomCloudRecordingActionResume:
            return status == ZoomSDKRecordingStatus_Pause ? ZoomSDKError_Success : ZoomSDKError_WrongUsage;
    }
    return ZoomSDKError_WrongUsage;
}
