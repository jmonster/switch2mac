# Application identity and signing

GameCubed uses the bundle identifier `io.github.switch2mac.gamecubed` and
application filename `GameCubed.app`.

Automatic updates, saved feed overrides, and download/install entry points are
disabled. Install builds manually. Enabling an updater requires a signing
identity, a trusted feed, bundle verification, and a rollback policy. The
signature verifier must remain in place.

A changed bundle identifier requires macOS privacy approvals, launch-at-login
registration, and preferences to be established for the new application.
Settings are not silently migrated. Bluetooth bonds are not deliberately
rewritten by an application-name or bundle-identifier change.

`bash scripts/build-app.sh` creates an ad-hoc development bundle. Signing with
an embedded provisioning profile requires **SIGN_IDENTITY**,
**PROVISIONING_PROFILE**, and an explicit **SIGN_ENTITLEMENTS** file. Its
application identifier must match the bundle identifier and stated team.
Runtime, signature, and provisioning-profile acceptance still need verification;
a local metadata check does not establish entitlement approval.

Notarization requires **SIGN_IDENTITY** and **NOTARY_KEYCHAIN_PROFILE** supplied
by the developer. No certificate or keychain account is built in. See
[trusted-release requirements](trusted-release.md) before distributing a release.
