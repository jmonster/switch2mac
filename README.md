# GameCubed

A macOS menu-bar bridge for Switch 2 Pro Controller, Joy-Con 2, and the NSO
GameCube controller.

**Start here:** [From installation to input in a game](docs/quick-start.md).
Connecting a controller and getting its input into a game are separate steps.

## Build

Use a macOS development environment with Swift 6 and Apple SDKs that provide
CoreHID. The build check uses macOS 26; macOS 15 is the declared minimum but
has not yet completed runtime qualification.

Download the source using GitHub's **Code** menu. From the source directory:

```sh
bash tests/run.sh
bash scripts/build-app.sh
```

The output is `build/GameCubed.app`. Development builds are ad-hoc signed,
not notarized releases. Install builds manually; automatic updates are disabled.
See [application identity and signing](docs/app-identity.md).

Successful macOS build checks also provide a development-app artifact with an
app ZIP, SHA-256 checksum, and source revision. Extract the ZIP and move the app
to Applications before loading its bundled browser extension. The About window
shows the source revision and whether the build includes local modifications.

## Choose an output

| Game or application | Setup | Limits |
|---|---|---|
| Compatible SDL3 game or emulator | [SDL bridge](sdl/README.md) | Requires the custom library; not a system-wide driver. Rebuild it after changing SDL patches. |
| RetroArch | [Network gamepad output](docs/retroarch-integration.md) | Disabled by default. No rumble return path; GameCube trigger travel maps to digital L2/R2. Use a trusted network. |
| Chromium web game | [Browser bridge](browser/README.md) | Disabled by default. Allow the extension's exact ID in Browser Bridge Settings and click Apply Changes. No Safari/Firefox package. |

CoreHID virtual-controller output requires Apple's restricted entitlement.
Verify compatibility in the intended game rather than assuming that a Bluetooth
connection or successful build establishes it. Run only one bridge against a
controller at a time.

The [Pro Controller guide](docs/pro-controller-support.md) covers buttons,
calibration, rumble, motion sensors, and output capabilities. NFC and
headphone/microphone audio are experimental. The browser output does not forward
GameCube HD-motor commands. The Dashboard offers a direct GameCube preset test,
not GameCube rumble from games; physical vibration still needs hardware
verification. See [rumble tests and limits](docs/rumble.md). Check trigger travel
and digital clicks separately in the game.

## Testing and reporting problems

`bash tests/run.sh` runs the protocol and available output suites. SDL
regressions build the pinned SDL source and exercise the joystick driver;
macOS checks build and verify the complete app bundle. Automated tests do not
replace hardware pairing, reconnection, sleep/wake, multiplayer, latency, or
real-game testing.

Include the source revision, macOS and controller firmware versions, transport,
output backend, and observed behavior when reporting a problem. Keep fixes
focused and include a reproducer. Review logs for sensitive data before sharing.

## Credits

See [CREDITS.md](CREDITS.md) for contributors and third-party notices.
