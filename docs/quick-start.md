# From installation to input in a game

There are two separate checks: **GameCubed receives the controller**, and
**the intended game receives GameCubed's output**. Passing the first does not
prove the second. GameCubed is not a universal macOS controller driver.

## 1. Install and launch

Follow the [build instructions](../README.md#build), or use the development-app
artifact from a successful macOS build check for the revision you intend to
test. Extract the ZIP and move `GameCubed.app` into Applications before loading
its bundled extension. The About window shows the source revision.

Development bundles are ad-hoc signed; normal macOS security policy still
applies. Do not disable Gatekeeper or other system-wide security controls.
Run one bridge at a time so multiple copies do not compete for controllers or
ports.

## 2. Connect and verify the controller

Launch GameCubed and allow Bluetooth access when requested. For initial setup,
hold the controller's Sync button beside USB-C until its player LEDs sweep.
For a previously bonded controller, try a normal button press first. Open
**Dashboard** and verify button presses **and releases**, both sticks where
present, and trigger travel/clicks separately where supported.

If the controller is absent, check Bluetooth power and the application's
Bluetooth privacy approval. Use the menu's Bluetooth/Privacy Settings shortcuts.
A failed connection is not repaired by changing game mappings or installing an
SDL library. Check the dashboard log before changing settings.

## 3. Set up the output needed by the game

| Intended consumer | Setup | Important limit |
|---|---|---|
| Compatible SDL3 game or Gopher64 | [SDL library and separate game copy](../sdl/README.md) | Build the library from the supplied patches; not a system-wide driver. |
| RetroArch | [Network gamepad instructions](retroarch-integration.md) | No SDL replacement needed; no rumble return path or analog GameCube trigger travel. |
| Chromium web game | [Browser extension instructions](../browser/README.md) | Exact extension ID, enabled listener, Apply Changes, and tab reload required; no Safari/Firefox package. |

For RetroArch, enable network gamepad input in RetroArch and the matching
output in Dashboard. The default base port is 55400. Use a trusted network:
RetroArch's unauthenticated receiver may listen beyond loopback.

For browser games, **Browser Bridge Settings → Show bundled extension** opens
the installed extension folder. Load it unpacked in Chromium's extension
manager, copy its ID into Browser Bridge Settings, enable output, and click
**Apply Changes**. Reload the game tab after installing or reloading the
extension. Keep its folder stable; moving an unpacked extension can change its
ID. The extension only injects into sites listed in its manifest.

Do not enable every optional output as a troubleshooting step. CoreHID output
requires Apple's restricted entitlement and does not establish compatibility
with arbitrary games.

## 4. Verify in the game

Open the game's input test or mapping screen. Check presses, releases, sticks,
triggers, player assignment, and supported rumble. For multiple players,
verify that each controller controls only the intended player. Test normal
gameplay, reconnect, and sleep/wake. Stop if releases remain held or controls
reach the wrong player; **Stop All Controller Output** is in the app menu.

If Dashboard input works but game input does not, check the selected output,
its library/extension build, configured ports or allowed extension ID, and
the game's mappings. Repeated pairing is not the first step for an output-side
problem.

Include the About source revision, macOS version, controller model and firmware,
Bluetooth/USB transport, output path, game/browser version, and the failing
step in a problem report. Review logs before sharing: serial numbers and
experimental sensor/NFC/audio data may be sensitive.

## Turn it off or remove it

Use **Stop All Controller Output** to stop sessions, or quit GameCubed. Disable
unused optional outputs. Disable Launch at Login before removing the app, and
remove the unpacked browser extension when no longer needed.

For Gopher64, quit/delete only the generated `Gopher64-Both.app` copy and return
to the original. Never remove an unrelated game or globally weaken macOS
security to undo this integration.
