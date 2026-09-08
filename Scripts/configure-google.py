#!/usr/bin/env python3
"""Bundle Google's desktop OAuth client before signing, without logging credentials.

Desktop clients are public clients: the bundled client_secret cannot be confidential.
User access/refresh tokens remain in Keychain and never enter the build pipeline.
"""
import os
from pathlib import Path
import plistlib
import re
import sys


def configure(info, env):
    info = {key: value for key, value in info.items()
            if key not in ("YapGoogleClientID", "YapGoogleClientSecret")}
    client_id = env.get("YAP_GOOGLE_CLIENT_ID", "").strip()
    secret = env.get("YAP_GOOGLE_CLIENT_SECRET", "").strip()
    if not client_id and not secret:
        if env.get("YAP_RELEASE") == "1":
            raise ValueError("Release builds require the Yap Google desktop OAuth client configuration.")
        return info
    if not re.fullmatch(r"[A-Za-z0-9_-]+\.apps\.googleusercontent\.com", client_id):
        raise ValueError("YAP_GOOGLE_CLIENT_ID must be a Google desktop OAuth client ID.")
    if not secret or any(character.isspace() for character in secret):
        raise ValueError("YAP_GOOGLE_CLIENT_SECRET must contain the matching desktop client secret.")
    return {**info, "YapGoogleClientID": client_id, "YapGoogleClientSecret": secret}


if __name__ == "__main__":
    try:
        path = Path(sys.argv[1])
        path.write_bytes(plistlib.dumps(configure(plistlib.loads(path.read_bytes()), os.environ), sort_keys=False))
    except (ValueError, IndexError) as error:
        sys.exit(str(error))
