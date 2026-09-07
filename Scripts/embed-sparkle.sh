#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 app-bundle SwiftPM-bin-directory" >&2
    exit 2
fi
app="$1"
source_framework="$2/Sparkle.framework"
framework="$app/Contents/Frameworks/Sparkle.framework"
: "${WHOOSH_SIGNING_IDENTITY:?Set the app signing identity}"
test -f "$source_framework/Sparkle"
ditto "$source_framework" "$framework"
# Follow Sparkle's manual distribution signing order. Keep versioned symlinks.
for target in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    codesign --force --sign "$WHOOSH_SIGNING_IDENTITY" --options runtime --timestamp \
        "$framework/Versions/B/$target"
done
codesign --force --sign "$WHOOSH_SIGNING_IDENTITY" --options runtime --timestamp "$framework"
codesign --verify --deep --strict "$framework"
test -L "$framework/Versions/Current"
test -L "$framework/Sparkle"
