import importlib.util
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("validate_zoom", ROOT / "Scripts/validate-zoom.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ZoomConfigurationTests(unittest.TestCase):
    def setUp(self):
        with (ROOT / "Resources/Info.plist").open("rb") as source:
            self.info = plistlib.load(source)

    def test_canonical_packaged_configuration_uses_native_public_client(self):
        module.validate(self.info)

    def test_missing_confidential_or_redirected_configuration_fails(self):
        for key, value in [("YapZoomOAuthClientID", "UHoml3aIQpy86gZeijjfpQ"),
                           ("YapZoomOAuthClientID", ""),
                           ("YapZoomOAuthRedirectURL", "http://127.0.0.1:1234/callback"),
                           ("YapZoomOAuthRedirectURL", "https://other.example/oauth/zoom/callback")]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                module.validate({**self.info, key: value})
        for key in ("YapZoomOAuthClientID", "YapZoomOAuthRedirectURL"):
            with self.subTest(missing=key), self.assertRaises(ValueError):
                module.validate({k: v for k, v in self.info.items() if k != key})

    def test_legacy_signer_configuration_cannot_ship(self):
        for key in ("YapZoomSDKClientID", "YapZoomSDKSignerURL", "YapZoomClientSecret"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.validate({**self.info, key: "retired"})


if __name__ == "__main__":
    unittest.main()
