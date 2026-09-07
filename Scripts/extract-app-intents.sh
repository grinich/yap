#!/usr/bin/env bash
set -euo pipefail

# Usage: extract-app-intents.sh <SwiftPM-built Whoosh binary> <app Contents/Resources>
# The matching SwiftPM Modules directory must be next to the binary, or provided
# through WHOOSH_MODULES_DIR. Run after compilation and before signing the app.
# Xcode's compiler produces the constants; its metadata processor validates and
# merges them. No metadata is synthesized or errors suppressed.

if [[ $# -ne 2 ]]; then
    printf '%s\n' 'Usage: extract-app-intents.sh <Whoosh binary> <app Resources directory>' >&2
    exit 64
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
resources="$2"
modules_dir="${WHOOSH_MODULES_DIR:-$(dirname "$binary")/Modules}"

if [[ ! -x "$binary" || ! -d "$modules_dir" ]]; then
    printf '%s\n' 'Build Whoosh first and pass its SwiftPM binary with the matching Modules directory.' >&2
    exit 66
fi

architectures="$(xcrun lipo -archs "$binary")"
if [[ "$architectures" != "arm64" ]]; then
    printf '%s\n' 'This extraction step targets the Apple silicon Whoosh build (arm64).' >&2
    exit 65
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/whoosh-app-intents.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$scratch/module-cache}"
sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
toolchain_dir="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"
xcode_version="$(xcodebuild -version | awk '/Build version/ { print $3 }')"
deployment_target="${WHOOSH_DEPLOYMENT_TARGET:-26.0}"
target_triple="arm64-apple-macosx${deployment_target}"
bundle_identifier="${WHOOSH_BUNDLE_ID:-com.grinich.woosh}"
if [[ -f "$(dirname "$resources")/Info.plist" ]]; then
    bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(dirname "$resources")/Info.plist")"
fi

# A Swift module that imports the native Zoom bridge records that Clang module
# as a dependency. Reuse SwiftPM's generated module map for this constants pass,
# just as the original executable compilation did. Inspect the actual binary so
# an old module map cannot turn a preview-only build into an SDK build.
native_dependencies=()
binary_libraries="$(otool -L "$binary")"
if [[ "$binary_libraries" == *"ZoomSDK.framework/"* ]]; then
    bridge_modulemap="$(dirname "$modules_dir")/WhooshZoomBridge.build/module.modulemap"
    bridge_headers="$project_root/Sources/WhooshZoomBridge/include"
    zoom_sdk_path="${WHOOSH_ZOOM_SDK_PATH:-$project_root/Vendor/Zoom/zoom-sdk-macos-7.1.5.84750/ZoomSDK}"
    if [[ ! -f "$bridge_modulemap" || ! -d "$bridge_headers" || ! -f "$zoom_sdk_path/ZoomSDK.framework/Headers/ZoomSDK.h" ]]; then
        printf '%s\n' 'The SDK build needs its matching WhooshZoomBridge module map, public headers, and Zoom SDK to extract App Intents.' >&2
        exit 66
    fi
    native_dependencies=(-Xcc "-fmodule-map-file=$bridge_modulemap" \
        -Xcc "-I$bridge_headers" -F "$zoom_sdk_path")
fi

# These are the protocol conformances currently used by Whoosh's intents.
cat > "$scratch/protocols.json" <<'JSON'
["AppIntent", "AppEntity", "AppEnum", "AppShortcutsProvider", "AppIntentsPackage", "EntityQuery", "AppIntentOptionsProvider"]
JSON

compile_constants() {
    local module="$1"
    local sources=("$project_root/Sources/$module/"*.swift)
    local definitions=(-D SWIFT_PACKAGE)
    if [[ "$(basename "$(dirname "$binary")")" != "release" ]]; then
        definitions+=(-D DEBUG)
    fi
    for source in "${sources[@]}"; do
        if [[ "$source" -nt "$binary" ]]; then
            printf 'Rebuild Whoosh before extracting metadata: %s changed after the binary.\n' "$source" >&2
            exit 65
        fi
    done
    printf '%s\n' "${sources[@]}" > "$scratch/$module.sources"
    printf '%s\n' "$scratch/$module.swiftconstvalues" > "$scratch/$module.constants"
    # A code-generation pass is necessary: -typecheck/-emit-module alone do not
    # emit supplementary constants in the installed Swift 6.3 compiler.
    xcrun swiftc -c -whole-module-optimization -parse-as-library \
        -module-name "$module" -swift-version 6 \
        -target "$target_triple" -sdk "$sdk_root" -I "$modules_dir" \
        "${native_dependencies[@]}" \
        "${definitions[@]}" -o "$scratch/$module.o" \
        -emit-const-values -emit-const-values-path "$scratch/$module.swiftconstvalues" \
        -Xfrontend -const-gather-protocols-file -Xfrontend "$scratch/protocols.json" \
        "${sources[@]}"
    test -s "$scratch/$module.swiftconstvalues"
}

extract_metadata() {
    local module="$1"
    shift
    mkdir -p "$scratch/$module"
    xcrun appintentsmetadataprocessor \
        --output "$scratch/$module" --toolchain-dir "$toolchain_dir" \
        --module-name "$module" --sdk-root "$sdk_root" \
        --xcode-version "$xcode_version" --platform-family macOS \
        --deployment-target "$deployment_target" --target-triple "$target_triple" \
        --source-file-list "$scratch/$module.sources" \
        --swift-const-vals-list "$scratch/$module.constants" \
        --compile-time-extraction --deployment-aware-processing \
        --validate-assistant-intents "$@" 2>&1 | tee "$scratch/$module.log"
}

compile_constants WhooshSystem
extract_metadata WhooshSystem
# The processor expects the actual actionsdata file, not Metadata.appintents's
# containing directory. The dependency is statically linked by SwiftPM.
printf '%s\n' "$scratch/WhooshSystem/Metadata.appintents/extract.actionsdata" > "$scratch/static-dependencies"
compile_constants Whoosh
extract_metadata Whoosh \
    --static-metadata-file-list "$scratch/static-dependencies" \
    --binary-file "$binary" --bundle-identifier "$bundle_identifier"

python3 - "$scratch" <<'PY'
import json
import sys
from pathlib import Path

scratch = Path(sys.argv[1])
for module in ("WhooshSystem", "Whoosh"):
    log = (scratch / f"{module}.log").read_text()
    # Some processor errors still exit with status zero. Verify both diagnostics
    # and the emitted data so an unusable bundle cannot pass this build step.
    if "error:" in log.lower() or "failed to decode metadata" in log.lower():
        raise SystemExit(f"App Intents metadata extraction failed for {module}.")
    metadata = scratch / module / "Metadata.appintents"
    for name in ("version.json", "extract.actionsdata", "extract.packagedata"):
        json.loads((metadata / name).read_text())

actions = json.loads((scratch / "Whoosh/Metadata.appintents/extract.actionsdata").read_text())
required = {"OpenWhooshIntent", "ShowUpcomingMeetingsIntent", "JoinNextMeetingIntent"}
if not required.issubset(actions.get("actions", {})):
    raise SystemExit("The app metadata is missing one or more Zooom actions.")
if actions["actions"]["OpenWhooshIntent"].get("title", {}).get("key") != "Open Zooom":
    raise SystemExit("The OpenWhooshIntent metadata must display Open Zooom.")
if len(actions.get("autoShortcuts", [])) != 3:
    raise SystemExit("Zooom needs its three AppShortcut builders in the executable app target.")
open_shortcuts = [item for item in actions["autoShortcuts"] if item.get("actionIdentifier") == "OpenWhooshIntent"]
if len(open_shortcuts) != 1 or open_shortcuts[0].get("shortTitle", {}).get("key") != "Open Zooom":
    raise SystemExit("The OpenWhooshIntent shortcut must display Open Zooom.")
if not actions.get("autoShortcutProviderMangledName"):
    raise SystemExit("The app metadata has no AppShortcutsProvider.")
print("Validated 3 Zooom App Intents and 3 App Shortcuts.")
PY

mkdir -p "$resources"
rm -rf "$resources/Metadata.appintents"
cp -R "$scratch/Whoosh/Metadata.appintents" "$resources/Metadata.appintents"
