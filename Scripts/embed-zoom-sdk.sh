#!/bin/bash
set -euo pipefail

# Match Zoom's official sample: the entire ZoomSDK directory belongs in
# Contents/Frameworks, and the supplied audio driver belongs in Contents/PlugIns.
# Copying the driver does not install it or request system-level privileges.
# Signing is inside-out; --deep is used only for verification, never signing.
# https://godevelopers.zoom.us/blog/msdk-macos-upgrade/
if [ "$#" -ne 2 ]; then
    printf 'Usage: %s /path/to/Yap.app /path/to/ZoomSDK\n' "$0" >&2
    exit 2
fi

YAP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YAP_SIGNING_IDENTITY="$(python3 "$YAP_ROOT/Scripts/resolve-signing-identity.py" "$YAP_ROOT")"
export YAP_SIGNING_IDENTITY

python3 - "$1" "$2" <<'PY'
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

app = Path(sys.argv[1]).resolve()
sdk = Path(sys.argv[2]).resolve()
signing_identity = os.environ.get("YAP_SIGNING_IDENTITY") or "-"
frameworks = app / "Contents/Frameworks"
plugins = app / "Contents/PlugIns"
if app.suffix != ".app" or not (app / "Contents/MacOS/Yap").is_file():
    raise SystemExit("A staged Yap application bundle with its Yap executable is required.")
if not (sdk / "ZoomSDK.framework/ZoomSDK").is_file():
    raise SystemExit("The linked Zoom SDK runtime is missing; check YAP_ZOOM_SDK_PATH.")
driver = sdk.parent / "Plugins/ZoomAudioDevice.driver"
if not driver.is_dir():
    raise SystemExit("The official Zoom SDK audio driver is missing from the SDK package.")
license_notice = sdk.parent / "OSS-LICENSE.pdf"
if not license_notice.is_file() or license_notice.stat().st_size == 0:
    raise SystemExit("The official Zoom SDK OSS-LICENSE.pdf notice is missing from the SDK package.")
if frameworks.exists() and any(frameworks.iterdir()):
    raise SystemExit("Embed Zoom into a fresh staging bundle to avoid mixing SDK versions.")

# ditto preserves versioned framework symlinks, resource layouts, and permissions.
# Keep the downloaded SDK and its vendor signatures untouched.
frameworks.mkdir(parents=True, exist_ok=True)
plugins.mkdir(parents=True, exist_ok=True)
subprocess.run(["/usr/bin/ditto", str(sdk), str(frameworks)], check=True)
subprocess.run(["/usr/bin/ditto", str(driver), str(plugins / driver.name)], check=True)
licenses = app / "Contents/Resources/ThirdPartyLicenses"
licenses.mkdir(parents=True, exist_ok=True)
bundled_notice = licenses / "Zoom-OSS-LICENSE.pdf"
subprocess.run(["/usr/bin/ditto", str(license_notice), str(bundled_notice)], check=True)
if bundled_notice.read_bytes() != license_notice.read_bytes():
    raise SystemExit("The bundled Zoom SDK open-source notice differs from the original.")

