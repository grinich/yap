#!/bin/bash
set -euo pipefail

WHOOSH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHOOSH_RESOURCES="${1:?Usage: compile-app-icon.sh resources-directory Info.plist}"
WHOOSH_INFO="${2:?Usage: compile-app-icon.sh resources-directory Info.plist}"
WHOOSH_ICON="$WHOOSH_ROOT/Resources/Whoosh.icon"
WHOOSH_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/whoosh-native-icon.XXXXXX")"
trap 'rm -rf "$WHOOSH_TEMP"' EXIT
mkdir -p "$WHOOSH_TEMP/Compiled" "$WHOOSH_RESOURCES"

# Compile the Icon Composer document, including its system-rendered appearances.
# A loose, pre-rounded PNG/ICNS alone makes macOS frame the artwork a second time.
xcrun actool "$WHOOSH_ICON" \
    --compile "$WHOOSH_TEMP/Compiled" \
    --platform macosx --minimum-deployment-target 26.0 \
    --app-icon Whoosh --output-partial-info-plist "$WHOOSH_TEMP/Icon.plist" \
    --output-format human-readable-text --notices --warnings

python3 - "$WHOOSH_TEMP" "$WHOOSH_RESOURCES" "$WHOOSH_INFO" <<'PY'
from pathlib import Path
import plistlib
import shutil
import sys

temporary, resources, info_path = map(Path, sys.argv[1:])
metadata = plistlib.loads((temporary / "Icon.plist").read_bytes())
if metadata.get("CFBundleIconName") != "Whoosh":
    raise SystemExit("Apple's asset compiler did not emit Whoosh icon metadata")
for name in ("Assets.car", "Whoosh.icns"):
    artifact = temporary / "Compiled" / name
    if not artifact.is_file() or artifact.stat().st_size == 0:
        raise SystemExit(f"Missing compiled icon artifact: {name}")
    shutil.copy2(artifact, resources / name)
info = plistlib.loads(info_path.read_bytes())
info.update(metadata)
updated_path = info_path.with_suffix(".icon-build.plist")
updated_path.write_bytes(plistlib.dumps(info))
updated_path.replace(info_path)
PY
printf 'Compiled Zooom Icon Composer asset and merged native icon metadata.\n'
