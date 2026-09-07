#!/bin/bash
set -euo pipefail

YAP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YAP_RESOURCES="${1:?Usage: compile-app-icon.sh resources-directory Info.plist}"
YAP_INFO="${2:?Usage: compile-app-icon.sh resources-directory Info.plist}"
YAP_ICON="$YAP_ROOT/Resources/Yap.icon"
YAP_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/yap-native-icon.XXXXXX")"
trap 'rm -rf "$YAP_TEMP"' EXIT
mkdir -p "$YAP_TEMP/Compiled" "$YAP_RESOURCES"

# Compile the Icon Composer document, including its system-rendered appearances.
# A loose, pre-rounded PNG/ICNS alone makes macOS frame the artwork a second time.
xcrun actool "$YAP_ICON" \
    --compile "$YAP_TEMP/Compiled" \
    --platform macosx --minimum-deployment-target 26.0 \
    --app-icon Yap --output-partial-info-plist "$YAP_TEMP/Icon.plist" \
    --output-format human-readable-text --notices --warnings

python3 - "$YAP_TEMP" "$YAP_RESOURCES" "$YAP_INFO" <<'PY'
from pathlib import Path
import plistlib
import shutil
import sys

temporary, resources, info_path = map(Path, sys.argv[1:])
metadata = plistlib.loads((temporary / "Icon.plist").read_bytes())
if metadata.get("CFBundleIconName") != "Yap":
    raise SystemExit("Apple's asset compiler did not emit Yap icon metadata")
for name in ("Assets.car", "Yap.icns"):
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
printf 'Compiled Yap Icon Composer asset and merged native icon metadata.\n'
