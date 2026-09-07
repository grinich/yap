import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/build-review-site.py"
spec = importlib.util.spec_from_file_location("review_site", SCRIPT)
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)


class ReviewSiteTests(unittest.TestCase):
    def test_raw_html_is_escaped_and_active_url_schemes_are_rejected(self):
        renderer = site.Markdown("README.md")
        rendered = renderer.render('<script>alert("x")</script> **Visible** `a < b`')
        self.assertNotIn("<script>", rendered)
        self.assertIn("&lt;script&gt;", rendered)
        self.assertIn("<strong>Visible</strong>", rendered)
        self.assertIn("<code>a &lt; b</code>", rendered)
        for target in ("javascript:alert", "javascript&#58;alert", "data:text/html,hello", "//tracker.invalid/x"):
            with self.subTest(target=target), self.assertRaises(ValueError):
                renderer.render(f"[Link]({target})")

    def test_only_original_allowlisted_images_can_be_published(self):
        renderer = site.Markdown("README.md")
        self.assertIn('src="/assets/recordings.jpg"', renderer.render("![Sample](Documentation/Images/recordings.jpg)"))
        for target in ("https://tracker.invalid/pixel.png", "Resources/ZoomSDK.lock.json", "../../private.png"):
            with self.subTest(target=target), self.assertRaises(ValueError):
                renderer.render(f"![Image]({target})")

    def test_source_document_links_become_site_routes_or_public_source_links(self):
        renderer = site.Markdown("README.md")
        value = renderer.render("[Privacy](PRIVACY.md) [Guide](Documentation/Recordings.md) [Contact](mailto:person@example.com)")
        self.assertIn('href="/privacy/"', value)
        self.assertIn('href="https://github.com/grinich/zooom/blob/main/Documentation/Recordings.md"', value)
        self.assertIn('href="mailto:person@example.com"', value)

    def test_lists_tables_quotes_and_heading_anchors_retain_content(self):
        renderer = site.Markdown("README.md")
        result = renderer.render("# Title\n\n## Same heading\n\n> Draft terms.\n\n- One\n- Two\n\n| Action | Key |\n| --- | --- |\n| Play | Space |\n\n## Same heading", omit_title=True)
        self.assertNotIn("<h1", result)
        self.assertIn('id="same-heading"', result)
        self.assertIn('id="same-heading-1"', result)
        self.assertIn("<blockquote><p>Draft terms.</p></blockquote>", result)
        self.assertIn("<li>Two</li>", result)
        self.assertIn("<td>Space</td>", result)

    def test_generated_site_has_only_intended_documents_and_assets(self):
        files = site.build_files()
        expected = {"index.html", "guide/index.html", "privacy/index.html", "terms/index.html",
                    "support/index.html", "notices/index.html", "404.html", "assets/site.css",
                    "assets/icon.png", "assets/recordings.jpg", "assets/agenda.jpg", "_headers",
                    "robots.txt", "sitemap.xml"}
        self.assertEqual(set(files), expected)
        site.validate(files)
        for source, target in site.ASSETS.items():
            self.assertEqual(files[target], (ROOT / source).read_bytes())
        for path, data in files.items():
            if path.endswith(".html"):
                self.assertNotIn(b"<script", data)
                self.assertNotIn(b"ZOOM_SDK_CLIENT_SECRET=", data)
                self.assertNotIn(b"/Users/mg/", data)
        for route, source in (("privacy", "PRIVACY.md"), ("terms", "TERMS.md"), ("notices", "THIRD_PARTY_NOTICES.md")):
            # Every rendered source paragraph remains present, including draft notices.
            full_body = site.Markdown(source).render((ROOT / source).read_text(), omit_title=True)
            self.assertIn(full_body, files[f"{route}/index.html"].decode())

    def test_link_validator_rejects_missing_assets_and_anchors(self):
        for link in ("/missing/", "#missing", "/assets/missing.jpg"):
            with self.subTest(link=link), self.assertRaises(ValueError):
                site.validate({"index.html": f'<h1>Page</h1><a href="{link}">Link</a>'.encode()})

    def test_cli_check_detects_stale_output_and_unexpected_private_files(self):
        with tempfile.TemporaryDirectory(prefix="review-site-test-") as directory:
            command = [sys.executable, str(SCRIPT), "--output", directory]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(subprocess.run(command + ["--check"], capture_output=True).returncode, 0)
            output = Path(directory)
            (output / "privacy/index.html").write_text("stale policy")
            self.assertEqual(subprocess.run(command + ["--check"], capture_output=True).returncode, 1)
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            (output / ".dev.vars").write_text("test-only private file")
            result = subprocess.run(command + ["--check"], capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn(b"Unexpected files", result.stderr)


if __name__ == "__main__":
    unittest.main()
