#!/usr/bin/env python3
"""Require stable version tags and strictly increasing Sparkle build numbers."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

current = plistlib.loads(Path("Resources/Info.plist").read_bytes())
version = current["CFBundleShortVersionString"]
build = current["CFBundleVersion"]
if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[1-9]\d*", build):
    sys.exit("Stable releases need a numeric x.y.z version and positive integer CFBundleVersion.")
tags = subprocess.check_output(["git", "tag", "--list", "v*"], text=True).splitlines()
for tag in tags:
    if tag == f"v{version}" or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        continue
    previous = plistlib.loads(subprocess.check_output(["git", "show", f"{tag}:Resources/Info.plist"]))
    if int(previous["CFBundleVersion"]) >= int(build):
        sys.exit(f"CFBundleVersion must be larger than the build in {tag}.")
    if tuple(map(int, tag[1:].split('.'))) >= tuple(map(int, version.split('.'))):
        sys.exit(f"Release version must be newer than {tag}.")
print(f"Release version {version} (build {build}) is valid.")
