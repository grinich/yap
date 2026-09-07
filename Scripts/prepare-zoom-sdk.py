#!/usr/bin/env python3
"""Verify a privately downloaded Zoom SDK archive before extracting vendor code."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
lock = json.loads((root / "Resources/ZoomSDK.lock.json").read_text())
archive = Path(sys.argv[1]).resolve()
destination = Path(sys.argv[2]).resolve()
with archive.open("rb") as stream:
    digest = hashlib.file_digest(stream, "sha256").hexdigest()
if digest != lock["sha256"]:
    sys.exit("Zoom SDK archive checksum differs from Resources/ZoomSDK.lock.json.")
destination.mkdir(parents=True, exist_ok=True)
# Only extract after the whole vendor archive matches the reviewed checksum.
subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(destination)], check=True)
sdk = destination / lock["sdkPath"]
if not (sdk / "ZoomSDK.framework/Headers/ZoomSDK.h").is_file():
    sys.exit("Verified archive did not contain the expected Zoom SDK.")
print(sdk)
