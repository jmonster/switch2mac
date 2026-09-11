import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("installer", Path(__file__).resolve().parents[2] / "sdl/install_gopher64.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "Original.app"
        self.destination = self.root / "Apps/Copy.app"
        self.library = self.root / "libSDL.dylib"
        self.library.write_bytes(b"library")
        for name in installer.REQUIRED_FILES:
            file = self.source / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b"unchanged original")
        (self.source / "Contents/Resources").mkdir()
        (self.source / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "original.id"}))
        self.destination.mkdir(parents=True)
        (self.destination / "Contents").mkdir()
        (self.destination / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": installer.BUNDLE_ID}))
        (self.destination / "previous-version").write_text("preserve me")
        self.original = {str(p.relative_to(self.source)): p.read_bytes() for p in self.source.rglob("*") if p.is_file()}

    def runner(self, args):
        return subprocess.CompletedProcess(args, 0, "", "flags=0x2(adhoc)\n")

    def install(self, runner=None):
        return installer.install(self.source, self.destination, self.library, runner or self.runner)

    def assert_preserved(self):
        self.assertEqual((self.destination / "previous-version").read_text(), "preserve me")
        self.assertEqual(self.original, {str(p.relative_to(self.source)): p.read_bytes() for p in self.source.rglob("*") if p.is_file()})
        self.assertFalse(list(self.destination.parent.glob(".switch2mac-install-*")))
        self.assertFalse(list(self.destination.parent.glob("*.install-lock")))

    def test_success_and_provenance(self):
        self.install()
        self.assertFalse((self.destination / "previous-version").exists())
        self.assertEqual(installer.read_plist(self.destination / "Contents/Info.plist")["LSEnvironment"], {"SDL3_DYNAMIC_API": installer.RUNTIME_DYLIB})
        self.assertTrue((self.destination / "Contents/Resources/switch2mac-install.json").exists())
        self.assertFalse(list(self.destination.parent.glob(".switch2mac-install-*")))
        self.assertEqual(self.original, {str(p.relative_to(self.source)): p.read_bytes() for p in self.source.rglob("*") if p.is_file()})

    def test_missing_cli_is_preflight_failure(self):
        (self.source / "Contents/MacOS/gopher64-cli").unlink()
        with self.assertRaises(installer.InstallError):
            self.install()
        self.assertTrue((self.destination / "previous-version").exists())
        self.assertFalse(list(self.destination.parent.glob(".switch2mac-install-*")))

    def test_copy_failure_preserves_previous(self):
        with patch.object(installer.shutil, "copy2", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.install()
        self.assert_preserved()

    def test_sign_and_both_verify_failures_preserve_previous(self):
        for failure in ("sign", "stage", "installed"):
            def runner(args):
                target = Path(args[-1])
                fail = (failure == "sign" and "--force" in args) or ("--verify" in args and (
                    (failure == "stage" and target != self.source and target != self.destination) or
                    (failure == "installed" and target == self.destination)))
                if fail:
                    raise subprocess.CalledProcessError(1, args)
                return self.runner(args)
            with self.assertRaises(subprocess.CalledProcessError):
                self.install(runner)
            self.assert_preserved()

    def test_promotion_failure_rolls_back(self):
        replace = installer.os.replace
        def fail_staged(source, dest):
            if Path(source).name == self.destination.name and Path(source).parent != self.destination.parent:
                raise OSError("rename denied")
            return replace(source, dest)
        with patch.object(installer.os, "replace", side_effect=fail_staged):
            with self.assertRaises(OSError):
                self.install()
        self.assert_preserved()

    def test_failed_rollback_retains_recovery_files(self):
        replace = installer.os.replace
        def fail(source, dest):
            if Path(dest) == self.destination:
                raise OSError("destination unavailable")
            return replace(source, dest)
        with patch.object(installer.os, "replace", side_effect=fail):
            with self.assertRaisesRegex(installer.InstallError, "Recovery files retained"):
                self.install()
        transactions = list(self.destination.parent.glob(".switch2mac-install-*"))
        self.assertEqual(len(transactions), 1)
        self.assertTrue((transactions[0] / "previous.app/previous-version").exists())
        self.assertTrue((transactions[0] / "recovery.json").exists())

    def test_refuses_original_unrelated_symlink_and_lock(self):
        with self.assertRaises(installer.InstallError):
            installer.install(self.source, self.source, self.library, self.runner)
        info = self.destination / "Contents/Info.plist"
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "unrelated"}))
        with self.assertRaises(installer.InstallError):
            self.install()
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": installer.BUNDLE_ID}))
        link = self.root / "link.app"; link.symlink_to(self.destination)
        with self.assertRaises(installer.InstallError):
            installer.install(self.source, link, self.library, self.runner)
        lock = self.destination.parent / ("." + self.destination.name + ".install-lock")
        lock.mkdir()
        with self.assertRaises(installer.InstallError):
            self.install()
        self.assertTrue(lock.exists(), "Must not remove another installation's lock")


if __name__ == "__main__":
    unittest.main()
