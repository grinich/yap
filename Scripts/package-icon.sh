#!/bin/bash
set -euo pipefail
YAP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YAP_ICON_OUTPUT="$YAP_ROOT/../work/Yap-Icon-Assets"
mkdir -p "$YAP_ICON_OUTPUT"
cp "$YAP_ROOT/Resources/Info.plist" "$YAP_ICON_OUTPUT/Info.plist"
/bin/bash "$YAP_ROOT/Scripts/compile-app-icon.sh" "$YAP_ICON_OUTPUT" "$YAP_ICON_OUTPUT/Info.plist"
cp "$YAP_ICON_OUTPUT/Yap.icns" "$YAP_ROOT/Resources/Yap.icns"
# Keep the in-app/README icon identical to Apple's rendered application icon.
YAP_ICON_EXPORT="$(mktemp -d "${TMPDIR:-/tmp}/yap-icon-export.XXXXXX")"
trap 'rm -rf "$YAP_ICON_EXPORT"' EXIT
/usr/bin/iconutil -c iconset -o "$YAP_ICON_EXPORT/Yap.iconset" "$YAP_ICON_OUTPUT/Yap.icns"
cp "$YAP_ICON_EXPORT/Yap.iconset/icon_128x128@2x.png" "$YAP_ROOT/Resources/YapIcon.png"
printf 'Prepared native Yap icon assets in %s. App builds compile the .icon document directly.\n' "$YAP_ICON_OUTPUT"
