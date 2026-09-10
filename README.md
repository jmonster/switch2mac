# switch2mac — jmonster development fork

A macOS menu-bar bridge for Switch 2 Pro Controller, Joy-Con 2 and the NSO
GameCube controller, based on Peter Sharma's
[Finally the Controller Works](https://github.com/Peterksharma/switch2mac).
This fork concentrates on input delivery, controller ownership and tested
output integrations. It is not a Nintendo product or an official upstream release.

**Start here:** [From installation to input in a game](docs/quick-start.md).
Bluetooth connection and game-output setup are separate steps.

## Switch 2 Pro Controller

The [Pro Controller support guide](docs/pro-controller-support.md) covers all
21 buttons, independent stick calibration and two-motor rumble, output-backend
capabilities, the rebuilt SDL gyro/accelerometer path, and hardware acceptance
limits. NFC and headphone/microphone audio remain experimental. The tracked
historical SDL binary must be rebuilt to include source changes.

## Build this fork

Use a macOS development environment with Swift 6 and Apple SDKs that provide
CoreHID. The hosted build check uses macOS 26; the package currently declares
macOS 15, but an actual macOS 15 runtime has not been qualified here.

```sh
git clone https://github.com/jmonster/switch2mac.git
cd switch2mac
bash tests/run.sh
bash scripts/build-app.sh
```

The output is `build/Finally the Controller Works (jmonster).app`. Source on
an unmerged PR branch must be checked out before building that PR's changes.
The default build is ad-hoc signed for development, not a notarized release.
Upstream's downloadable application and automatic-update feed do not contain
this fork's changes. No physical-controller or game acceptance is implied by
a successful build or test run.

This fork uses a separate bundle identifier, `io.github.jmonster.switch2mac`,
and disables automatic updates, including saved feed overrides. Establish
Bluetooth/privacy approvals, preferences and login-item registration for this
app separately. Do not run two bridges against the same controller at once.
See [fork identity and signing policy](docs/fork-identity.md).

Successful macOS CI runs provide a **switch2mac-development-app** artifact containing
an app ZIP, SHA-256 checksum and source revision. Extract it and move the app to
Applications before loading its bundled browser extension. These are ad-hoc
development builds, not notarized releases; normal macOS security policy applies.
The About window identifies the source revision and locally modified builds.

## Choose an output for the intended game

- **SDL3 games:** the [SDL bridge](sdl/README.md) uses a custom library, not a
  system-wide driver. The tracked upstream dylib is a historical binary; a
  change to a source patch does not update it. Use the corrected library built
  from the reviewed patch set, and check its source revision. The Gopher64
  helper creates a separate ad-hoc-signed copy, not a modification of the original.
- **RetroArch:** [network gamepad output](docs/retroarch-integration.md) is
  disabled by default. It does not require replacing SDL, but its legacy UDP
  protocol has no rumble return path and maps GameCube trigger travel to
  digital L2/R2. Enable the unauthenticated receiver only on a trusted network.
- **Chromium web games:** the [browser bridge](browser/README.md) is disabled
  by default. Load the supplied extension, allow its exact ID in Browser Bridge
  Settings, then relaunch the app. No Safari/Firefox package is provided.

CoreHID virtual-controller output requires Apple's restricted entitlement;
this fork has not established approval or universal game compatibility.
The browser path deliberately does not forward GameCube HD-motor commands;
verified GameCube preset rumble remains an outstanding hardware/protocol task.
Check analog trigger travel and digital clicks separately in the actual game.

## Validation and contributions

`bash tests/run.sh` runs the checked-in protocol and available output suites.
Tests use synthetic controller reports, simulated radio boundaries and, where
applicable, real localhost sockets. SDL regressions separately build the pinned
SDL source and exercise the actual joystick driver. Hosted macOS checks build
the complete app with Apple frameworks and verify the ad-hoc bundle.

Keep fixes scoped and attach a reproducer. Report the exact commit, macOS and
controller firmware, transport, output backend and observed behavior. Hardware
pairing/reconnection, sleep/wake, latency, multiplayer and real-game testing
are separate from automated regression coverage.

Original application and protocol research: **Peter Sharma** and the community
contributors credited in [research/PROTOCOL.md](research/PROTOCOL.md).
Optional browser output is adapted from **Andrei-Kondrykau**, and RetroArch
output from **vialoh**, with source revisions in their integration notes.
[Support the original author](https://buymeacoffee.com/peterksharma).
The SDL modifications retain their [separate license/provenance](sdl/README.md).
Application-wide licensing still needs clarification with upstream; this fork
does not invent a new license or relicense contributed work.
