#!/usr/bin/env python3
"""Publish only the existing allowlisted review pages on Yap's GitHub Pages custom domain."""
import argparse
import hashlib
import html
import importlib.util
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SITE_URL = 'https://yap.enterprises'
spec = importlib.util.spec_from_file_location('review_site', ROOT / 'Scripts/build-review-site.py')
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)


def google_completion_files():
    """Static receipt pages. No OAuth parameters or account data reach this renderer."""
    css = (ROOT / 'Services/zoom-auth/site/google-completion.css').read_bytes()
    css_hash = hashlib.sha256(css).hexdigest()[:12]
    files = {'assets/google-completion.css': css}
    outcomes = {
        'received': ('Ready to yap.', 'Sign-in received',
                     'Your Google sign-in has reached Yap. Return to the app to finish connecting your calendar.'),
        'cancelled': ('Maybe next time.', 'Sign-in cancelled',
                      'Google Calendar wasn’t connected. You can return to Yap and try again whenever you’re ready.'),
        'error': ('Let’s try that again.', 'Connection not completed',
                  'We couldn’t verify this sign-in. Return to Yap and start a new connection.'),
    }
    for outcome, (title, status, detail) in outcomes.items():
        files[f'connect/google/{outcome}/index.html'] = f'''<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer"><meta name="robots" content="noindex, nofollow">
<meta name="color-scheme" content="light dark">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'">
<title>{html.escape(title)} — Yap</title>
<link rel="icon" href="{SITE_URL}/assets/icon.png" type="image/png">
<link rel="stylesheet" href="{SITE_URL}/assets/google-completion.css?v={css_hash}">
</head><body><main>
<img class="app-icon" src="{SITE_URL}/assets/icon.png" width="112" height="112" alt="Yap">
<p class="wordmark">Yap</p>
<p class="status" data-outcome="{outcome}">{html.escape(status)}</p>
<h1>{html.escape(title)}</h1>
<p class="detail">{html.escape(detail)}</p>
<a class="open-app" href="yap://open" rel="noreferrer">Open Yap <span aria-hidden="true">→</span></a>
<p class="hint">You can close this tab.</p>
<footer>For people who professionally yap for a living.</footer>
</main></body></html>'''.encode()
    return files


def build_files():
    files = site.build_files()  # Validates every source link before rebasing.
    verifications = (ROOT / 'Resources/GoogleSiteVerification.txt').read_text().splitlines()
    if not verifications or any(not re.fullmatch(r'[A-Za-z0-9_-]+', token) for token in verifications):
        raise ValueError('Invalid public Google site-verification tag')
    result = {}
    for name, data in files.items():
        if name == '_headers':
            continue  # GitHub Pages does not interpret Worker header configuration.
        if name.endswith('.html'):
            text = data.decode().replace(site.CANONICAL_URL, SITE_URL)
            text = re.sub(r'\b(href|src)="/(?!/)', lambda match: match[1] + '="' + SITE_URL + '/', text)
            if name == 'index.html':
                tags = ''.join(f'<meta name="google-site-verification" content="{token}">\n' for token in verifications)
                text = text.replace('</head>', tags + '</head>', 1)
            data = text.encode()
        elif name in ('robots.txt', 'sitemap.xml'):
            data = data.replace(site.CANONICAL_URL.encode(), SITE_URL.encode())
        result[name] = data
    result['.nojekyll'] = b''
    result.update(google_completion_files())
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
