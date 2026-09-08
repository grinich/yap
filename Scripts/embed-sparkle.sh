#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 app-bundle SwiftPM-bin-directory" >&2
    exit 2
fi
app="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"
source_framework="$2/Sparkle.framework"
source_license="$root/.build/artifacts/sparkle/Sparkle/LICENSE"
framework="$app/Contents/Frameworks/Sparkle.framework"
: "${YAP_SIGNING_IDENTITY:?Set the app signing identity}"
test -f "$source_framework/Sparkle"
if [ ! -s "$source_license" ]; then
    echo "Sparkle's complete upstream LICENSE is missing; resolve the pinned dependency before packaging." >&2
    exit 1
fi
ditto "$source_framework" "$framework"
licenses="$app/Contents/Resources/ThirdPartyLicenses"
mkdir -p "$licenses"
ditto "$source_license" "$licenses/Sparkle.txt"
cmp "$source_license" "$licenses/Sparkle.txt"
python3 "$root/Scripts/trim-runtime.py" "$framework"
# Follow Sparkle's manual distribution signing order. Keep versioned symlinks.
for target in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    codesign --force --sign "$YAP_SIGNING_IDENTITY" --options runtime --timestamp \
        "$framework/Versions/B/$target"
done
codesign --force --sign "$YAP_SIGNING_IDENTITY" --options runtime --timestamp "$framework"
codesign --verify --deep --strict "$framework"
test -L "$framework/Versions/Current"
test -L "$framework/Sparkle"
