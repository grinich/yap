"""Fail packaging if managed Zoom sign-in is missing or uses the retired broker."""
import plistlib
from pathlib import Path
import sys


def validate(info):
    if info.get("YapZoomOAuthClientID") != "_Xz_EnBNS3OPtUmqZ1og3A":
        raise ValueError("Packaged Yap requires its production Zoom public client ID.")
    if info.get("YapZoomOAuthRedirectURL") != "https://auth.yap.enterprises/oauth/zoom/callback":
        raise ValueError("Packaged Yap requires its production HTTPS Zoom callback.")
    if any(key in info for key in ("YapZoomSDKClientID", "YapZoomSDKSignerURL", "YapZoomClientSecret")):
        raise ValueError("Packaged Yap must not include the retired Zoom signer configuration or a client secret.")


if __name__ == "__main__":
    with Path(sys.argv[1]).open("rb") as source:
        validate(plistlib.load(source))
