import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('github_pages', ROOT / 'Scripts/build-github-pages.py')
pages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pages)

class GitHubPagesTests(unittest.TestCase):
    def test_verified_homepage_and_all_local_paths_work_under_project_prefix(self):
        files = pages.build_files()
        self.assertIn('.nojekyll', files)
        self.assertNotIn('_headers', files)
        home = files['index.html'].decode()
        self.assertIn('name="google-site-verification"', home)
        self.assertIn('href="https://grinich.github.io/yap/privacy/"', home)
        self.assertIn('src="https://grinich.github.io/yap/assets/meeting-gallery.png"', home)
        for name, content in files.items():
            if name.endswith('.html'):
                self.assertNotIn(b'href="/', content)
                self.assertNotIn(b'src="/', content)
                self.assertNotIn(b'127.0.0.1', content)
        self.assertIn(b'https://grinich.github.io/yap/privacy/', files['sitemap.xml'])

    def test_source_artwork_is_unchanged(self):
        files = pages.build_files()
        for source, target in pages.site.ASSETS.items():
            self.assertEqual(files[target], (ROOT / source).read_bytes())
