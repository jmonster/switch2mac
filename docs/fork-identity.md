# Fork identity and update policy

This build uses `io.github.jmonster.switch2mac` and the bundle name
**Finally the Controller Works (jmonster)**. It can coexist with upstream
without sharing its standard UserDefaults domain or overwriting the same
application filename. Original author/copyright/protocol credits are retained.

The fork's built-in updater is disabled, including saved feed overrides and
its download/install entry points. No upstream release may silently replace
this build. This does not weaken or substitute the existing signature verifier;
there is no approved fork update trust path yet. Install reviewed builds
manually. Enabling automatic updates later requires an explicit decision on
the fork's own signing identity, feed, bundle verification and rollback policy.

The changed bundle identity means macOS privacy approvals, launch-at-login
registration and preferences need to be established for this app. Settings
are not silently migrated from upstream; use a reviewed export/import. Existing
Bluetooth bonds are not deliberately rewritten by this metadata change.

`bash scripts/build-app.sh` produces the distinct ad-hoc development bundle.
Signing with an embedded profile requires **SIGN_IDENTITY**,
**PROVISIONING_PROFILE**, and an explicit **SIGN_ENTITLEMENTS** file whose
application identifier matches the fork bundle ID and stated team. The script
never silently consumes upstream's entitlement plist. Passing that local check
does not prove Apple granted the capability or that a provisioning profile is
valid; runtime/signature/profile acceptance must still be verified.

The notarization script has no built-in certificate or keychain account. It
requires the owner to supply SIGN_IDENTITY and NOTARY_KEYCHAIN_PROFILE and
uses the new bundle/zip names. It generates no appcast, tag, or release.
No production signing, entitlement approval or notarization was performed for
this PR. Metadata, disabled-feed and early signing-refusal tests run in CI,
alongside an actual ad-hoc app build with the new identifier and output path.
