#!/bin/bash
set -euo pipefail
WHOOSH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$WHOOSH_ROOT/../work" "${WHOOSH_OUTPUT_DIR:-$WHOOSH_ROOT/../outputs}"
WHOOSH_WORK="$(cd "$WHOOSH_ROOT/../work" && pwd)"
WHOOSH_OUTPUT="$(cd "${WHOOSH_OUTPUT_DIR:-$WHOOSH_ROOT/../outputs}" && pwd)"
ensure_output_is_not_running() {
    local lookup_status matching_pids process_id executable
    matching_pids="$(/usr/bin/pgrep -x Whoosh)" && lookup_status=0 || lookup_status=$?
    [[ "$lookup_status" -eq 1 ]] && return 0
    [[ "$lookup_status" -eq 0 ]] || { echo 'Cannot inspect running apps; refusing output replacement.' >&2; return 1; }
    for process_id in $matching_pids; do
        executable="$(/bin/ps -p "$process_id" -o comm=)" || return 1
        if [[ "$executable" == "$WHOOSH_OUTPUT/Zooom.app/Contents/MacOS/Whoosh" ]]; then
            echo 'Zooom is running from this output. Set WHOOSH_OUTPUT_DIR to a different directory.' >&2
            return 1
        fi
    done
}
ensure_output_is_not_running
WHOOSH_CONFIGURATION="${1:-debug}"
# Keep a stable certificate identity across personal updates when configured.
# A name or exact certificate SHA-1 fingerprint is accepted by codesign. Never
# fall back to ad-hoc signing if a supplied identity fails or is unavailable.
WHOOSH_SIGNING_IDENTITY="$(python3 "$WHOOSH_ROOT/Scripts/resolve-signing-identity.py" "$WHOOSH_ROOT")"
export WHOOSH_SIGNING_IDENTITY
export WHOOSH_ZOOM_SDK_PATH="${WHOOSH_ZOOM_SDK_PATH:-$WHOOSH_ROOT/Vendor/Zoom/zoom-sdk-macos-7.1.5.84750/ZoomSDK}"
export CLANG_MODULE_CACHE_PATH="$WHOOSH_WORK/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WHOOSH_WORK/module-cache"
cd "$WHOOSH_ROOT"
swift build --configuration "$WHOOSH_CONFIGURATION" --disable-sandbox --cache-path "$WHOOSH_WORK/spm-cache"
WHOOSH_BIN="$(swift build --configuration "$WHOOSH_CONFIGURATION" --show-bin-path --disable-sandbox --cache-path "$WHOOSH_WORK/spm-cache")"
WHOOSH_STAGE="$(mktemp -d "$WHOOSH_OUTPUT/.whoosh-build.XXXXXX")"
trap 'rm -rf "$WHOOSH_STAGE"' EXIT
WHOOSH_APP="$WHOOSH_STAGE/Zooom.app"
mkdir -p "$WHOOSH_APP/Contents/MacOS" "$WHOOSH_APP/Contents/Resources" "$WHOOSH_APP/Contents/Frameworks"
cp "$WHOOSH_BIN/Whoosh" "$WHOOSH_APP/Contents/MacOS/Whoosh"
cp "$WHOOSH_ROOT/Resources/Info.plist" "$WHOOSH_APP/Contents/Info.plist"
python3 "$WHOOSH_ROOT/Scripts/configure-updates.py" "$WHOOSH_APP/Contents/Info.plist"
/bin/bash "$WHOOSH_ROOT/Scripts/compile-app-icon.sh" "$WHOOSH_APP/Contents/Resources" "$WHOOSH_APP/Contents/Info.plist"
if [ -f "$WHOOSH_ROOT/Resources/WhooshIcon.png" ]; then
    cp "$WHOOSH_ROOT/Resources/WhooshIcon.png" "$WHOOSH_APP/Contents/Resources/WhooshIcon.png"
fi
if [ -x "$WHOOSH_ROOT/Scripts/extract-app-intents.sh" ]; then
    "$WHOOSH_ROOT/Scripts/extract-app-intents.sh" "$WHOOSH_BIN/Whoosh" "$WHOOSH_APP/Contents/Resources"
fi
WHOOSH_ENTITLEMENTS="$WHOOSH_ROOT/Resources/Whoosh.entitlements"
WHOOSH_LINKS="$(otool -L "$WHOOSH_APP/Contents/MacOS/Whoosh")"
if [[ "$WHOOSH_LINKS" == *"ZoomSDK.framework/"* ]]; then
    /bin/bash "$WHOOSH_ROOT/Scripts/embed-zoom-sdk.sh" "$WHOOSH_APP" "$WHOOSH_ZOOM_SDK_PATH"
    WHOOSH_ENTITLEMENTS="$WHOOSH_ROOT/Resources/WhooshZoom.entitlements"
fi
/bin/bash "$WHOOSH_ROOT/Scripts/embed-sparkle.sh" "$WHOOSH_APP" "$WHOOSH_BIN"
WHOOSH_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WHOOSH_APP/Contents/Info.plist")"
codesign --force --sign "$WHOOSH_SIGNING_IDENTITY" --identifier "$WHOOSH_BUNDLE_ID" --options runtime --entitlements "$WHOOSH_ENTITLEMENTS" "$WHOOSH_APP"
codesign --verify --deep --strict "$WHOOSH_APP"
plutil -lint "$WHOOSH_APP/Contents/Info.plist"
# Replace the previous generated bundle only after the complete new bundle verifies.
ensure_output_is_not_running
rm -rf "$WHOOSH_OUTPUT/Zooom.app"
mv "$WHOOSH_APP" "$WHOOSH_OUTPUT/Zooom.app"
printf 'Built %s\n' "$WHOOSH_OUTPUT/Zooom.app"
