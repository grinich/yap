#!/bin/bash
set -euo pipefail

YAP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YAP_CAMERA_TEST_SDK="${YAP_ZOOM_SDK_PATH:-$YAP_ROOT/Vendor/Zoom/zoom-sdk-macos-7.1.5.84750/ZoomSDK}"
if [[ ! -f "$YAP_CAMERA_TEST_SDK/ZoomSDK.framework/Headers/ZoomSDK.h" ]]; then
    echo "Set YAP_ZOOM_SDK_PATH to the ZoomSDK directory containing ZoomSDK.framework." >&2
    exit 1
fi

YAP_CAMERA_TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/yap-media-device-tests.XXXXXX")"
trap 'rm -rf "$YAP_CAMERA_TEST_WORK"' EXIT

xcrun clang -fobjc-arc -fmodules -mmacosx-version-min=26.0 \
    -F "$YAP_CAMERA_TEST_SDK" -Wl,-rpath,"$YAP_CAMERA_TEST_SDK" \
    -framework ZoomSDK -framework AppKit -framework AVFoundation -framework CoreAudio \
    -I "$YAP_ROOT/Sources/YapZoomBridge/include" -I "$YAP_ROOT/Sources/YapZoomBridge" \
    "$YAP_ROOT/Sources/YapZoomBridge/YapZoomBridge.m" \
    "$YAP_ROOT/Sources/YapZoomBridge/WHZoomRenderHost.m" \
    "$YAP_ROOT/Sources/YapZoomBridge/WHZoomVideoDetachGrace.m" \
    "$YAP_ROOT/Sources/YapZoomBridge/WHZoomCloudRecordingPolicy.m" \
    "$YAP_ROOT/Sources/YapZoomBridge/WHZoomChatSupport.m" \
    "$YAP_ROOT/Tests/YapZoomBridgeTests/MediaDeviceLifecycleTests.m" \
    -o "$YAP_CAMERA_TEST_WORK/media-device-tests"

"$YAP_CAMERA_TEST_WORK/media-device-tests" "$YAP_CAMERA_TEST_WORK"
