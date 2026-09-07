import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


def load(name):
    path = Path(__file__).resolve().parents[1] / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


download = load("download-zoom-sdk").download
prepare = load("prepare-zoom-sdk").prepare


class ZoomSDKDependencyTests(unittest.TestCase):
    def setUp(self):
        self.env = {
            "ZOOM_SDK_REPOSITORY": "owner/private-dependencies",
            "ZOOM_SDK_ASSET_ID": "123",
            "GH_TOKEN": "dependency-read-token-fixture",
            "GITHUB_REPOSITORY": "owner/public-source",
            "YAP_RELEASE_REPOSITORY": "owner/public-releases",
        }
        self.metadata = {"private": True, "visibility": "private", "full_name": "owner/private-dependencies"}

    def test_private_visibility_is_verified_before_downloading_to_a_temporary_file(self):
        calls = []

        def run(args, **kwargs):
            calls.append(args)
            self.assertEqual(kwargs["env"]["GH_TOKEN"], self.env["GH_TOKEN"])
            self.assertNotIn(self.env["GH_TOKEN"], args)
            if len(calls) == 1:
                return subprocess.CompletedProcess(args, 0, stdout=json.dumps(self.metadata))
            kwargs["stdout"].write(b"private SDK fixture")
            return subprocess.CompletedProcess(args, 0)

        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "sdk.zip"
            download(archive, self.env, run)
            self.assertEqual(archive.read_bytes(), b"private SDK fixture")
            self.assertEqual(list(Path(directory).iterdir()), [archive])
            self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        self.assertEqual(calls, [
            ["gh", "api", "repos/owner/private-dependencies"],
            ["gh", "api", "repos/owner/private-dependencies/releases/assets/123",
             "-H", "Accept: application/octet-stream"],
        ])

    def test_public_internal_unknown_malformed_and_redirected_repositories_never_fetch_sdk_bytes(self):
        rejected = [
            {**self.metadata, "private": False, "visibility": "public"},
            {**self.metadata, "visibility": "internal"},
            {**self.metadata, "visibility": "public"},
            {**self.metadata, "private": "true"},
            {"private": True, "full_name": self.metadata["full_name"]},
            {**self.metadata, "full_name": "owner/different-repository"},
            {},
            [],
            None,
        ]
        for metadata in rejected:
            with self.subTest(metadata=metadata), tempfile.TemporaryDirectory() as directory:
                calls = []

                def run(args, **kwargs):
                    calls.append(args)
                    self.assertNotIn("stdout", kwargs)
                    return subprocess.CompletedProcess(args, 0, stdout=json.dumps(metadata))

                archive = Path(directory) / "sdk.zip"
                with self.assertRaises(ValueError):
                    download(archive, self.env, run)
                self.assertEqual(len(calls), 1)
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_unreadable_metadata_and_failed_access_never_fetch_sdk_bytes(self):
        for response in ["not json", subprocess.CalledProcessError(1, ["gh", "api"])]:
            with self.subTest(response=response), tempfile.TemporaryDirectory() as directory:
                calls = []

                def run(args, **kwargs):
                    calls.append(args)
                    if isinstance(response, Exception):
                        raise response
                    return subprocess.CompletedProcess(args, 0, stdout=response)

                with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    download(Path(directory) / "sdk.zip", self.env, run)
                self.assertEqual(len(calls), 1)
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_invalid_configuration_and_source_or_distribution_repo_are_rejected_before_network_access(self):
        invalid = [
            {"ZOOM_SDK_REPOSITORY": ""},
            {"ZOOM_SDK_REPOSITORY": "https://github.com/owner/private"},
            {"ZOOM_SDK_REPOSITORY": "owner/repo/../public"},
            {"ZOOM_SDK_REPOSITORY": "OWNER/PUBLIC-SOURCE"},
            {"ZOOM_SDK_REPOSITORY": "owner/public-releases"},
            {"ZOOM_SDK_ASSET_ID": ""},
            {"ZOOM_SDK_ASSET_ID": "123/../../other"},
            {"ZOOM_SDK_ASSET_ID": "-1"},
            {"ZOOM_SDK_ASSET_ID": "0"},
            {"GH_TOKEN": "", "GITHUB_TOKEN": "source-token-must-not-be-used"},
        ]
        for overrides in invalid:
            with self.subTest(overrides=overrides), tempfile.TemporaryDirectory() as directory:
                def run(*args, **kwargs):
                    self.fail("Invalid dependency configuration attempted a network request.")

                with self.assertRaises(ValueError):
                    download(Path(directory) / "sdk.zip", {**self.env, **overrides}, run)
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_failed_download_removes_partial_archive_and_preserves_previous_archive(self):
        calls = []

        def run(args, **kwargs):
            calls.append(args)
            if len(calls) == 1:
                return subprocess.CompletedProcess(args, 0, stdout=json.dumps(self.metadata))
            kwargs["stdout"].write(b"incomplete download")
            raise subprocess.CalledProcessError(1, args)

        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "sdk.zip"
            archive.write_bytes(b"previous verified archive")
            with self.assertRaises(subprocess.CalledProcessError):
                download(archive, self.env, run)
            self.assertEqual(archive.read_bytes(), b"previous verified archive")
            self.assertEqual(list(Path(directory).iterdir()), [archive])

    def test_shared_public_source_and_distribution_still_require_a_separate_private_sdk_repository(self):
        env = {**self.env, "YAP_RELEASE_REPOSITORY": self.env["GITHUB_REPOSITORY"]}
        calls = []

        def run(args, **kwargs):
            calls.append(args)
            if "stdout" not in kwargs:
                return subprocess.CompletedProcess(args, 0, stdout=json.dumps(self.metadata))
            kwargs["stdout"].write(b"private SDK fixture")
            return subprocess.CompletedProcess(args, 0)

        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "sdk.zip"
            with self.assertRaisesRegex(ValueError, "separate"):
                download(archive, {**env, "ZOOM_SDK_REPOSITORY": env["GITHUB_REPOSITORY"]}, run)
            self.assertEqual(calls, [])
            download(archive, env, run)
            self.assertEqual(archive.read_bytes(), b"private SDK fixture")
            self.assertEqual(len(calls), 2)


