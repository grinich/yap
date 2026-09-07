#!/usr/bin/env python3
"""Fail publication if the generated feed is unsigned, incomplete, or misdirected."""
import base64
import os
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def validate(feed, archive, info, repository):
    item = ET.fromstring(feed).find("channel/item")
    if item is None:
        raise ValueError("The appcast has no release item.")
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("The appcast has no update download.")
    signature = enclosure.get(SPARKLE + "edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("The update archive is missing its Ed25519 signature (check the key pair).")
    expected = f"https://github.com/{repository}/releases/download/v{info['CFBundleShortVersionString']}/{archive.name}"
    if enclosure.get("url") != expected or enclosure.get("length") != str(archive.stat().st_size):
        raise ValueError("The appcast download URL or archive size is incorrect.")
    if item.findtext(SPARKLE + "version") != info["CFBundleVersion"]:
        raise ValueError("The appcast build version differs from the app bundle.")
    if item.findtext(SPARKLE + "minimumSystemVersion") != info["LSMinimumSystemVersion"]:
        raise ValueError("The appcast minimum macOS version is incorrect.")


if __name__ == "__main__":
    try:
        validate(Path(sys.argv[1]).read_bytes(), Path(sys.argv[2]),
                 plistlib.loads(Path(sys.argv[3]).read_bytes()), os.environ["ZOOOM_RELEASE_REPOSITORY"])
    except (ValueError, KeyError, ET.ParseError) as error:
        sys.exit(str(error))
