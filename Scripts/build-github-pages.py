#!/usr/bin/env python3
"""Publish only the existing allowlisted review pages under Yap's GitHub Pages path."""
import argparse
import importlib.util
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SITE_URL = 'https://grinich.github.io/yap'
spec = importlib.util.spec_from_file_location('review_site', ROOT / 'Scripts/build-review-site.py')
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)


def build_files():
    files = site.build_files()  # Validates every source link before rebasing.
    verification = (ROOT / 'Resources/GoogleSiteVerification.txt').read_text().strip()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', verification):
        raise ValueError('Invalid public Google site-verification tag')
    result = {}
    for name, data in files.items():
        if name == '_headers':
            continue  # GitHub Pages does not interpret Worker header configuration.
        if name.endswith('.html'):
            text = data.decode().replace(site.CANONICAL_URL, SITE_URL)
            text = re.sub(r'\b(href|src)="/(?!/)', lambda match: match[1] + '="' + SITE_URL + '/', text)
            if name == 'index.html':
                text = text.replace('</head>', f'<meta name="google-site-verification" content="{verification}">\n</head>', 1)
            data = text.encode()
        elif name in ('robots.txt', 'sitemap.xml'):
            data = data.replace(site.CANONICAL_URL.encode(), SITE_URL.encode())
        result[name] = data
    result['.nojekyll'] = b''
    # Check every rebased page/image target still belongs to the allowed output.
    for name, data in result.items():
        if not name.endswith('.html'): continue
        parser = site.PageLinks()
        parser.feed(data.decode())
        for link in parser.links:
            if not link.startswith(SITE_URL + '/'): continue
            path = link[len(SITE_URL) + 1:].split('#')[0].split('?')[0]
            if not path or path.endswith('/'): path += 'index.html'
            if path not in result:
                raise ValueError(f'Broken GitHub Pages link: {name} -> {link}')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    files = build_files()
    if args.output.exists() and any(args.output.iterdir()):
        raise SystemExit('Use an empty output directory to exclude unrelated files.')
    for name, data in files.items():
        path = args.output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    print(f'Built {len(files)} allowlisted files for {SITE_URL}/')
