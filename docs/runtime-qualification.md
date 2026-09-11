# Runtime compatibility evidence

The package and bundle continue to declare macOS 15.0. A deployment declaration
is not evidence that every macOS 15 patch, permission flow or device works.
The new **Packaged macOS runtime qualification** workflow builds and executes the
actual packaged app on the hosted macOS 15 and 26 images, on Apple silicon and
Intel. It records the exact OS patch, architecture, source revision, SDK metadata
and Xcode used. Consult the artifact for a particular commit; do not interpret a
runner's major-version label as a test of 15.0, or one architecture as universal.

The `--runtime-check` entry runs before constructing the SwiftUI app or delegate.
It checks bundle identity, revision, architecture and minimum-version metadata,
then exercises the production report parser's malformed-input boundary and an
endian helper. The wrapper verifies the signature and compares package/plist and
Mach-O deployment metadata. It writes no preferences, opens no listeners, starts
no Bluetooth manager, grants no permissions and claims no physical/game/HID
entitlement acceptance. It exits on completion; the normal launch path is unchanged.

On a real Mac, after building this commit:

```sh
bash tests/runtime-qualification/run.sh
bash scripts/build-app.sh
bash scripts/check-runtime.sh
```

macOS 15 images currently default to an older compiler, so that matrix explicitly
selects the installed Xcode 26.3 while retaining the macOS 15 **runtime**. Missing
SDKs fail visibly; no download of an unreviewed toolchain or silent runtime skip
is performed. Newer compiler APIs must still be availability-guarded. Official
runner inventories and labels:
https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md
https://docs.github.com/en/actions/reference/runners/github-hosted-runners

Remaining acceptance: test normal launch and UI on the exact earliest claimed
OS patch, first-run privacy approvals, login registration, sleep/wake, devices
and actual games. If those tests establish a higher minimum, change Package.swift,
Info.plist, this validator and user documentation together. A successful loader
probe alone does not close those qualification gates.
