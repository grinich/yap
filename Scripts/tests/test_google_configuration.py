import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("configure_google", Path(__file__).parents[1] / "configure-google.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class GoogleConfigurationTests(unittest.TestCase):
    def test_release_embeds_client_and_preserves_other_settings(self):
        result = module.configure({"CFBundleIdentifier": "com.grinich.yap"}, {
            "YAP_RELEASE": "1", "YAP_GOOGLE_CLIENT_ID": "test.apps.googleusercontent.com",
            "YAP_GOOGLE_CLIENT_SECRET": "test-secret"})
        self.assertEqual(result["YapGoogleClientID"], "test.apps.googleusercontent.com")
        self.assertEqual(result["YapGoogleClientSecret"], "test-secret")
        self.assertEqual(result["CFBundleIdentifier"], "com.grinich.yap")

    def test_release_cannot_silently_omit_sign_in_configuration(self):
        with self.assertRaises(ValueError):
            module.configure({}, {"YAP_RELEASE": "1"})

    def test_source_build_does_not_retain_stale_configuration(self):
        self.assertEqual(module.configure({"YapGoogleClientID": "stale", "YapGoogleClientSecret": "stale"}, {}), {})

    def test_incomplete_and_invalid_configuration_fail_without_printing_values(self):
        for client, secret in [("test.apps.googleusercontent.com", ""), ("", "sensitive"),
                               ("test.apps.googleusercontent.com.evil", "sensitive"),
                               ("test.apps.googleusercontent.com", "sensitive\nvalue")]:
            with self.subTest(client=client):
                with self.assertRaises(ValueError) as caught:
                    module.configure({}, {"YAP_GOOGLE_CLIENT_ID": client, "YAP_GOOGLE_CLIENT_SECRET": secret})
                self.assertNotIn("sensitive", str(caught.exception))
