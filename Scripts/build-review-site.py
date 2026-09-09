#!/usr/bin/env python3
"""Build the static review site from allowlisted source documents, using only stdlib.

The renderer deliberately supports the Markdown subset used by these documents:
headings, paragraphs, links/images, emphasis, code, blockquotes, lists and tables.
Raw HTML is escaped. No remote resources are fetched or copied into the site.
"""
from __future__ import annotations

import argparse
import hashlib
import html
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from urllib.parse import quote, unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SERVICE = Path("Services/zoom-auth")
REPOSITORY = "https://github.com/grinich/yap"
CANONICAL_URL = "http://127.0.0.1:8000"
ROUTES = {"README.md": "/", "PRIVACY.md": "/privacy/", "TERMS.md": "/terms/",
          "THIRD_PARTY_NOTICES.md": "/notices/", str(SERVICE / "site/guide.md"): "/guide/"}
ASSETS = {"Resources/YapIcon.png": "assets/icon.png",
          "Documentation/Images/meeting-gallery.png": "assets/meeting-gallery.png",
          "Documentation/Images/recordings.png": "assets/recordings.png",
          "Documentation/Images/agenda.png": "assets/agenda.png"}
TOKEN = re.compile(r"`([^`\n]+)`|(!?)\[([^\]\n]+)\]\(([^\s)]+)\)|\*\*([^*\n]+)\*\*|(?<!\*)\*([^*\n]+)\*(?!\*)")


def slug(value: str) -> str:
    value = re.sub(r"[^\w\s-]", "", value.lower())
    return re.sub(r"\s+", "-", value).strip("-") or "section"


def destination(value: str, source: str, image: bool = False) -> str:
    parsed = urlsplit(html.unescape(value))
    if parsed.scheme:
        if image or parsed.scheme not in {"https", "mailto"} or parsed.username or parsed.password:
            raise ValueError(f"Unsupported link in {source}")
        return value
    if parsed.netloc or "\\" in value:
        raise ValueError(f"Unsupported link in {source}")
    if value.startswith(("/", "#")):
        if image and not value.startswith("/assets/"):
            raise ValueError("Images must be allowlisted local assets")
        return value
    resolved = (ROOT / source).parent.joinpath(unquote(parsed.path)).resolve()
    try:
        relative = str(resolved.relative_to(ROOT))
    except ValueError as error:
        raise ValueError(f"Link escapes repository in {source}") from error
    if image:
        if relative not in ASSETS:
            raise ValueError(f"Image is not allowlisted: {relative}")
        return "/" + ASSETS[relative]
    if not resolved.is_file():
        raise ValueError(f"Source link does not exist: {relative}")
    suffix = ("?" + parsed.query if parsed.query else "") + ("#" + parsed.fragment if parsed.fragment else "")
    return ROUTES.get(relative, REPOSITORY + "/blob/main/" + quote(relative)) + suffix


