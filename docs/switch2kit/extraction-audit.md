# Switch2Kit extraction audit

Baseline: `c98a15c5673d6d2f989e166dfc1056f4480d5da1` on GitHub (repository ID 1362965573, renamed from jmonster/switch2mac to jmonster/Switch2Kit during this work). No developer macOS working tree is accessed. The newer identity-routed rumble tests and finite GameCube preset diagnostic in this revision must be retained.

## Existing dependency boundary

The package currently has one executable target. `Switch2Protocol.swift` supplies advertisement validation, model IDs, command framing, calibration, input decoding, and motor packet construction. `ControllerSession.swift` supplies GATT discovery, ordered handshake, command correlation, first-report readiness, keep-alive, write backpressure, and terminal teardown. It also reads application LED preferences and contains experimental channel/audio operations; those are extraction seams, not reusable policy.

`BridgeEngine.swift` combines CoreBluetooth discovery/connection/retry/session ownership with logical-player/output routing. Logical Joy-Con pairing, serial-keyed configuration, four-player assignment, idle policy, keyboard/mouse/gesture processing, screenshots, and output sinks remain application responsibilities. Physical controller support must not inherit the four-player limit.

The output implementations (`UDPHub`, `WebSocketHub`, `NetworkGamepadSink`, and `VirtualHID`) depend on decoded state and model/button values, not GATT ownership. Keyboard/mouse posting and permission/context handling stay outside the library. Dashboard, sensor/game visualizers, settings, notifications, updater, login-item, and menu lifecycle remain in the executable.

`DiscoveryPolicy.swift` combines a deterministic discovery window with app-specific UserDefaults persistence. Generation-checked expiry belongs at the controller boundary; storage keys and persistence decisions belong to the host. `LogStore.swift` has bounded queues but defaults to writing under Library/Logs. Switch2Kit needs independent bounded diagnostics with no automatic file output.

Existing tests compile production decoder/session/lifecycle methods against fakes and exercise application adapters. Moving a file must not silently remove these behavioral assertions. macOS CI, not Linux fake builds, is the authority for Apple SDK builds.

## Identity discrepancy

The requested bundle ID is `wabisabi.ware.gamecubed`. At the GitHub baseline, `Resources/Info.plist` contains `io.github.jmonster.switch2mac`; the build script names `Finally the Controller Works (jmonster).app`. README and `docs/app-identity.md` describe another identity. `docs/fork-identity.md` is absent; the current signing guide is `docs/app-identity.md`.

A correction to the explicitly requested ID must be called out as an identity change relative to this GitHub baseline. Keep signing-input checks, disabled updater entry points, privacy usage text, and explicit notarization credentials. A changed ID can require fresh privacy approvals and login-item registration; do not silently migrate defaults or bonds.

## Redistribution blocker

**No application-wide redistribution license is supplied in this revision.** `CREDITS.md` explicitly says its acknowledgments do not grant a license. Research credits and third-party notices do not establish permission to relicense the application or extracted Swift implementation. Keep attribution, add no invented license, and do not advertise source or XCFramework distribution as legally cleared. Local engineering and a locally usable package can proceed; publication requires rights-holder/provenance review.

## Verification discipline

Record actual outcomes at the final PR head. A successful baseline workflow, a synthetic Bluetooth test, an archive script, or a framework-shaped directory is not evidence that the extracted library, dashboard, sample, or XCFramework builds. Pairing, button-wake, sleep/wake, latency, and physical rumble require separate hardware evidence.
