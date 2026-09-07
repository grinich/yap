#!/usr/bin/env python3
"""Download the pinned SDK asset only from an explicitly private dependency repo."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def download(archive, env=None, run=None):
    env = os.environ if env is None else env
    run = subprocess.run if run is None else run
    repository = env.get("ZOOM_SDK_REPOSITORY", "")
    asset_id = env.get("ZOOM_SDK_ASSET_ID", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Set ZOOM_SDK_REPOSITORY to the private dependency repository (owner/name).")
    if repository.casefold() in {
        env.get("GITHUB_REPOSITORY", "").casefold(),
        env.get("ZOOOM_RELEASE_REPOSITORY", "").casefold(),
    }:
        raise ValueError("The SDK dependency repository must be separate from the source and distribution repositories.")
    if not re.fullmatch(r"[1-9][0-9]*", asset_id):
        raise ValueError("Set ZOOM_SDK_ASSET_ID to the private SDK release asset's numeric ID.")
    if not env.get("GH_TOKEN", "").strip():
        raise ValueError("Set ZOOM_SDK_READ_TOKEN; the workflow passes this dependency-only read token as GH_TOKEN.")

    # The workflow gives this process only the dependency repo's read token.
    # Never fetch asset bytes unless GitHub confirms the exact repo is private;
    # unknown/internal/public visibility and failed lookups all fail closed.
    result = run(["gh", "api", f"repos/{repository}"], check=True, capture_output=True, text=True, env=dict(env))
    metadata = json.loads(result.stdout)
    if not isinstance(metadata, dict) or metadata.get("private") is not True or metadata.get("visibility") != "private":
        raise ValueError("Refusing to download the Zoom SDK: its dependency repository is not explicitly private.")
    if str(metadata.get("full_name", "")).casefold() != repository.casefold():
        raise ValueError("The SDK repository lookup returned a different repository; update ZOOM_SDK_REPOSITORY.")

    archive = Path(archive)
    archive.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        # A failed download never replaces a previously verified archive.
        with tempfile.NamedTemporaryFile(prefix=".zoom-sdk-", suffix=".zip", dir=archive.parent, delete=False) as stream:
            temporary = Path(stream.name)
            run(["gh", "api", f"repos/{repository}/releases/assets/{asset_id}",
                 "-H", "Accept: application/octet-stream"], check=True, stdout=stream, env=dict(env))
        temporary.replace(archive)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    if len(sys.argv) != 2:
        sys.exit("Usage: download-zoom-sdk.py OUTPUT_ARCHIVE")
    try:
        download(sys.argv[1])
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            sys.exit("Could not access the private Zoom SDK dependency. Check ZOOM_SDK_READ_TOKEN, repository, and asset ID.")
        sys.exit(str(error))


if __name__ == "__main__":
    main()
