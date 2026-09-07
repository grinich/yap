import importlib.util
from pathlib import Path
import subprocess
import unittest


spec = importlib.util.spec_from_file_location("install_safety", Path(__file__).resolve().parents[1] / "install-safety.py")
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)


class InstallSafetyTests(unittest.TestCase):
    parent = Path("/fixture/Applications")

    def runner(self, processes):
        def run(args, **kwargs):
            if args[0] == "/usr/bin/pgrep":
                name = args[-1]
                pids = [str(pid) for pid, (executable, _) in processes.items() if executable == name]
                return subprocess.CompletedProcess(args, 0 if pids else 1, stdout="\n".join(pids), stderr="")
            self.assertEqual(args[0], "/bin/ps")
            return subprocess.CompletedProcess(args, 0, stdout=processes[int(args[2])][1] + "\n", stderr="")
        return run

    def test_no_installed_processes_allows_installation(self):
        safety.require_stopped(self.parent, self.runner({}))

    def test_current_and_legacy_installed_apps_each_block_installation(self):
        for executable, bundle in (("Yap", "Yap.app"), ("Whoosh", "Zooom.app"),
                                   ("Whoosh", "Whoosh.app"), ("Zooom", "Zooom.app")):
            with self.subTest(executable=executable, bundle=bundle), self.assertRaisesRegex(ValueError, "Quit the installed"):
                safety.require_stopped(self.parent, self.runner({123: (executable, str(self.parent / bundle / "Contents/MacOS" / executable))}))

    def test_isolated_previews_and_similarly_named_paths_do_not_block(self):
        processes = {123: ("Yap", "/temporary/preview/Yap.app/Contents/MacOS/Yap"),
                     456: ("Whoosh", str(self.parent / "Zooom.app-preview/Contents/MacOS/Whoosh"))}
        safety.require_stopped(self.parent, self.runner(processes))

    def test_installed_legacy_process_is_found_even_after_noninstalled_current_preview(self):
        processes = {123: ("Yap", "/temporary/preview/Yap.app/Contents/MacOS/Yap"),
                     456: ("Whoosh", str(self.parent / "Zooom.app/Contents/MacOS/Whoosh"))}
        with self.assertRaises(ValueError):
            safety.require_stopped(self.parent, self.runner(processes))

    def test_multiple_same_named_processes_cannot_hide_the_installed_instance(self):
        processes = {123: ("Yap", "/temporary/preview/Yap.app/Contents/MacOS/Yap"),
                     456: ("Yap", str(self.parent / "Yap.app/Contents/MacOS/Yap"))}
        with self.assertRaises(ValueError):
            safety.require_stopped(self.parent, self.runner(processes))

    def test_process_discovery_errors_and_malformed_results_fail_closed(self):
        for status, output in ((2, ""), (0, ""), (0, "123\nnot-a-pid")):
            with self.subTest(status=status, output=output), self.assertRaises(ValueError):
                safety.require_stopped(self.parent, lambda args, **kwargs: subprocess.CompletedProcess(args, status, stdout=output))

    def test_process_exiting_during_lookup_requires_a_retry(self):
        def run(args, **kwargs):
            if args[0] == "/usr/bin/pgrep":
                return subprocess.CompletedProcess(args, 0, stdout="123")
            return subprocess.CompletedProcess(args, 1, stdout="")
        with self.assertRaisesRegex(ValueError, "Retry"):
            safety.require_stopped(self.parent, run)

    def test_spaces_in_installation_path_are_preserved(self):
        parent = Path("/fixture/Account With Spaces/Applications")
        with self.assertRaises(ValueError):
            safety.require_stopped(parent, self.runner({123: ("Whoosh", str(parent / "Zooom.app/Contents/MacOS/Whoosh"))}))


if __name__ == "__main__":
    unittest.main()
