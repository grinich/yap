import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/publish-release.sh"


class ReleasePublicationTests(unittest.TestCase):
    def run_release(self, arguments=(), *, existing=False, create_fails=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            calls = path / "calls.jsonl"
            gh = path / "gh"
            gh.write_text(f"#!{sys.executable}\n" + '''import json, os, pathlib, sys
args = sys.argv[1:]
entry = {"args": args}
if "--notes-file" in args:
    entry["notes"] = pathlib.Path(args[args.index("--notes-file") + 1]).read_text()
with open(os.environ["GH_FIXTURE_CALLS"], "a") as output:
    output.write(json.dumps(entry) + "\\n")
if args[:1] == ["api"]:
    print("public")
elif args[:2] == ["release", "view"]:
    sys.exit(0 if os.environ["GH_FIXTURE_EXISTS"] == "1" else 1)
elif args[:2] == ["release", "create"]:
    sys.exit(1 if os.environ["GH_FIXTURE_CREATE_FAILS"] == "1" else 0)
elif args[:2] != ["release", "edit"]:
    sys.exit("Unexpected gh command")
''')
            gh.chmod(0o700)
            env = {
                **os.environ,
                "PATH": f"{path}{os.pathsep}{os.environ['PATH']}",
                "YAP_RELEASE_REPOSITORY": "example/yap",
                "YAP_RELEASE_TAG": "v0.1.0",
                # An inherited environment variable must never enable publishing.
                "YAP_PUBLISH_RELEASE": "true",
                "GH_FIXTURE_CALLS": str(calls),
                "GH_FIXTURE_EXISTS": "1" if existing else "0",
                "GH_FIXTURE_CREATE_FAILS": "1" if create_fails else "0",
            }
            result = subprocess.run(["/bin/bash", str(SCRIPT), *arguments], cwd=path,
                                    env=env, capture_output=True, text=True)
            recorded = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
            return result, recorded

    def test_default_creates_complete_draft_without_publishing_or_switching_latest(self):
        result, calls = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        create = calls[-1]
        self.assertEqual(create["args"][:3], ["release", "create", "v0.1.0"])
        self.assertIn("--draft", create["args"])
        self.assertEqual(create["args"][-5:], [
            "dist/Yap-macOS.zip", "dist/Yap-macOS.zip.sha256", "dist/Yap.dmg",
            "dist/Yap.dmg.sha256", "dist/appcast.xml",
        ])
        self.assertIn("held pending required Zoom approval", create["notes"])
        self.assertFalse(any(call["args"][:2] == ["release", "edit"] for call in calls))

    def test_explicit_publish_promotes_only_after_creating_complete_draft(self):
        result, calls = self.run_release(["--publish"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-2]["args"][:2], ["release", "create"])
        self.assertIn("--draft", calls[-2]["args"])
        self.assertNotIn("held pending", calls[-2]["notes"])
        self.assertEqual(calls[-1]["args"], ["release", "edit", "v0.1.0", "--repo",
                                          "example/yap", "--draft=false", "--latest"])

    def test_failed_upload_never_publishes(self):
        result, calls = self.run_release(["--publish"], create_fails=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call["args"][:2] == ["release", "edit"] for call in calls))

    def test_existing_draft_or_published_release_is_never_overwritten_or_promoted(self):
        for arguments in [[], ["--publish"]]:
            with self.subTest(arguments=arguments):
                result, calls = self.run_release(arguments, existing=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls[-1]["args"][:2], ["release", "view"])
                self.assertIn("Release already exists", result.stderr)

    def test_ambiguous_publish_arguments_fail_before_github_access(self):
        for arguments in [["true"], ["--publish=false"], ["--publish", "false"]]:
            with self.subTest(arguments=arguments):
                result, calls = self.run_release(arguments)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(calls, [])


class ReleaseWorkflowTests(unittest.TestCase):
    def test_tag_push_cannot_enable_publication_or_public_artifacts(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        condition = re.search(r"^      YAP_PUBLISH_RELEASE: (.+)$", workflow, re.MULTILINE)
        self.assertIsNotNone(condition)
        self.assertEqual(condition[1], "${{ github.event_name == 'workflow_dispatch' && inputs.publish == true }}")
        publish_input = workflow.split("      publish:\n", 1)[1].split("permissions:", 1)[0]
        self.assertIn("        default: false\n", publish_input)
        self.assertIn("        type: boolean\n", publish_input)

        steps = workflow.split("      - name: ")
        artifact = next(step for step in steps if "uses: actions/upload-artifact@" in step)
        self.assertIn("        if: env.YAP_PUBLISH_RELEASE == 'true'\n", artifact)
        release = next(step for step in steps if "Scripts/publish-release.sh" in step)
        self.assertIn('if [[ "$YAP_PUBLISH_RELEASE" == true ]]; then\n'
                      '            /bin/bash Scripts/publish-release.sh --publish\n'
                      '          else\n'
                      '            /bin/bash Scripts/publish-release.sh\n'
                      '          fi', release)
        self.assertNotIn("        if:", release, "Tag and default dispatch runs must retain a draft.")


if __name__ == "__main__":
    unittest.main()
