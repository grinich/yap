#!/usr/bin/env python3
"""Verify a privately downloaded Zoom SDK archive before extracting vendor code."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

def prepare(archive, destination, lock=None, run=None):
    run = subprocess.run if run is None else run
    if lock is None:
        root = Path(__file__).resolve().parent.parent
        lock = json.loads((root / "Resources/ZoomSDK.lock.json").read_text())
    archive = Path(archive).resolve()
    destination = Path(destination).resolve()
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != lock["sha256"]:
        raise ValueError("Zoom SDK archive checksum differs from Resources/ZoomSDK.lock.json.")
    sdk = (destination / lock["sdkPath"]).resolve()
    if not sdk.is_relative_to(destination):
        raise ValueError("The pinned SDK path must remain inside the extraction directory.")
    destination.mkdir(parents=True, exist_ok=True)
    # Only extract after the whole vendor archive matches the reviewed checksum.
    run(["/usr/bin/ditto", "-x", "-k", str(archive), str(destination)], check=True)
    if not (sdk / "ZoomSDK.framework/Headers/ZoomSDK.h").is_file():
        raise ValueError("Verified archive did not contain the expected Zoom SDK.")
    return sdk


def main():
    if len(sys.argv) != 3:
        sys.exit("Usage: prepare-zoom-sdk.py ARCHIVE DESTINATION")
    try:
        print(prepare(sys.argv[1], sys.argv[2]))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
