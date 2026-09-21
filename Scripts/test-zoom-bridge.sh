#!/bin/bash
set -euo pipefail

YAP_NATIVE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export YAP_ZOOM_SDK_PATH="${YAP_ZOOM_SDK_PATH:-$YAP_NATIVE_ROOT/Vendor/Zoom/zoom-sdk-macos-7.1.5.84750/ZoomSDK}"
if [[ ! -f "$YAP_ZOOM_SDK_PATH/ZoomSDK.framework/Headers/ZoomSDK.h" ]]; then
    echo "Native bridge tests require the verified Zoom SDK in YAP_ZOOM_SDK_PATH." >&2
    exit 1
fi

YAP_NATIVE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/yap-zoom-bridge-tests.XXXXXX")"
trap 'rm -rf "$YAP_NATIVE_WORK"' EXIT
export CLANG_MODULE_CACHE_PATH="$YAP_NATIVE_WORK/module-cache"

# These are independent executables, each with its own main and inert SDK
# collaborators. They never join a meeting or activate a media device.
# Keep visible-window fixtures out of unattended CI. AvatarEventsTests and
# VideoDimensionsTests also remain excluded until their old roster mocks are
# updated for the current SDK selectors; their omission is not a passing test.
run_bounded() {
    python3 - "$@" <<'PY'
import os
import signal
import subprocess
import sys

process = subprocess.Popen(sys.argv[1:], start_new_session=True)
try:
    result = process.wait(timeout=180)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    sys.exit("Native test command exceeded its three-minute limit.")
sys.exit(result if result >= 0 else 1)
PY
}

for suite in camera-effects media-devices chat-content; do
    printf 'Running native suite: %s\n' "$suite"
    run_bounded /bin/bash "$YAP_NATIVE_ROOT/Scripts/test-$suite.sh"
done

native_flags=(
    -fobjc-arc -fmodules -mmacosx-version-min=26.0
    -F "$YAP_ZOOM_SDK_PATH"
    -I "$YAP_NATIVE_ROOT/Sources/YapZoomBridge"
    -I "$YAP_NATIVE_ROOT/Sources/YapZoomBridge/include"
)
native_link_flags=(
    -Wl,-rpath,"$YAP_ZOOM_SDK_PATH"
    -framework ZoomSDK -framework AppKit -framework AVFoundation
)

# Compile the shared bridge once for fixtures that exercise it. Header-only
# PhotoShutterTests must be linked separately: its header owns an implementation
# that YapZoomBridge.m also includes.
bridge_objects=()
for source in YapZoomBridge WHZoomRenderHost WHZoomVideoDetachGrace WHZoomCloudRecordingPolicy WHZoomChatSupport; do
    object="$YAP_NATIVE_WORK/$source.o"
    run_bounded xcrun clang "${native_flags[@]}" -c "$YAP_NATIVE_ROOT/Sources/YapZoomBridge/$source.m" -o "$object"
    bridge_objects+=("$object")
done

run_native_suite() {
    local suite="$1"
    shift
    local executable="$YAP_NATIVE_WORK/$suite"
    local link_flags=("${native_link_flags[@]}")
    if [[ "$suite" == RenderHostLifecycleTests || "$suite" == VideoDetachGraceTests ]]; then
        # These fixtures deliberately exercise AppKit/Foundation without Zoom.
        link_flags=(-framework AppKit)
    fi
    printf 'Running native suite: %s\n' "$suite"
    run_bounded xcrun clang "${native_flags[@]}" "${link_flags[@]}" \
        "$YAP_NATIVE_ROOT/Tests/YapZoomBridgeTests/$suite.m" "$@" -o "$executable"
    run_bounded "$executable"
}

run_native_suite ComputerAudioSharingTests "${bridge_objects[@]}"
run_native_suite VideoCaptureReadinessTests "${bridge_objects[@]}"
run_native_suite JoinMediaPreferenceTests "${bridge_objects[@]}"
run_native_suite PhotoShutterTests
run_native_suite ShareStatusTests
run_native_suite CloudRecordingPolicyTests "$YAP_NATIVE_WORK/WHZoomCloudRecordingPolicy.o"
run_native_suite RenderHostLifecycleTests "$YAP_NATIVE_WORK/WHZoomRenderHost.o"
run_native_suite VideoDetachGraceTests "$YAP_NATIVE_WORK/WHZoomVideoDetachGrace.o"
printf 'All 11 native bridge suites passed.\n'
