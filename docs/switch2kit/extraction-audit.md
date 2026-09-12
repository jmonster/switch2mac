# Switch2Kit extraction audit

Baseline: `c98a15c5673d6d2f989e166dfc1056f4480d5da1` in
`jmonster/Switch2Kit` (formerly `jmonster/switch2mac`). The work is performed
on a separate GitHub branch, not a user's macOS checkout. The exact baseline
source was retrieved from the existing macOS CI `tested-source` artifact.

## Redistribution blocker

The repository has no application-wide license. `CREDITS.md` explicitly says
that acknowledgments do not grant a new license. Protocol-research references
and licenses of individual upstream projects do not establish permission to
redistribute the Swift application or an extracted framework. Existing notices
must be retained. No new license is granted by this extraction. Until provenance
and permission are resolved, do not treat an XCFramework build as clearance for
redistribution.

## Identity discrepancy in the GitHub baseline

The requested application identifier is `wabisabi.ware.gamecubed`. However,
`Resources/Info.plist` at the baseline contains `io.github.jmonster.switch2mac`
and the display name `Finally the Controller Works (jmonster)`. The build script
uses that display name, while README and `docs/app-identity.md` describe
`GameCubed.app` and the latter describes `io.github.switch2mac.gamecubed`.
`docs/fork-identity.md` is absent; the signing guide is `docs/app-identity.md`.

The extraction must not silently reconcile these distinct identities. Signing,
notarization, updater behavior, entitlements, and privacy identity are separate
from the library boundary. Any identity change requires an explicit, documented
change, not a side effect of moving protocol code.

## Dependency graph inspected before moving sources

The baseline Swift package has one executable target and no dependencies.
A source-level declaration/reference and import inventory covers all 46 Swift
source files. Its important edges are:

| Component | Current dependencies | Destination/responsibility |
| --- | --- | --- |
| `Switch2Protocol.swift` | Foundation; process environment for experimental sensor selection | Single internal decoder/framer/calibration implementation in Switch2Kit; host chooses experimental configuration |
| `ControllerSession.swift` | CoreBluetooth, IOBluetooth, protocol types, application logging and LED preferences | Single internal session implementation; remove host preferences and LogStore dependency |
| CoreBluetooth portions of `BridgeEngine.swift` | Sessions, discovery policy, retry/retirement timers | Queue-confined physical-controller transport in Switch2Kit |
| Logical-player portions of `BridgeEngine.swift` | Controller configuration, output sinks, input context, gestures, visualization, notifications | Application adapter consuming immutable kit state; retain four-player policy and Joy-Con grouping |
| NFC/audio portions of engine/session | Command channel, GATT notifications, bounded audio queue; app notifications/files | Unsupported experimental access isolated from stable public API; application retains experiment UI and persistence |
| `DiscoveryPolicy.swift` | UserDefaults plus queue/timer | Reusable discovery decisions separated from application preference storage |
| `LogStore.swift` | Combine, os.Logger, bounded mutex buffers, Library file storage | Remains in application; library gets an independent bounded, redacted optional-handler logger |
| Output sinks | Protocol/state values, network/CoreHID/CoreGraphics APIs, application configuration | Remain exclusively in application |
| SwiftUI/UI/runtime policy | Bridge engine, settings, outputs, application identity | Remain exclusively in application |

`ControllerSession` already serializes commands, bounds the command queue,
correlates replies, waits for the first input report before readiness, rejects
post-retirement work, and uses a one-second keep-alive. `BridgeEngine` already
protects cancellation ownership, phase deadlines, bounded retry caches,
replacement discovery windows, and stale sessions. Preserve these invariants
rather than replacing them with an untested simplified connect loop.

The latest baseline also includes controller-identity-based direct rumble tests,
independent Pro motor routing, and the finite GameCube preset diagnostic. Do not
regress that commit or advertise GameCube game-rumble support.

## Verification policy

macOS compilation, packaging and framework inspection run in GitHub Actions.
Linux/fake-boundary tests are not evidence of Apple-SDK compilation or physical
controller behavior. A draft PR remains incomplete until its implementation,
migration and required build checks have been reported. No physical Bluetooth
adapter or controller has been used in this session.
