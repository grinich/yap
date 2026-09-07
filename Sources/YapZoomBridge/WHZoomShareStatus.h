#import <ZoomSDK/ZoomSDKErrors.h>

typedef NS_ENUM(NSUInteger, WHZoomLocalShareUpdate) {
    WHZoomLocalShareUpdateUnchanged,
    WHZoomLocalShareUpdateActive,
    WHZoomLocalShareUpdateIdle
};

static inline BOOL WHZoomShareSourceMatches(uint32_t windowID, uint32_t displayID,
                                          uint32_t requestedWindowID, uint32_t requestedDisplayID) {
    if (requestedWindowID != 0 && requestedDisplayID == 0) return windowID == requestedWindowID;
    if (requestedDisplayID != 0 && requestedWindowID == 0) return windowID == 0 && displayID == requestedDisplayID;
    return NO;
}

static inline WHZoomLocalShareUpdate WHZoomLocalShareUpdateForStatus(
    ZoomSDKShareStatus status, unsigned int ownerID, unsigned int localID
) {
    // SelfBegin/SelfEnd already identify the local user. Do not discard those
    // authoritative callbacks merely because their source metadata is incomplete.
    switch (status) {
        case ZoomSDKShareStatus_SelfBegin: return WHZoomLocalShareUpdateActive;
        case ZoomSDKShareStatus_SelfEnd: return WHZoomLocalShareUpdateIdle;
        case ZoomSDKShareStatus_Resume:
            return ownerID != 0 && ownerID == localID ? WHZoomLocalShareUpdateActive : WHZoomLocalShareUpdateUnchanged;
        default: return WHZoomLocalShareUpdateUnchanged;
    }
}
