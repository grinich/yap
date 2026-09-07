#import <Foundation/Foundation.h>
#import <ZoomSDK/ZoomSDKErrors.h>

typedef NS_ENUM(NSInteger, WHZoomCloudRecordingAction) {
    WHZoomCloudRecordingActionStart, WHZoomCloudRecordingActionStop,
    WHZoomCloudRecordingActionPause, WHZoomCloudRecordingActionResume
};

NSDictionary *WHZoomCloudRecordingPayload(ZoomSDKRecordingStatus status, ZoomSDKError startPermission,
                                         BOOL connected, BOOL controlRole);
ZoomSDKError WHZoomCloudRecordingCommandError(WHZoomCloudRecordingAction action, ZoomSDKRecordingStatus status,
                                             ZoomSDKError startPermission, BOOL connected, BOOL controlRole);
