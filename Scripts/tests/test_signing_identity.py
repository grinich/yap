import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("signing_identity", Path(__file__).resolve().parents[1] / "resolve-signing-identity.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_unconfigured_build_retains_adhoc_default(self):
        self.assertEqual(signing.resolve(self.root, {}), "-")

    def test_local_fingerprint_persists_without_environment(self):
        (self.root / "signing.local.json").write_text(json.dumps({"certificateSHA1": "ab" * 20}))
        self.assertEqual(signing.resolve(self.root, {}), "AB" * 20)

    def test_explicit_environment_overrides_local_configuration(self):
        (self.root / "signing.local.json").write_text(json.dumps({"certificateSHA1": "ab" * 20}))
        self.assertEqual(signing.resolve(self.root, {"WHOOSH_SIGNING_IDENTITY": "Other Identity"}), "Other Identity")

    def test_empty_environment_does_not_silently_fall_back(self):
        with self.assertRaises(ValueError):
            signing.resolve(self.root, {"WHOOSH_SIGNING_IDENTITY": ""})

    def test_invalid_local_configuration_never_falls_back(self):
        for content in ("not JSON", "[]", '{"certificateSHA1":"-"}', '{"certificateSHA1":"abcd"}'):
            with self.subTest(content=content):
                (self.root / "signing.local.json").write_text(content)
                with self.assertRaises(ValueError):
                    signing.resolve(self.root, {})


if __name__ == "__main__":
    unittest.main()
