#!/usr/bin/env python3
"""Inject public update configuration into the staged bundle before code signing."""
import base64
import os
from pathlib import Path
import plistlib
import sys
from urllib.parse import urlsplit


def configure(info, env):
    feed = env.get("ZOOOM_UPDATE_FEED_URL", "")
    key = env.get("ZOOOM_UPDATE_PUBLIC_KEY", "")
    if not feed and not key:
        if env.get("ZOOOM_RELEASE") == "1":
            raise ValueError("Release builds require ZOOOM_UPDATE_FEED_URL and ZOOOM_UPDATE_PUBLIC_KEY.")
        return info
    url = urlsplit(feed)
    if url.scheme != "https" or not url.hostname or url.username or url.password:
        raise ValueError("Update feed must be an HTTPS URL without credentials.")
    try:
        valid_key = len(base64.b64decode(key, validate=True)) == 32
    except ValueError:
        valid_key = False
    if not valid_key:
        raise ValueError("ZOOOM_UPDATE_PUBLIC_KEY must contain a base64 Ed25519 public key (32 bytes).")
    return {**info, "SUFeedURL": feed, "SUPublicEDKey": key,
            "SUEnableAutomaticChecks": True, "SUAutomaticallyUpdate": True, "SURequireSignedFeed": True,
            "SUScheduledCheckInterval": 21600, "SUSendProfileInfo": False}


if __name__ == "__main__":
    try:
        path = Path(sys.argv[1])
        info = configure(plistlib.loads(path.read_bytes()), os.environ)
        path.write_bytes(plistlib.dumps(info, sort_keys=False))
    except (ValueError, IndexError) as error:
        sys.exit(str(error))