class ZoomSDKPreparationTests(unittest.TestCase):
    def setUp(self):
        self.contents = b"pinned archive fixture"
        self.lock = {"sha256": hashlib.sha256(self.contents).hexdigest(), "sdkPath": "sdk-version/ZoomSDK"}

    def test_checksum_is_verified_before_creating_destination_or_extracting(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "sdk.zip"
            archive.write_bytes(b"unreviewed archive")
            destination = Path(directory) / "extracted"

            def run(*args, **kwargs):
                self.fail("An unverified SDK archive reached the extractor.")

            with self.assertRaisesRegex(ValueError, "checksum"):
                prepare(archive, destination, self.lock, run)
            self.assertFalse(destination.exists())

    def test_matching_archive_must_contain_the_pinned_sdk_header(self):
        for includes_header in [False, True]:
            with self.subTest(includes_header=includes_header), tempfile.TemporaryDirectory() as directory:
                archive = Path(directory) / "sdk.zip"
                archive.write_bytes(self.contents)
                destination = Path(directory) / "extracted"
                sdk = destination / self.lock["sdkPath"]
                calls = []

                def run(args, **kwargs):
                    calls.append(args)
                    if includes_header:
                        header = sdk / "ZoomSDK.framework/Headers/ZoomSDK.h"
                        header.parent.mkdir(parents=True)
                        header.write_text("reviewed SDK fixture")
                    return subprocess.CompletedProcess(args, 0)

                if includes_header:
                    self.assertEqual(prepare(archive, destination, self.lock, run), sdk.resolve())
                else:
                    with self.assertRaisesRegex(ValueError, "expected Zoom SDK"):
                        prepare(archive, destination, self.lock, run)
                self.assertEqual(calls, [["/usr/bin/ditto", "-x", "-k", str(archive.resolve()), str(destination.resolve())]])

    def test_pinned_path_cannot_escape_the_extraction_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "sdk.zip"
            archive.write_bytes(self.contents)
            destination = Path(directory) / "extracted"

            def run(*args, **kwargs):
                self.fail("An SDK lock with an escaping path reached the extractor.")

            with self.assertRaisesRegex(ValueError, "inside the extraction directory"):
                prepare(archive, destination, {**self.lock, "sdkPath": "../outside"}, run)
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
