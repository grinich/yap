#!/usr/bin/env python3
"""Trim copied runtime payloads before signing; never run against vendor sources."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

MACHO_MAGIC = {bytes.fromhex(h) for h in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca',
)}
METADATA = {'Headers', 'PrivateHeaders', 'Modules'}


def framework_metadata(path):
    parent = path.parent
    return path.name in METADATA and (
        parent.suffix == '.framework' or
        (parent.parent.name == 'Versions' and parent.parent.parent.suffix == '.framework')
    )


def files(root):
    for directory, names, filenames in os.walk(root, followlinks=False):
        for name in filenames:
            path = Path(directory) / name
            if not path.is_symlink():
                yield path


def trim(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Expected a real copied runtime directory, not a symlink.')
    before = sum(p.stat().st_size for p in files(root))
    binaries = []
    # Validate every architecture before changing the staged payload. No runtime
    # image is silently deleted if its arm64 implementation is missing.
    for path in files(root):
        with path.open('rb') as stream:
            if stream.read(4) not in MACHO_MAGIC:
                continue
        architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).split()
        if 'arm64' not in architectures:
            raise ValueError(f'Runtime image has no arm64 slice: {path}')
        binaries.append((path, architectures))
    for directory, names, filenames in os.walk(root, followlinks=False):
        for name in list(names) + filenames:
            path = Path(directory) / name
            if not framework_metadata(path):
                continue
            if path.is_symlink() or path.is_file():
                path.unlink()
            else:
                shutil.rmtree(path)
            if name in names:
                names.remove(name)
    thinned = 0
    for path, architectures in binaries:
        if architectures == ['arm64']:
            continue
        mode = path.stat().st_mode
        with tempfile.TemporaryDirectory(prefix='.yap-thin-', dir=path.parent) as directory:
            output = Path(directory) / path.name
            subprocess.run(['/usr/bin/lipo', str(path), '-thin', 'arm64', '-output', str(output)], check=True)
            if subprocess.check_output(['/usr/bin/lipo', '-archs', str(output)], text=True).split() != ['arm64']:
                raise ValueError(f'Could not verify arm64 output: {path}')
            output.chmod(mode)
            os.replace(output, path)
        thinned += 1
    after = sum(p.stat().st_size for p in files(root))
    print(f'Apple silicon runtime: {len(binaries)} images, {thinned} thinned; removed {before - after:,} bytes from {root.name}.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('copied_runtime', type=Path)
    trim(parser.parse_args().copied_runtime)
