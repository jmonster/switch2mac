"""Metadata/signing guards and the production updater's actual feed resolver."""
from pathlib import Path
import os
import json
import plistlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'io.github.switch2mac.gamecubed'
assert info['CFBundleName'] == info['CFBundleDisplayName'] == 'GameCubed'
assert info['CFBundleExecutable'] == 'GameCubed'
assert 'Peter Sharma' in info['NSHumanReadableCopyright']
about = (root / 'Sources/GameCubed/UI/AboutAndOnboarding.swift').read_text()
assert re.search(r'static let updatesEnabled\s*=\s*false', about)
assert re.search(r'static let defaultUpdateFeedURL\s*=\s*""', about)
assert 'Text("GameCubed")' in about
assert 'product: "\\(model.displayName) (GameCubed)"' in (root / 'Sources/GameCubed/Output/VirtualHID.swift').read_text()
menu = (root / 'Sources/GameCubed/GameCubedApp.swift').read_text()
assert not re.search(r'coffee|donat|patreon|paypal|ko-fi', about + menu, re.I)
assert 'Credits' in about and 'CREDITS.md' in about
manifest = json.loads((root / 'browser/extension/manifest.json').read_text())
assert manifest['name'] == 'GameCubed — Browser Bridge'
package = (root / 'Package.swift').read_text()
assert 'path: "Sources/GameCubed"' in package
assert package.count('name: "GameCubed"') == 2
assert 'GameCubedApp.main()' in (root / 'Sources/GameCubed/Runtime/ApplicationEntry.swift').read_text()
for file in ['README.md', 'CREDITS.md', 'docs/app-identity.md', 'browser/INTEGRATION.md']:
    assert (root / file).is_file(), file
updater = (root / 'Sources/GameCubed/UI/Updater.swift').read_text()
# Extract the actual resolver without its unrelated AppKit/SwiftUI UI. Use
# a nonempty default and an explicit saved override to show
# both are rejected by the production policy guard.
a = updater.index('    var feedURL: URL? {')
b = updater.index('\n    /// Auto-check', a)
resolver = updater[a:b]
Path(sys.argv[1]).write_text('''import Foundation
enum AppInfo {
    static let updatesEnabled = false
    static let defaultUpdateFeedURL = "https://example.invalid/default.json"
}
final class Updater {
    static let feedURLKey = "gamecubed-update-policy-test"
''' + resolver + '''
}
@main enum Test {
    static func main() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Updater.feedURLKey)
        defer { defaults.removeObject(forKey: Updater.feedURLKey) }
        precondition(Updater().feedURL == nil, "Default feed must be disabled")
        defaults.set("https://example.invalid/override.json", forKey: Updater.feedURLKey)
        precondition(Updater().feedURL == nil, "Saved override must not bypass update policy")
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
rejected('scripts/build-app.sh', 'Provide an application-specific entitlement plist')
print('PASS application metadata, attribution, and fail-closed signing configuration')
