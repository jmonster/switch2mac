# Maintainer-controlled trusted release packaging

This is release **tooling**, not a notarized release or an enabled update feed.
Automatic updates remain disabled, including saved feed overrides. The tool
requires an explicit signing identity and never publishes a release, installs an
app, grants HID entitlements, modifies the input app, or changes macOS policy.

## Preconditions and deliberate submission

A maintainer must establish permission to distribute all included work, their
own Apple Developer ID Application identity, a clean reviewed commit, and an
existing `notarytool` Keychain profile. Do not put certificates, passwords or API
keys in source, pull-request comments, command-line password arguments or CI logs.
Apple's account/identity and restricted HID entitlement approvals are separate
requirements; this script does not obtain or imply them.

Build and test the intended commit with the maintainer's own signing identity:

```sh
SIGN_IDENTITY='Developer ID Application: YOUR IDENTITY' bash scripts/build-app.sh
bash tests/run.sh
python3 scripts/notarize-release.py \
  --app 'build/GameCubed.app' \
  --output build/notarized-candidate \
  --team-id YOURTEAMID \
  --keychain-profile YOUR_EXISTING_PROFILE
```

**Running the last command submits a copy of the app to Apple.** The output
path must not exist. Team ID is exactly ten uppercase letters/digits; use the
actual value, not the placeholder. The existing build script enables hardened
runtime with Developer ID signing. A profile-bearing HID build additionally
requires explicit application-specific entitlements and matching provisioning.

The packager verifies the app signature, expected team, Developer ID Application
authority, secure timestamp, hardened runtime, clean source provenance and known
Mach-O architectures. It rejects debugging/library-validation exceptions. It
stages beside the output, creates a submission ZIP, waits for an Accepted
response, fetches the notary log, staples/validates the **app**, reassesses it
with Gatekeeper, and recreates the distributable ZIP after stapling. Any failure
prevents promotion of the distribution directory. The original app remains
unchanged. Hard interruption can leave a private `.switch2mac-notary-*` staging
directory; remove it only after confirming no packager is running.

The output contains a SHA-256 checksum, provenance, the stapled app ZIP and
Apple's receipt/log. Review warnings even after acceptance. Logs can contain
internal bundle paths; review them before sharing. No credential or Keychain
profile name is added to provenance. A notary receipt is not hardware/game
acceptance, and a checksum by itself is not a trusted update signature.

## Distribution and update gates still requiring the maintainer

Verify installation on a clean Mac under normal Gatekeeper policy, the actual
minimum OS/architecture, first-run Bluetooth privacy, login registration,
upgrading/replacing the same bundle identity, interruption recovery, removal,
and each claimed controller/game combination. Obtain distribution/license and
entitlement approvals before representing those claims as established.

Only then publish the reviewed ZIP and evidence through a maintainer-controlled
release. Do not enable automatic updates merely because this tool produced a ZIP.
An update system needs an authenticated
manifest/signature trust root, pinned team/bundle verification, version/rollback
rules, size bounds, atomic replacement/recovery and signing-key rotation tests.
None of those guarantees can be provided by an unsigned checksum/feed alone.

Automated tests use injected command responses for successful/rejected notary
flows and real temporary files for staging. The macOS suite also creates an
actual ad-hoc signed fixture and proves it is rejected **before any submission**.
No test claims that Apple accepted a real release or that a credential is present.

Primary process references:
- https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
- https://developer.apple.com/documentation/security/resolving-common-notarization-issues
- https://developer.apple.com/developer-id/
