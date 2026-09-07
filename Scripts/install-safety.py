#!/usr/bin/env python3
"""Read-only running-app guard for current and legacy installed app bundles."""
from pathlib import Path
import re
import subprocess
import sys


# These names are compatibility checks, not names for a new bundle or process.
EXECUTABLE_NAMES = ("Yap", "Whoosh", "Zooom")
BUNDLE_NAMES = ("Yap.app", "Zooom.app", "Whoosh.app")


def require_stopped(parent: Path, run=subprocess.run) -> None:
    prefixes = tuple(str(parent.absolute() / name) + "/" for name in BUNDLE_NAMES)
    for name in EXECUTABLE_NAMES:
        result = run(["/usr/bin/pgrep", "-x", name], capture_output=True, text=True)
        if result.returncode == 1:
            continue
        if result.returncode != 0:
            raise ValueError("Could not check whether the app is running; refusing installation.")
        pids = result.stdout.split()
        if not pids or any(re.fullmatch(r"[0-9]+", pid) is None for pid in pids):
            raise ValueError("Could not identify running apps; refusing installation.")
        for pid in pids:
            process = run(["/bin/ps", "-p", pid, "-o", "comm="], capture_output=True, text=True)
            if process.returncode != 0 or not process.stdout.strip():
                raise ValueError("Could not inspect a running app. Retry the update.")
            if process.stdout.strip().startswith(prefixes):
                raise ValueError("Quit the installed Yap and any legacy Zooom or Whoosh app before installing or updating.")


if __name__ == "__main__":
    try:
        require_stopped(Path(sys.argv[1]))
    except (ValueError, IndexError) as error:
        sys.exit(str(error))
