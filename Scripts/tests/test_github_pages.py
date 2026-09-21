import importlib.util
from pathlib import Path
import unittest
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('github_pages', ROOT / 'Scripts/build-github-pages.py')
pages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pages)

class GitHubPagesTests(unittest.TestCase):
    def test_verified_homepage_and_all_local_paths_work_on_custom_domain(self):
        files = pages.build_files()
        self.assertIn('.nojekyll', files)
        self.assertNotIn('_headers', files)
        home = files['index.html'].decode()
        tokens = (ROOT / 'Resources/GoogleSiteVerification.txt').read_text().splitlines()
        self.assertEqual(home.count('name="google-site-verification"'), len(tokens))
        for token in tokens:
            self.assertIn(f'<meta name="google-site-verification" content="{token}">', home)
        self.assertIn('href="https://yap.enterprises/privacy/"', home)
        self.assertIn('src="https://yap.enterprises/assets/meeting-gallery.png"', home)
        self.assertIn('property="og:image" content="https://yap.enterprises/assets/social-share-v1.png"', home)
        self.assertIn('name="twitter:image" content="https://yap.enterprises/assets/social-share-v1.png"', home)
        for name, content in files.items():
            if name.endswith('.html'):
                self.assertNotIn(b'href="/', content)
                self.assertNotIn(b'src="/', content)
                self.assertNotIn(b'127.0.0.1', content)
                if name != '404.html' and not name.startswith('connect/'):
                    route = '/' + name.removesuffix('index.html')
                    self.assertIn(f'property="og:url" content="https://yap.enterprises{route}"'.encode(), content)
        self.assertIn(b'https://yap.enterprises/privacy/', files['sitemap.xml'])

    def test_source_artwork_is_unchanged(self):
        files = pages.build_files()
        for source, target in pages.site.ASSETS.items():
            self.assertEqual(files[target], (ROOT / source).read_bytes())

    def test_google_receipts_are_static_and_only_offer_a_fixed_app_link(self):
        files = pages.build_files()
        for outcome in ('received', 'cancelled', 'error'):
            with self.subTest(outcome=outcome):
                text = files[f'connect/google/{outcome}/index.html'].decode()
                parsed = pages.site.PageLinks()
                parsed.feed(text)  # Rejects scripts, forms, frames and event handlers.
                self.assertEqual(parsed.h1s, 1)
                self.assertEqual(parsed.links.count('yap://open'), 1)
                self.assertIn('name="referrer" content="no-referrer"', text)
                self.assertIn('name="robots" content="noindex, nofollow"', text)
                self.assertNotIn('property="og:', text)
                self.assertNotIn('name="twitter:', text)
                self.assertIn("default-src 'none'", text)
                self.assertIn("base-uri 'none'; form-action 'none'", text)
                for link in parsed.links:
                    if link != 'yap://open':
                        url = urlsplit(link)
                        self.assertEqual(url.scheme, 'https')
                        self.assertEqual(url.netloc, 'yap.enterprises')
                        self.assertTrue(url.path.startswith('/assets/'))
                self.assertNotIn(f'/connect/google/{outcome}/', files['sitemap.xml'].decode())
        received = files['connect/google/received/index.html'].decode()
        self.assertIn('Sign-in received', received)
        self.assertIn('finish connecting', received)
        self.assertNotIn('successfully connected', received)
