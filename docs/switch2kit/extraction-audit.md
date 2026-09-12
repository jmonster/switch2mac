# Switch2Kit extraction audit

Baseline: `c98a15c5673d6d2f989e166dfc1056f4480d5da1` from GitHub, including the September 12 direct-rumble routing fixes. No developer's local working tree is used. The exact baseline was obtained from the `tested-source` artifact of macOS validation run `34710251916`; artifact SHA-256: `6f5823c986b609d6abdade39dd4532ec093d62e70edb55c7566f9c087d2702d0`.

This is a work-in-progress audit, not a claim that extraction or validation is complete.

## Identity discrepancy — do not silently migrate

The requested identity is `wabisabi.ware.gamecubed`, but the GitHub baseline's `Resources/Info.plist` contains `io.github.jmonster.switch2mac` and names the application `Finally the Controller Works (jmonster)`. `scripts/build-app.sh` builds that application. Meanwhile README and `docs/app-identity.md` describe GameCubed, with the latter naming yet another identifier, `io.github.switch2mac.gamecubed`. `docs/fork-identity.md` does not exist in this baseline; `docs/app-identity.md` is its documented replacement.

The controller-library extraction must not silently change the actual plist, entitlements, signing inputs, privacy identity, login registration, or disabled updater. The requested bundle identifier cannot truthfully be described as already preserved in this remote baseline. An identity migration is separate from extraction.

## Dependency and ownership inventory

The original SwiftPM graph has one executable target and no dependencies. Its source-level graph crosses the following boundaries:

| Sources | Controller-library responsibility | Application responsibility |
| --- | --- | --- |
| `Protocol/Switch2Protocol.swift` | Advertisement validation, model IDs, command framing, identity decoding, input decoding, calibration, motor packets | Remapping display labels and experimental sensor-profile selection policy |
| `Bluetooth/ControllerSession.swift` | Service/characteristic discovery, correlated bounded command queue, ordered handshake, bonding, first-report readiness, calibration, state, keep-alive, rumble, terminal teardown | Reading `controllerSettings` for LED preferences must be removed |
| `Bluetooth/BridgeEngine.swift` | CoreBluetooth central, admission, connection deadlines, bounded retry cache, cancellation ownership, stale-input detection | Four logical players, eight-unit dashboard limit, Joy-Con links, remembered player order, settings, names, idle/pointer policy, screenshots, sink routing, party games, visualizer delivery |
| `Runtime/DiscoveryPolicy.swift` | Ready-set and replaceable-window state machine | UserDefaults keys, persistence, settings UI |
| `Logging/LogStore.swift` | None; library needs an independent bounded diagnostic interface | Shared dashboard log store, explicit file persistence and rotation |
| `Output/*` | None | CoreHID, UDP, browser/WebSocket, RetroArch, keyboard, mouse, gestures |
| `Runtime/*`, `UI/*`, `FTCWApp.swift` | Immutable controller values are inputs only | App lifecycle, permissions UI, settings, support/status, runtime qualification, updater, launch at login |

NFC/audio/haptic-research orchestration currently spans the engine and session. It must be separated from the stable API, while retaining the dashboard actions through an explicitly unsupported experimental product. The stable product must not acquire app defaults, file logging, UI/output dependencies, or a required singleton.

## Invariants to retain

Advertisement admission validates Nintendo company and vendor IDs plus the supported product ID, not a peripheral name. Handshake response subscription precedes commands; identity precedes actuator selection; readiness requires handshake completion and an actual input report. Commands remain atomic, correlated, FIFO and bounded. Cancellation retires a session before requesting asynchronous radio cancellation; a terminal callback releases peripheral ownership. Retry caches and retry timers are bounded. GameCube must never receive Pro/Joy-Con HD-motor packets.

The existing source-extraction regression suites exercise production methods against fake Bluetooth boundaries. They are not physical-controller evidence and must not be replaced with tests of reimplemented algorithms.

## Redistribution blocker

`CREDITS.md` says an application-wide license has not been supplied, and that acknowledgments do not grant permission or relicense contributed code. Protocol-source comments and third-party project licenses do not, by themselves, license the application's Swift implementation. Retain all notices; do not add a license or claim redistribution permission. Upstream provenance and any unresolved distribution restrictions must be reported alongside locally usable source and build tooling.