class Markdown:
    def __init__(self, source: str):
        self.source = source
        self.headings: list[tuple[str, str]] = []
        self.ids: dict[str, int] = {}

    def inline(self, text: str) -> str:
        result, position = [], 0
        for match in TOKEN.finditer(text):
            result.append(html.escape(text[position:match.start()]))
            code, image, label, target, strong, emphasis = match.groups()
            if code is not None:
                result.append("<code>" + html.escape(code) + "</code>")
            elif target is not None:
                url = html.escape(destination(target, self.source, bool(image)), quote=True)
                if image:
                    result.append(f'<figure><img src="{url}" alt="{html.escape(label, quote=True)}" loading="lazy" decoding="async"></figure>')
                else:
                    result.append(f'<a href="{url}">{self.inline(label)}</a>')
            elif strong is not None:
                result.append("<strong>" + self.inline(strong) + "</strong>")
            else:
                result.append("<em>" + self.inline(emphasis) + "</em>")
            position = match.end()
        result.append(html.escape(text[position:]))
        return "".join(result)

    def render(self, text: str, omit_title: bool = False) -> str:
        lines, output, index = text.strip().splitlines(), [], 0
        while index < len(lines):
            line = lines[index].strip()
            if not line:
                index += 1
                continue
            heading = re.match(r"^(#{1,6})\s+(.+)$", line)
            if heading:
                level, title = len(heading[1]), heading[2]
                if not (level == 1 and omit_title):
                    key = slug(title)
                    count = self.ids.get(key, 0)
                    self.ids[key] = count + 1
                    identifier = key + (f"-{count}" if count else "")
                    output.append(f'<h{level} id="{identifier}">{self.inline(title)}</h{level}>')
                    if level == 2:
                        self.headings.append((identifier, title))
                index += 1
                continue
            if line.startswith("```"):
                language, code = line[3:], []
                index += 1
                while index < len(lines) and not lines[index].strip().startswith("```"):
                    code.append(lines[index])
                    index += 1
                if index == len(lines):
                    raise ValueError(f"Unclosed code fence in {self.source}")
                output.append('<pre><code>' + html.escape("\n".join(code)) + '</code></pre>')
                index += 1
                continue
            if line.startswith(">"):
                quote_lines = []
                while index < len(lines) and lines[index].lstrip().startswith(">"):
                    quote_lines.append(re.sub(r"^\s*> ?", "", lines[index]))
                    index += 1
                output.append("<blockquote>" + self.render("\n".join(quote_lines)) + "</blockquote>")
                continue
            if line.startswith("|") and index + 1 < len(lines) and re.fullmatch(r"[|:\s-]+", lines[index + 1]):
                rows = []
                while index < len(lines) and lines[index].strip().startswith("|"):
                    if not re.fullmatch(r"[|:\s-]+", lines[index]):
                        rows.append([cell.strip() for cell in lines[index].strip().strip("|").split("|")])
                    index += 1
                output.append('<div class="table-wrap"><table><thead><tr>' + "".join("<th scope=\"col\">" + self.inline(cell) + "</th>" for cell in rows[0]) + "</tr></thead><tbody>")
                for row in rows[1:]:
                    if len(row) != len(rows[0]):
                        raise ValueError(f"Uneven table in {self.source}")
                    output.append("<tr>" + "".join("<td>" + self.inline(cell) + "</td>" for cell in row) + "</tr>")
                output.append("</tbody></table></div>")
                continue
            item = re.match(r"^([-*]|\d+\.)\s+(.+)$", line)
            if item:
                ordered = item[1][0].isdigit()
                tag = "ol" if ordered else "ul"
                output.append(f"<{tag}>")
                while index < len(lines):
                    item = re.match(r"^([-*]|\d+\.)\s+(.+)$", lines[index].strip())
                    if not item or item[1][0].isdigit() != ordered:
                        break
                    output.append("<li>" + self.inline(item[2]) + "</li>")
                    index += 1
                output.append(f"</{tag}>")
                continue
            paragraph = [line]
            index += 1
            while index < len(lines) and lines[index].strip() and not re.match(r"^(#{1,6}\s|[-*]\s|\d+\.\s|```|>|\|)", lines[index].strip()):
                paragraph.append(lines[index].strip())
                index += 1
            value = self.inline(" ".join(paragraph))
            output.append(value if value.startswith("<figure>") and value.endswith("</figure>") else "<p>" + value + "</p>")
        return "\n".join(output)


def section(markdown: str, title: str) -> str:
    match = re.search(r"^## " + re.escape(title) + r"\s*\n(.*?)(?=^## |\Z)", markdown, re.M | re.S)
    if not match:
        raise ValueError(f"README section missing: {title}")
    return match[1].strip()


