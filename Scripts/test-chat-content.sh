#!/bin/bash
set -euo pipefail
YAP_CHAT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YAP_CHAT_SDK="${YAP_ZOOM_SDK_PATH:-$YAP_CHAT_ROOT/Vendor/Zoom/zoom-sdk-macos-7.1.5.84750/ZoomSDK}"
YAP_CHAT_WORK="$(mktemp -d "${TMPDIR:-/tmp}/yap-chat-tests.XXXXXX")"
trap 'rm -rf "$YAP_CHAT_WORK"' EXIT
xcrun clang -fobjc-arc -fmodules -mmacosx-version-min=26.0 \
    -F "$YAP_CHAT_SDK" -Wl,-rpath,"$YAP_CHAT_SDK" -framework ZoomSDK -framework AppKit -framework AVFoundation \
    -I "$YAP_CHAT_ROOT/Sources/YapZoomBridge" -I "$YAP_CHAT_ROOT/Sources/YapZoomBridge/include" \
    "$YAP_CHAT_ROOT/Sources/YapZoomBridge/YapZoomBridge.m" \
    "$YAP_CHAT_ROOT/Sources/YapZoomBridge/WHZoomRenderHost.m" \
    "$YAP_CHAT_ROOT/Sources/YapZoomBridge/WHZoomVideoDetachGrace.m" \
    "$YAP_CHAT_ROOT/Sources/YapZoomBridge/WHZoomCloudRecordingPolicy.m" \
    "$YAP_CHAT_ROOT/Sources/YapZoomBridge/WHZoomChatSupport.m" \
    "$YAP_CHAT_ROOT/Tests/YapZoomBridgeTests/ChatContentTests.m" \
    -o "$YAP_CHAT_WORK/chat-content-tests"
"$YAP_CHAT_WORK/chat-content-tests"
