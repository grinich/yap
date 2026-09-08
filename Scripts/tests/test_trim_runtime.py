import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('trim_runtime', Path(__file__).resolve().parents[1] / 'trim-runtime.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TrimRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        source = cls.root / 'fixture.c'
        source.write_text('int fixture(void) { return 42; }\n')
        for arch, target in [('arm64', 'arm64-apple-macos14'), ('x86_64', 'x86_64-apple-macos14')]:
            subprocess.run(['xcrun', 'clang', '-target', target, '-dynamiclib', str(source), '-o', str(cls.root / arch)], check=True)
        subprocess.run(['/usr/bin/lipo', '-create', str(cls.root/'arm64'), str(cls.root/'x86_64'), '-output', str(cls.root/'universal')], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_trims_real_universal_images_preserving_layout_resources_and_original(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            framework = root / 'Fixture.framework'
            version = framework / 'Versions/A'
            version.mkdir(parents=True)
            original = (self.root/'universal').read_bytes()
            binary = version / 'Fixture'
            binary.write_bytes(original)
            binary.chmod(0o755)
            (framework/'Versions/Current').symlink_to('A')
            (framework/'Fixture').symlink_to('Versions/Current/Fixture')
            for name in module.METADATA:
                (version/name).mkdir()
                (version/name/'compile-only').write_text('metadata')
                (framework/name).symlink_to('Versions/Current/'+name)
            (version/'Resources').mkdir()
            (version/'Resources/license.txt').write_text('keep license')
            (root/'Modules').mkdir()
            (root/'Modules/runtime.txt').write_text('keep unrelated folder')
            (root/'external').symlink_to(self.root, target_is_directory=True)
            module.trim(root)
            self.assertEqual(subprocess.check_output(['/usr/bin/lipo', '-archs', str(binary)], text=True).strip(), 'arm64')
            self.assertTrue((framework/'Fixture').is_file())
            self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
            for name in module.METADATA:
                self.assertFalse((version/name).exists())
                self.assertFalse((framework/name).is_symlink())
            self.assertEqual((version/'Resources/license.txt').read_text(), 'keep license')
            self.assertTrue((root/'Modules/runtime.txt').is_file())
            self.assertEqual((self.root/'universal').read_bytes(), original)
            arm_bytes = binary.read_bytes()
            module.trim(root)
            self.assertEqual(binary.read_bytes(), arm_bytes)

    def test_rejects_intel_only_runtime_instead_of_silently_removing_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root/'intel-only'
            original = (self.root/'x86_64').read_bytes()
            binary.write_bytes(original)
            with self.assertRaisesRegex(ValueError, 'no arm64 slice'):
                module.trim(root)
            self.assertEqual(binary.read_bytes(), original)

    def test_rejects_symlink_root(self):
        with tempfile.TemporaryDirectory() as directory:
            link = Path(directory)/'source'
            link.symlink_to(self.root, target_is_directory=True)
            with self.assertRaises(ValueError):
                module.trim(link)
