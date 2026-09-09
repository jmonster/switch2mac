"""Metadata/signing guards and the production updater's actual feed resolver."""
from pathlib import Path
import os
import plistlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'io.github.jmonster.switch2mac'
assert info['CFBundleDisplayName'].endswith('(jmonster)')
assert 'Peter Sharma' in info['NSHumanReadableCopyright']
about = (root / 'Sources/FinallyTheControllerWorks/UI/AboutAndOnboarding.swift').read_text()
assert re.search(r'static let updatesEnabled\s*=\s*false', about)
assert re.search(r'static let defaultUpdateFeedURL\s*=\s*""', about)
assert 'https://buymeacoffee.com/peterksharma' in about
updater = (root / 'Sources/FinallyTheControllerWorks/UI/Updater.swift').read_text()
# Extract the actual resolver without its unrelated AppKit/SwiftUI UI. Use
# an upstream-like nonempty default and an explicit saved override to show
# both are rejected by the production policy guard.
a = updater.index('    var feedURL: URL? {')
b = updater.index('\n    /// Auto-check', a)
resolver = updater[a:b]
Path(sys.argv[1]).write_text('''import Foundation
enum AppInfo {
    static let updatesEnabled = false
    static let defaultUpdateFeedURL = "https://example.invalid/upstream.json"
}
final class Updater {
    static let feedURLKey = "fork-update-policy-test"
''' + resolver + '''
}
@main enum Test {
    static func main() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Updater.feedURLKey)
        defer { defaults.removeObject(forKey: Updater.feedURLKey) }
        precondition(Updater().feedURL == nil, "Default feed must be disabled")
        defaults.set("https://example.invalid/override.json", forKey: Updater.feedURLKey)
        precondition(Updater().feedURL == nil, "Saved override must not bypass fork policy")
        print("PASS disabled default and override update feeds")
    }
}
''')
for method in ['downloadAndInstall(_ entry: AppcastEntry)', 'installNow()']:
    start = updater.index('    func ' + method)
    assert 'guard AppInfo.updatesEnabled else { return }' in updater[start:start + 150]
# No signed build or credentials are accessed by these negative controls.
env = dict(os.environ)
for name in ('SIGN_IDENTITY', 'SIGN_ENTITLEMENTS', 'NOTARY_KEYCHAIN_PROFILE', 'PROVISIONING_PROFILE'):
    env.pop(name, None)
def rejected(script, expected):
    result = subprocess.run(['bash', str(root / script)], env=env, capture_output=True, text=True, timeout=3)
    assert result.returncode != 0 and expected in result.stderr, result.stderr
rejected('scripts/notarize.sh', 'Supply your own Developer ID')
env['SIGN_IDENTITY'] = 'test-only-not-a-certificate'
rejected('scripts/notarize.sh', 'Supply your own notarytool')
env['PROVISIONING_PROFILE'] = '/nonexistent-test-profile'
rejected('scripts/build-app.sh', 'Provide a fork-specific entitlement plist')
print('PASS fork metadata, attribution, and fail-closed signing configuration')
