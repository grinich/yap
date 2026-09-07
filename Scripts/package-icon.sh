#!/bin/bash
set -euo pipefail
WHOOSH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHOOSH_ICON_OUTPUT="$WHOOSH_ROOT/../work/Whoosh-Icon-Assets"
mkdir -p "$WHOOSH_ICON_OUTPUT"
cp "$WHOOSH_ROOT/Resources/Info.plist" "$WHOOSH_ICON_OUTPUT/Info.plist"
/bin/bash "$WHOOSH_ROOT/Scripts/compile-app-icon.sh" "$WHOOSH_ICON_OUTPUT" "$WHOOSH_ICON_OUTPUT/Info.plist"
cp "$WHOOSH_ICON_OUTPUT/Whoosh.icns" "$WHOOSH_ROOT/Resources/Whoosh.icns"
printf 'Prepared native Zooom icon assets in %s. App builds compile the .icon document directly.\n' "$WHOOSH_ICON_OUTPUT"