def shell(brand: str, title: str, description: str, body: str, route: str, css_hash: str) -> str:
    def nav(label: str, href: str) -> str:
        current = ' aria-current="page"' if route == href else ""
        return f'<a href="{href}"{current}>{label}</a>'
    canonical = f'<link rel="canonical" href="{CANONICAL_URL}{route}">' if route != "/404.html" else '<meta name="robots" content="noindex">'
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)} · {html.escape(brand)}</title>
<meta name="description" content="{html.escape(description, quote=True)}"><meta name="referrer" content="no-referrer">
{canonical}<meta property="og:title" content="{html.escape(brand + ' · ' + title, quote=True)}"><meta property="og:description" content="{html.escape(description, quote=True)}"><meta property="og:image" content="{CANONICAL_URL}/assets/meeting-gallery.png"><meta property="og:type" content="website">
<link rel="icon" href="/assets/icon.png" type="image/png"><link rel="stylesheet" href="/assets/site.css?v={css_hash}">
</head><body><a class="skip" href="#main">Skip to content</a>
<header class="site-header"><div class="shell topbar"><a class="brand" href="/" aria-label="{html.escape(brand, quote=True)} home"><img src="/assets/icon.png" alt="" width="42" height="42">{html.escape(brand)}</a><nav class="nav" aria-label="Main">{nav("Guide", "/guide/")}{nav("Support", "/support/")}<a href="{REPOSITORY}">Source ↗</a></nav></div></header>
<main id="main" class="shell">{body}</main>
<footer class="site-footer"><div class="shell"><div class="footer-top"><span>{html.escape(brand)} · An independent Mac app</span><nav class="footer-links" aria-label="Legal and project">{nav("Privacy", "/privacy/")}{nav("Terms", "/terms/")}{nav("Notices", "/notices/")}<a href="{REPOSITORY}">GitHub</a></nav></div><p>Independent of Zoom, Google, and Apple. Screenshots show the native interface with fictional participants, sample meetings, and an original sample recording. This site uses no analytics, external fonts, or tracking scripts.</p></div></footer></body></html>
'''


def document(brand: str, title: str, description: str, text: str, source: str, route: str, css_hash: str) -> str:
    renderer = Markdown(source)
    body = renderer.render(text, omit_title=True)
    toc = ''.join(f'<a href="#{identifier}">{html.escape(label)}</a>' for identifier, label in renderer.headings)
    content = f'<header class="page-title"><span class="eyebrow">{html.escape(brand)} / {html.escape(title)}</span><h1>{html.escape(title)}</h1><p>{html.escape(description)}</p></header><div class="document"><nav class="toc" aria-label="On this page"><div class="toc-label">On this page</div>{toc}</nav><article class="markdown">{body}<p class="source-note">Published from the project’s <a href="{REPOSITORY}/blob/main/{quote(source)}">source document</a>.</p></article></div>'
    return shell(brand, title, description, content, route, css_hash)


class PageLinks(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links, self.ids, self.h1s = [], set(), 0

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag in {"script", "iframe", "object", "embed", "form"}:
            raise ValueError(f"Unexpected active element: {tag}")
        if any(key.startswith("on") for key in values):
            raise ValueError("Unexpected event handler")
        if "id" in values:
            if values["id"] in self.ids:
                raise ValueError("Duplicate HTML anchor")
            self.ids.add(values["id"])
        if tag == "h1":
            self.h1s += 1
        for key in ("href", "src"):
            if key in values:
                self.links.append(values[key])
        if tag == "img" and "alt" not in values:
            raise ValueError("Missing image alt text")


def validate(files: dict[str, bytes]) -> None:
    pages = {}
    for path, data in files.items():
        if path.endswith(".html"):
            page = PageLinks()
            page.feed(data.decode("utf-8"))
            if page.h1s != 1:
                raise ValueError(f"Expected one page heading: {path}")
            pages[path] = page
    for path, page in pages.items():
        for link in page.links:
            target = urlsplit(link)
            if target.scheme in {"https", "mailto"} or (target.scheme == "http" and target.netloc == "127.0.0.1:8000"):
                continue
            if target.scheme or target.netloc:
                raise ValueError(f"Unexpected external URL in {path}")
            local = unquote(target.path).lstrip("/") if target.path else path
            if local.endswith("/") or not local:
                local += "index.html"
            if local not in files:
                raise ValueError(f"Broken local link: {path} -> {link}")
            if target.fragment and local in pages and target.fragment not in pages[local].ids:
                raise ValueError(f"Broken local anchor: {path} -> {link}")


def build_files(root: Path = ROOT) -> dict[str, bytes]:
    readme = (root / "README.md").read_text()
    name = re.search(r'<h1[^>]*>([^<]+)</h1>', readme)
    if not name:
        raise ValueError("README must name the product in its h1")
    brand = html.unescape(name[1])
    css = (root / SERVICE / "site/site.css").read_bytes()
    css_hash = hashlib.sha256(css).hexdigest()[:12]
    files = {"assets/site.css": css}
    for source, target in ASSETS.items():
        files[target] = (root / source).read_bytes()
    tagline = re.search(r'<p align="center"><strong>(.*?)</strong></p>', readme)
    deck = re.search(r'<p align="center">([^<]+)</p>', readme)
    status = re.search(r'^> (.+)$', readme, re.M)
    if not (tagline and deck and status):
        raise ValueError("README introduction or preview status is missing")
    renderer = Markdown("README.md")
    recording_section = section(readme, "Pick up where the meeting left off")
    agenda_section = section(readme, "Less between you and your next meeting")
    meeting_section = section(readme, "A meeting window that feels like a Mac app")
    shortcuts = section(readme, "A few keys worth knowing")
    try_section = section(readme, "Try " + brand).split("\n\n", 1)[0]
    content = f'''<section class="hero"><h1>{renderer.inline(tagline[1])}</h1><p class="deck">{renderer.inline(deck[1])}</p><div class="actions"><a class="button" href="{REPOSITORY}/releases/latest/download/Yap.dmg"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5"/></svg>Download {html.escape(brand)}</a><a class="button secondary" href="{REPOSITORY}">Explore the source ↗</a></div><p class="requirements">For Apple silicon · macOS 26 or newer</p></section>