magic = {bytes.fromhex(h) for h in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe",
    "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}
bundle_suffixes = {".app", ".framework", ".bundle", ".driver", ".xpc"}
bundles = []
machos = []
for root in (frameworks, plugins):
    for directory, names, filenames in os.walk(root, followlinks=False):
        current = Path(directory)
        if current.suffix in bundle_suffixes:
            bundles.append(current)
        for name in filenames:
            path = current / name
            if path.is_symlink():
                continue
            with path.open("rb") as stream:
                if stream.read(4) in magic:
                    machos.append(path)

# Resolve static SDK dependencies using the same relative paths dyld uses.
# Apple system libraries may live only in the shared cache on modern macOS.
load_commands = {}
def commands(path):
    if path not in load_commands:
        load_commands[path] = subprocess.check_output(["/usr/bin/otool", "-l", str(path)], text=True)
    return load_commands[path]

def rpaths(path):
    return set(re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset", commands(path)))

def executable_for(path):
    for parent in path.parents:
        if parent.suffix == ".app":
            with (parent / "Contents/Info.plist").open("rb") as stream:
                name = plistlib.load(stream)["CFBundleExecutable"]
            return parent / "Contents/MacOS" / name
    return app / "Contents/MacOS/Yap"

def expand(value, loader, executable):
    return Path(value.replace("@loader_path", str(loader.parent)).replace("@executable_path", str(executable.parent)))

main = app / "Contents/MacOS/Yap"
# SwiftPM tests need the downloaded SDK's absolute runpath. The distributed
# executable must resolve its runtime from its own bundle, even on this Mac.
for value in rpaths(main):
    if value.startswith("/") and Path(value).resolve() == sdk:
        subprocess.run(["/usr/bin/install_name_tool", "-delete_rpath", value, str(main)], check=True)
        load_commands.pop(main, None)
if "@executable_path/../Frameworks" not in rpaths(main) and "@loader_path/../Frameworks" not in rpaths(main):
    raise SystemExit("Yap must link with an executable-relative Contents/Frameworks runpath.")
for path in [main] + machos:
    executable = executable_for(path)
    search = {expand(value, path, executable) for value in rpaths(path)}
    search.update(expand(value, executable, executable) for value in rpaths(executable))
    # A helper may load a plug-in that in turn loads private libraries. Those
    # images inherit the plug-in/framework loader's runpaths as well as the
    # process executable's paths (for example aomhost's nested zmp.bundle).
    for container in path.parents:
        if container == app:
            break
        if container.suffix not in {".bundle", ".framework"}:
            continue
        metadata = container / ("Resources/Info.plist" if container.suffix == ".framework" else "Contents/Info.plist")
        if not metadata.is_file():
            continue
        with metadata.open("rb") as stream:
            name = plistlib.load(stream).get("CFBundleExecutable")
        if not name:
            continue
        loader = (container / name if container.suffix == ".framework" else container / "Contents/MacOS" / name).resolve()
        if loader.is_file():
            search.update(expand(value, loader, executable) for value in rpaths(loader))
    # LC_ID_DYLIB describes an image's own identity; it is not a dependency.
    dependencies = re.findall(
        r"cmd LC_(?:LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LOAD_UPWARD_DYLIB|LAZY_LOAD_DYLIB)\n\s+cmdsize \d+\n\s+name (.+?) \(offset",
        commands(path),
    )
    for dependency in dependencies:
        if path == main and dependency == "@rpath/Sparkle.framework/Versions/B/Sparkle":
            # Embedded and verified separately after the Zoom-only signing pass.
            continue
        if dependency.startswith(("/System/Library/", "/usr/lib/")):
            continue
        if dependency.startswith("@rpath/"):
            candidates = [base / dependency[len("@rpath/"):] for base in search]
        else:
            candidates = [expand(dependency, path, executable)]
        if not any(candidate.exists() or str(candidate).startswith("/usr/lib/swift/") for candidate in candidates):
            raise SystemExit(f"Unresolved runtime dependency in {path.relative_to(app)}: {dependency}")

# Bundle signing signs its main executable too. Sign other Mach-O images first,
# and then nested containers before their parents so resource seals stay valid.
bundle_executables = set()
for bundle in bundles:
    info = bundle / ("Resources/Info.plist" if bundle.suffix == ".framework" else "Contents/Info.plist")
    if not info.exists():
        raise SystemExit(f"Missing bundle metadata: {bundle.relative_to(app)}")
    with info.open("rb") as stream:
        name = plistlib.load(stream).get("CFBundleExecutable")
    if name:
        executable = bundle / name if bundle.suffix == ".framework" else bundle / "Contents/MacOS" / name
        if not executable.is_file():
            # Zoom's two resource-only bundles declare a historical executable
            # name but ship no binary. codesign signs their resource envelopes.
            if bundle.name in {"zMacRes.bundle", "RingtoneRes.bundle"}:
                continue
            raise SystemExit(f"Missing bundle executable: {bundle.relative_to(app)}")
        bundle_executables.add(executable.resolve())

targets = bundles + [path for path in machos if path.resolve() not in bundle_executables]
targets.sort(key=lambda path: (-len(path.parts), str(path)))
with tempfile.TemporaryDirectory(prefix="yap-zoom-sign-") as temporary:
    for index, target in enumerate(targets):
        command = ["/usr/bin/codesign", "--force", "--sign", signing_identity, "--options", "runtime"]
        if target.suffix == ".app":
            # Ad-hoc and personal self-signed identities have no Apple Team ID.
            # Keep the SDK's existing library-validation exceptions unchanged.
            entitlements = {"com.apple.security.cs.disable-library-validation": True}
            if target.name != "capHost.app":
                entitlements.update({
                    "com.apple.security.device.camera": True,
                    "com.apple.security.device.audio-input": True,
                })
            if target.name in {"airhost.app", "CptHost.app"}:
                entitlements["com.apple.security.automation.apple-events"] = True
            if target.name == "aomhost.app":
                entitlements.update({
                    "com.apple.security.cs.allow-jit": True,
                    "com.apple.security.cs.allow-unsigned-executable-memory": True,
                })
            entitlement_file = Path(temporary) / f"helper-{index}.plist"
            entitlement_file.write_bytes(plistlib.dumps(entitlements))
            command.extend(["--entitlements", str(entitlement_file)])
        command.append(str(target))
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            raise SystemExit(f"Signing failed for {target.relative_to(app)}:\n{result.stderr}")
    for target in targets:
        result = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(target)], capture_output=True, text=True)
        if result.returncode:
            raise SystemExit(f"Signature verification failed for {target.relative_to(app)}:\n{result.stderr}")

print(f"Embedded Zoom SDK: {len(machos)} Mach-O images; nested signatures and runtime paths verified.")
PY
