import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest


def load(name):
    path = Path(__file__).resolve().parents[1] / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


configure = load("configure-updates").configure
validate = load("validate-appcast").validate


class ReleaseConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.key = base64.b64encode(bytes(32)).decode()
        self.env = {"YAP_RELEASE": "1", "YAP_UPDATE_FEED_URL": "https://example.com/appcast.xml",
                    "YAP_UPDATE_PUBLIC_KEY": self.key}

    def test_release_cannot_silently_disable_updates(self):
        with self.assertRaises(ValueError):
            configure({}, {"YAP_RELEASE": "1"})
        self.assertEqual(configure({"CFBundleName": "Yap"}, {}), {"CFBundleName": "Yap"})

    def test_invalid_keys_and_insecure_feeds_fail_closed(self):
        for url in ["http://example.com/feed", "file:///tmp/feed", "https://name:secret@example.com/feed", "https://"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                configure({}, {**self.env, "YAP_UPDATE_FEED_URL": url})
        for key in ["", "not-base64", base64.b64encode(bytes(31)).decode()]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                configure({}, {**self.env, "YAP_UPDATE_PUBLIC_KEY": key})

    def test_release_configuration_requires_signed_feed_and_private_profile(self):
        info = configure({"CFBundleIdentifier": "com.grinich.yap"}, self.env)
        self.assertTrue(info["SURequireSignedFeed"])
        self.assertTrue(info["SUEnableAutomaticChecks"])
        self.assertTrue(info["SUAutomaticallyUpdate"])
        self.assertFalse(info["SUSendProfileInfo"])
        self.assertEqual(info["CFBundleIdentifier"], "com.grinich.yap")

    def test_unsigned_misdirected_and_mismatched_appcasts_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "Yap-macOS.zip"
            archive.write_bytes(b"archive")
            signature = base64.b64encode(bytes(64)).decode()
            info = {"CFBundleVersion": "2", "CFBundleShortVersionString": "0.1.1", "LSMinimumSystemVersion": "26.0"}
            feed = f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
                <sparkle:version>2</sparkle:version><sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
                <enclosure url="https://github.com/example/releases/releases/download/v0.1.1/Yap-macOS.zip"
                length="7" sparkle:edSignature="{signature}"/></item></channel></rss>'''
            validate(feed, archive, info, "example/releases")
            for invalid in [feed.replace(signature, ""), feed.replace('length="7"', 'length="8"'),
                            feed.replace("github.com", "attacker.example"), feed.replace(">2<", ">1<"),
                            feed.replace("26.0", "13.0")]:
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    validate(invalid, archive, info, "example/releases")


if __name__ == "__main__":
    unittest.main()