<figure><div class="showcase"><img src="/assets/meeting-gallery.png" alt="{html.escape(brand, quote=True)} meeting gallery with four fictional participants and native meeting controls" width="2624" height="1784" fetchpriority="high"></div><figcaption>The native meeting interface, shown with fictional participants. Keep people in view and meeting controls close.</figcaption></figure>
<aside class="status" aria-label="Release status">{renderer.render(status[1])}</aside>
<section class="section meeting-copy"><h2>A meeting window that feels like a Mac app</h2>{renderer.render(meeting_section)}</section>
<section class="section features"><h2>Pick up where the meeting left off</h2>{renderer.render(recording_section)}</section>
<section class="section agenda"><h2>Less between you and your next meeting</h2>{renderer.render(agenda_section)}</section>
<section class="section shortcut-area"><h2>A few keys worth knowing</h2><div class="markdown">{renderer.render(shortcuts)}</div></section>
<section class="source-card"><h2>Try {html.escape(brand)}</h2>{renderer.render(try_section)}<div class="actions"><a class="button" href="{REPOSITORY}#try-{slug(brand)}">Installation and setup ↗</a><a class="button secondary" href="/support/">Get in touch</a></div></section>'''
    files["index.html"] = shell(brand, tagline[1], deck[1], content, "/", css_hash).encode()
    documents = [("privacy", "Privacy", "How the app and its authorization service handle your data.", "PRIVACY.md"),
                 ("terms", "Terms for the free preview", "The terms and current publication status of the preview.", "TERMS.md"),
                 ("notices", "Third-party notices", "The components and licenses behind the app.", "THIRD_PARTY_NOTICES.md")]
    for route, title, description, source in documents:
        files[f"{route}/index.html"] = document(brand, title, description, (root / source).read_text(), source, f"/{route}/", css_hash).encode()
    guide_source = str(SERVICE / "site/guide.md")
    guide = (root / guide_source).read_text().replace("{{brand}}", brand).replace("{{shortcuts}}", shortcuts)
    files["guide/index.html"] = document(brand, "User guide", "Connect your account, join a meeting, and find your way through recordings.", guide, guide_source, "/guide/", css_hash).encode()
    privacy = (root / "PRIVACY.md").read_text()
    email = re.search(r'\[([^\]]+)\]\((mailto:[^)]+)\)', privacy)
    if not email:
        raise ValueError("Privacy policy must provide a private contact")
    support = "# Support\n\n## Report a problem\n\n" + section(readme, "Support and feedback")
    support += f"\n\n## Privacy and security\n\nFor private account, privacy, or security matters, contact [{email[1]}]({email[2]}). Include only the information needed to explain the issue. Do not post credentials, tokens, meeting passcodes, or private transcripts in public Issues.\n\n## Before you write\n\nCheck the [user guide](/guide/) for connection, recordings, and removal instructions. Include the app version and macOS version, what you expected, what happened, and the steps needed to reproduce it. Screenshots with sample content are helpful.\n\n## Availability\n\n" + try_section
    files["support/index.html"] = document(brand, "Support", "Questions, bug reports, and a private route for sensitive matters.", support, "README.md", "/support/", css_hash).encode()
    missing = '<section class="not-found"><span class="eyebrow">404</span><h1>This page isn’t here.</h1><p>Try the <a href="/guide/">user guide</a>, or head back to the <a href="/">homepage</a>.</p></section>'
    files["404.html"] = shell(brand, "Page not found", "This page could not be found.", missing, "/404.html", css_hash).encode()
    files["_headers"] = b"/*\n  Content-Security-Policy: default-src 'none'; img-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\n  X-Content-Type-Options: nosniff\n  Referrer-Policy: no-referrer\n  X-Frame-Options: DENY\n"
    files["robots.txt"] = f"User-agent: *\nAllow: /\nDisallow: /v1/\nSitemap: {CANONICAL_URL}/sitemap.xml\n".encode()
    urls = ("/", "/guide/", "/support/", "/privacy/", "/terms/", "/notices/")
    files["sitemap.xml"] = ('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + ''.join(f"<url><loc>{CANONICAL_URL}{route}</loc></url>" for route in urls) + '</urlset>\n').encode()
    validate(files)
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / SERVICE / "public")
    parser.add_argument("--check", action="store_true", help="Verify generated files are current without writing")
    args = parser.parse_args()
    files = build_files()
    current = {str(path.relative_to(args.output)) for path in args.output.rglob("*") if path.is_file()} if args.output.exists() else set()
    unexpected = current - files.keys()
    if unexpected:
        raise ValueError("Unexpected files in public output: " + ", ".join(sorted(unexpected)))
    differences = [name for name, data in files.items() if not (args.output / name).is_file() or (args.output / name).read_bytes() != data]
    if args.check:
        if differences:
            print("Regenerate the review site: " + ", ".join(differences), file=sys.stderr)
            return 1
    else:
        for name in differences:
            path = args.output / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(files[name])
    print(f"Review site {'checked' if args.check else 'generated'}: {len(files)} files; all local links and anchors valid.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as error:
        print(f"Review site: {error}", file=sys.stderr)
        raise SystemExit(1)
