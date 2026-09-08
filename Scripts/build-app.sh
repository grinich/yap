#!/bin/bash
set -euo pipefail
YAP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$YAP_ROOT/../work" "${YAP_OUTPUT_DIR:-$YAP_ROOT/../outputs}"
YAP_WORK="$(cd "$YAP_ROOT/../work" && pwd)"
YAP_OUTPUT="$(cd "${YAP_OUTPUT_DIR:-$YAP_ROOT/../outputs}" && pwd)"
ensure_output_is_not_running() {
    local lookup_status matching_pids process_id executable
    matching_pids="$(/usr/bin/pgrep -x Yap)" && lookup_status=0 || lookup_status=$?
    [[ "$lookup_status" -eq 1 ]] && return 0
    [[ "$lookup_status" -eq 0 ]] || { echo 'Cannot inspect running apps; refusing output replacement.' >&2; return 1; }
    for process_id in $matching_pids; do
        executable="$(/bin/ps -p "$process_id" -o comm=)" || return 1
        if [[ "$executable" == "$YAP_OUTPUT/Yap.app/Contents/MacOS/Yap" ]]; then
            echo 'Yap is running from this output. Set YAP_OUTPUT_DIR to a different directory.' >&2
            return 1
        fi
    done
}
ensure_output_is_not_running
YAP_CONFIGURATION="${1:-debug}"
# Keep a stable certificate identity across personal updates when configured.
# A name or exact certificate SHA-1 fingerprint is accepted by codesign. Never
# fall back to ad-hoc signing if a supplied identity fails or is unavailable.
YAP_SIGNING_IDENTITY="$(python3 "$YAP_ROOT/Scripts/resolve-signing-identity.py" "$YAP_ROOT")"
export YAP_SIGNING_IDENTITY
export YAP_ZOOM_SDK_PATH="${YAP_ZOOM_SDK_PATH:-$YAP_ROOT/Vendor/Zoom/zoom-sdk-macos-7.1.5.84750/ZoomSDK}"
export CLANG_MODULE_CACHE_PATH="$YAP_WORK/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$YAP_WORK/module-cache"
cd "$YAP_ROOT"
swift build --configuration "$YAP_CONFIGURATION" --disable-sandbox --cache-path "$YAP_WORK/spm-cache"
YAP_BIN="$(swift build --configuration "$YAP_CONFIGURATION" --show-bin-path --disable-sandbox --cache-path "$YAP_WORK/spm-cache")"
YAP_STAGE="$(mktemp -d "$YAP_OUTPUT/.yap-build.XXXXXX")"
trap 'rm -rf "$YAP_STAGE"' EXIT
YAP_APP="$YAP_STAGE/Yap.app"
mkdir -p "$YAP_APP/Contents/MacOS" "$YAP_APP/Contents/Resources" "$YAP_APP/Contents/Frameworks"
cp "$YAP_BIN/Yap" "$YAP_APP/Contents/MacOS/Yap"
cp "$YAP_ROOT/Resources/Info.plist" "$YAP_APP/Contents/Info.plist"
python3 "$YAP_ROOT/Scripts/configure-updates.py" "$YAP_APP/Contents/Info.plist"
python3 "$YAP_ROOT/Scripts/configure-google.py" "$YAP_APP/Contents/Info.plist"
/bin/bash "$YAP_ROOT/Scripts/compile-app-icon.sh" "$YAP_APP/Contents/Resources" "$YAP_APP/Contents/Info.plist"
if [ -f "$YAP_ROOT/Resources/YapIcon.png" ]; then
    cp "$YAP_ROOT/Resources/YapIcon.png" "$YAP_APP/Contents/Resources/YapIcon.png"
fi
if [ -x "$YAP_ROOT/Scripts/extract-app-intents.sh" ]; then
    "$YAP_ROOT/Scripts/extract-app-intents.sh" "$YAP_BIN/Yap" "$YAP_APP/Contents/Resources"
fi
YAP_ENTITLEMENTS="$YAP_ROOT/Resources/Yap.entitlements"
YAP_LINKS="$(otool -L "$YAP_APP/Contents/MacOS/Yap")"
if [[ "$YAP_LINKS" == *"ZoomSDK.framework/"* ]]; then
    /bin/bash "$YAP_ROOT/Scripts/embed-zoom-sdk.sh" "$YAP_APP" "$YAP_ZOOM_SDK_PATH"
    YAP_ENTITLEMENTS="$YAP_ROOT/Resources/YapZoom.entitlements"
fi
/bin/bash "$YAP_ROOT/Scripts/embed-sparkle.sh" "$YAP_APP" "$YAP_BIN"
YAP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$YAP_APP/Contents/Info.plist")"
codesign --force --sign "$YAP_SIGNING_IDENTITY" --identifier "$YAP_BUNDLE_ID" --options runtime --entitlements "$YAP_ENTITLEMENTS" "$YAP_APP"
codesign --verify --deep --strict "$YAP_APP"
plutil -lint "$YAP_APP/Contents/Info.plist"
# Replace the previous generated bundle only after the complete new bundle verifies.
ensure_output_is_not_running
rm -rf "$YAP_OUTPUT/Yap.app"
mv "$YAP_APP" "$YAP_OUTPUT/Yap.app"
printf 'Built %s\n' "$YAP_OUTPUT/Yap.app"
