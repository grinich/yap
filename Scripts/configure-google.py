#!/usr/bin/env python3
"""Bundle Yap's one public desktop OAuth client in every build, without logging it.

An installed-app client secret is public application configuration. User access and
refresh tokens remain in Keychain and must never enter this file or build pipeline.
"""
import os
from pathlib import Path
import plistlib
import re
import sys

CONFIGURATION = Path(__file__).resolve().parents[1] / "Sources/YapCalendar/Resources/GoogleOAuth.plist"


def configure(info, env, configuration_path=CONFIGURATION):
    try:
        client = plistlib.loads(Path(configuration_path).read_bytes())
    except (OSError, ValueError) as error:
        raise ValueError("Yap's checked-in Google OAuth configuration is missing or invalid.") from error
    client_id = client.get("YapGoogleClientID", "")
    secret = client.get("YapGoogleClientSecret", "")
    if not isinstance(client_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]+\.apps\.googleusercontent\.com", client_id):
        raise ValueError("Yap's Google desktop OAuth client ID is invalid.")
    if not isinstance(secret, str) or not secret or any(c.isspace() for c in secret):
        raise ValueError("Yap's Google desktop client secret is missing or invalid.")
    # Older build wrappers may still pass the same values. Never allow them to
    # substitute another Google app or make local builds omit the shared client.
    for key, expected in [("YAP_GOOGLE_CLIENT_ID", client_id), ("YAP_GOOGLE_CLIENT_SECRET", secret)]:
        if key in env and env[key] != expected:
            raise ValueError("Google OAuth overrides must match Yap's checked-in client configuration.")
    return {**info, "YapGoogleClientID": client_id, "YapGoogleClientSecret": secret}


if __name__ == "__main__":
    try:
        path = Path(sys.argv[1])
        result = configure(plistlib.loads(path.read_bytes()), os.environ)
        if len(sys.argv) == 3 and sys.argv[2] == "--verify":
            if plistlib.loads(path.read_bytes()) != result:
                raise ValueError("The packaged app does not contain Yap's Google OAuth client.")
            resource = path.parent / "Resources/GoogleOAuth.plist"
            if resource.read_bytes() != CONFIGURATION.read_bytes():
                raise ValueError("The packaged app is missing Yap's canonical Google OAuth resource.")
        else:
            path.write_bytes(plistlib.dumps(result, sort_keys=False))
    except (ValueError, OSError, IndexError) as error:
        sys.exit(str(error))
