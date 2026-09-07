#!/usr/bin/env python3
"""Resolve public signing configuration without reading Keychain or creating keys."""
import json
import os
from pathlib import Path
import re
import sys


def resolve(root: Path, environment: dict[str, str]) -> str:
    if "YAP_SIGNING_IDENTITY" in environment:
        value = environment["YAP_SIGNING_IDENTITY"].strip()
        if not value or "\n" in value or "\r" in value:
            raise ValueError("YAP_SIGNING_IDENTITY must name an identity, its fingerprint, or explicit '-'.")
        return value
    local = root / "signing.local.json"
    if not local.exists():
        return "-"
    try:
        configuration = json.loads(local.read_text())
    except (OSError, ValueError) as error:
        raise ValueError("Cannot read signing.local.json; refusing ad-hoc fallback.") from error
    fingerprint = configuration.get("certificateSHA1") if isinstance(configuration, dict) else None
    if not isinstance(fingerprint, str) or re.fullmatch(r"[0-9a-fA-F]{40}", fingerprint) is None:
        raise ValueError("signing.local.json requires one exact 40-digit certificateSHA1; refusing ad-hoc fallback.")
    return fingerprint.upper()


if __name__ == "__main__":
    try:
        print(resolve(Path(sys.argv[1]), dict(os.environ)))
    except (ValueError, IndexError) as error:
        sys.exit(str(error))
