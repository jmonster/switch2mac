import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[2] / 'scripts/notarize-release.py')
release = importlib.util.module_from_spec(spec); spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve(); self.app = self.root / 'App.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/MacOS/App').write_bytes(b'executable')
        self.info = {'CFBundleIdentifier': release.BUNDLE_ID, 'CFBundleExecutable': 'App',
                     'FTCWSourceRevision': 'a' * 40, 'FTCWSourceDirty': False, 'LSMinimumSystemVersion': '15.0'}
        self.save_info()
        self.output = self.root / 'output'; self.calls = []; self.failure = None
        self.signature = 'Authority=Developer ID Application: Fixture\nTeamIdentifier=ABCDEFGHIJ\nCodeDirectory v=20500 flags=0x10000(runtime)\nTimestamp=Fixture\n'
        self.entitlements = {}; self.dirty = ''; self.status = 'Accepted'

    def save_info(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))

    def runner(self, args):
        self.calls.append(args)
        if self.failure and self.failure in args:
            raise subprocess.CalledProcessError(1, args)
        text = ''
        if args[:3] == ['git', 'rev-parse', 'HEAD']: text = 'a' * 40
        elif args[:2] == ['git', 'status']: text = self.dirty
        elif args[:3] == ['codesign', '--display', '--verbose=4']: text = self.signature
        elif '--entitlements' in args: text = plistlib.dumps(self.entitlements).decode()
        elif args[0] == 'lipo': text = 'arm64 x86_64'
        elif args[:3] == ['xcrun', 'notarytool', 'submit']:
            text = json.dumps({'status': self.status, 'id': '01234567-89ab-cdef-0123-456789abcdef'})
        elif args[:3] == ['xcrun', 'notarytool', 'log']: text = json.dumps({'status': self.status, 'issues': None})
        elif args[0] == 'ditto':
            if '-c' in args:
                Path(args[-1]).write_bytes(b'fixture archive; not real notarization')
            else: shutil.copytree(args[-2], args[-1])
        return subprocess.CompletedProcess(args, 0, text, '')

    def package(self):
        return release.package(self.app, self.output, 'ABCDEFGHIJ', 'test-profile', self.runner)

    def test_success_staples_before_final_archive_and_never_mutates_original(self):
        before = (self.app / 'Contents/Info.plist').read_bytes()
        self.package()
        manifest = json.loads((self.output / 'provenance.json').read_text())
        self.assertEqual(manifest['hardware_game_acceptance'], 'not-run')
        self.assertEqual(manifest['architectures'], ['arm64', 'x86_64'])
        self.assertEqual(before, (self.app / 'Contents/Info.plist').read_bytes())
        final = next(i for i,c in enumerate(self.calls) if c[-1].endswith('switch2mac-notarized.zip'))
        assess = next(i for i,c in enumerate(self.calls) if c[0] == 'spctl')
        staple = next(i for i,c in enumerate(self.calls) if c[:3] == ['xcrun', 'stapler', 'staple'])
        self.assertLess(staple, assess); self.assertLess(assess, final)
        self.assertFalse(list(self.root.glob('.switch2mac-notary-*')))
        self.assertNotIn('test-profile', (self.output/'provenance.json').read_text())

    def test_untrusted_signatures_never_submit(self):
        for signature in [self.signature.replace('Developer ID Application:', 'Apple Development:'),
                          self.signature.replace('ABCDEFGHIJ', 'ZZZZZZZZZZ'),
                          self.signature.replace('runtime', 'adhoc'), self.signature.replace('Timestamp=', 'Signed Time=')]:
            self.signature = signature
            with self.assertRaises(release.ReleaseError): self.package()
            self.assertFalse(any('notarytool' in c for c in self.calls))
            self.assertFalse(self.output.exists())

    def test_dirty_wrong_bundle_revision_and_unsafe_entitlements_rejected(self):
        for key, value in [('FTCWSourceDirty', True), ('CFBundleIdentifier', 'other.application'), ('FTCWSourceRevision', 'b'*40)]:
            old = self.info[key]; self.info[key] = value; self.save_info()
            with self.assertRaises(release.ReleaseError): self.package()
            self.info[key] = old
        self.save_info(); self.dirty = ' M source.swift'
        with self.assertRaises(release.ReleaseError): self.package()
        self.dirty = ''; self.entitlements = {'com.apple.security.cs.disable-library-validation': True}
        with self.assertRaises(release.ReleaseError): self.package()
        self.assertFalse(any('notarytool' in c for c in self.calls))

    def test_rejected_notary_or_verification_never_produces_distribution(self):
        self.status = 'Invalid'
        with self.assertRaises(release.ReleaseError): self.package()
        self.status = 'Accepted'
        for failure in ['staple', 'validate', 'spctl']:
            self.failure = failure
            with self.assertRaises(subprocess.CalledProcessError): self.package()
            self.assertFalse(self.output.exists())
            self.assertFalse(list(self.root.glob('.switch2mac-notary-*')))

    def test_existing_output_and_invalid_inputs(self):
        self.output.mkdir(); (self.output/'keep').write_text('unchanged')
        with self.assertRaises(release.ReleaseError): self.package()
        self.assertEqual((self.output/'keep').read_text(), 'unchanged')
        for team, profile in [('bad', 'ok'), ('ABCDEFGHIJ', ''), ('ABCDEFGHIJ', '\nsecret')]:
            with self.assertRaises(release.ReleaseError):
                release.package(self.app, self.output, team, profile, self.runner)
        for invalid in ['[]', '"text"', 'x' * 1_048_577]:
            with self.assertRaises((release.ReleaseError, ValueError)): release.bounded_json(invalid)


if __name__ == '__main__': unittest.main()
