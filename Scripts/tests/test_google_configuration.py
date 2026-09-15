import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).parents[2]
spec = importlib.util.spec_from_file_location("configure_google", ROOT / "Scripts/configure-google.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class GoogleConfigurationTests(unittest.TestCase):
    def test_every_build_embeds_the_same_client_without_environment_configuration(self):
        expected = plistlib.loads(module.CONFIGURATION.read_bytes())
        for env in [{}, {"YAP_RELEASE": "0"}, {"YAP_RELEASE": "1"}]:
            result = module.configure({"CFBundleIdentifier": "com.grinich.yap"}, env)
            self.assertEqual(result["YapGoogleClientID"], expected["YapGoogleClientID"])
            self.assertTrue(result["YapGoogleClientSecret"] == expected["YapGoogleClientSecret"])
            self.assertEqual(result["CFBundleIdentifier"], "com.grinich.yap")

    def test_stale_plist_configuration_is_replaced(self):
        result = module.configure({"YapGoogleClientID": "old", "YapGoogleClientSecret": "old"}, {})
        self.assertNotEqual(result["YapGoogleClientID"], "old")
        self.assertTrue(result["YapGoogleClientSecret"] != "old")

    def test_environment_cannot_substitute_another_google_app(self):
        for env in [{"YAP_GOOGLE_CLIENT_ID": "other.apps.googleusercontent.com"},
                    {"YAP_GOOGLE_CLIENT_SECRET": "private-fixture"}, {"YAP_GOOGLE_CLIENT_ID": ""}]:
            with self.assertRaises(ValueError) as caught:
                module.configure({}, env)
            self.assertNotIn("private-fixture", str(caught.exception))

    def test_missing_or_corrupt_canonical_configuration_blocks_every_build(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "GoogleOAuth.plist"
            for env in [{}, {"YAP_RELEASE": "1"}]:
                with self.assertRaises(ValueError):
                    module.configure({}, env, path)
            for value in [b"invalid", plistlib.dumps({}), plistlib.dumps({"YapGoogleClientID": "invalid", "YapGoogleClientSecret": "private-fixture"})]:
                path.write_bytes(value)
                with self.assertRaises(ValueError) as caught:
                    module.configure({}, {}, path)
                self.assertNotIn("private-fixture", str(caught.exception))

    def test_google_developer_setup_cannot_return_to_product_ui(self):
        sources = "\n".join(path.read_text() for path in (ROOT / "Sources/YapAppUI").glob("*.swift"))
        for removed in ["console.cloud.google.com", "Import Google desktop client", "Replace Google desktop client", "importGoogleConfiguration", "YapConfigurationStore"]:
            self.assertNotIn(removed, sources)

    def test_packaging_requires_the_canonical_resource_and_verification(self):
        script = (ROOT / "Scripts/build-app.sh").read_text()
        self.assertIn('Sources/YapCalendar/Resources/GoogleOAuth.plist', script)
        self.assertIn('configure-google.py" "$YAP_APP/Contents/Info.plist" --verify', script)
