# From installation to input in a game

There are two separate checks: **the app receives the controller**, and
**the intended game receives the app's output**. Passing the first does not
prove the second. This fork is a development build, not a universal macOS
controller driver or a notarized consumer release.

## 1. Run the right application

Follow [Build this fork](../README.md#build-this-fork), or use the
`switch2mac-development-app` artifact from a successful macOS workflow for
the exact commit you intend to test. Extract the ZIP and move the app into
Applications before loading its bundled extension. The About window shows
the source revision. Upstream downloads and updates do not contain these
fork changes. Development bundles are ad-hoc signed; normal macOS security
policy still applies. Do not disable Gatekeeper or other system-wide security
controls to install an experimental controller bridge.

Run one bridge at a time. Quit other copies, including the upstream app or
older Python bridge, rather than letting them compete for controllers or ports.

## 2. Connect and verify the physical controller

Launch the app and allow Bluetooth access when requested. For initial setup,
hold the controller's Sync button beside USB-C until its player LEDs sweep.
For a previously bonded controller, try a normal button press first. Open
**Dashboard** and verify button presses **and releases**, both sticks where
present, and trigger travel/clicks separately where supported.

If the controller is absent, check Bluetooth power and the app's Bluetooth
privacy approval. Use the menu's Bluetooth/Privacy Settings shortcuts. A failed
connection is not repaired by changing game mappings or installing an SDL
library. Check the dashboard log and the exact build before changing settings.

## 3. Set up only the output needed by the game

| Intended consumer | Setup | Important limit |
|---|---|---|
| Compatible SDL3 game or Gopher64 | [Corrected SDL library and separate game copy](../sdl/README.md) | The tracked historical dylib is not the corrected build; not a system-wide driver. |
| RetroArch | [Network gamepad instructions](retroarch-integration.md) | No SDL replacement needed; no rumble return path or analog GameCube trigger travel. |
| Supported Chromium web game | [Browser extension instructions](../browser/README.md) | Exact extension ID, opt-in listener, Apply Changes, and tab reload required; no Safari/Firefox package. |

For RetroArch, enable network gamepad input in RetroArch and the matching
output in the app's Dashboard. The default base port is 55400. Use a trusted
network because RetroArch's unauthenticated receiver may listen beyond loopback.

For browser games, **Browser Bridge Settings → Show bundled extension** opens
the installed extension folder. Load it unpacked in the Chromium extension
manager, copy its ID into Browser Bridge Settings, enable output, then
click Apply Changes. Reload the game tab after installing or reloading the
extension. Keep its folder stable; moving an unpacked extension can change its
ID. The extension only injects into sites listed in its manifest.

Do not enable every optional output as a troubleshooting step. The CoreHID
path still requires Apple's restricted entitlement; this fork does not promise
native compatibility with arbitrary games.

## 4. Verify in the intended game

Open the game's own input test or mapping screen and check presses, releases,
sticks, triggers, player assignment, and supported rumble. For multiple players,
verify that each controller controls only the intended player. Then test normal
gameplay, reconnect, and sleep/wake. Stop if releases remain held or controls
reach the wrong player; **Stop All Controller Output** is in the app menu.

If Dashboard input works but game input does not, check the selected output,
its exact library/extension build, configured ports or allowed extension ID,
and the game's mappings. Repeatedly pairing the controller is not the first
step for an output-side problem.

For a useful report, include the About source revision, macOS version,
controller model and firmware if known, Bluetooth/USB transport, output path,
game/browser version, and the exact step that failed. Review logs before sharing;
serial numbers and experimental sensor/NFC/audio data may be sensitive.

## Turn it off or remove it

Use the menu's **Stop All Controller Output** to stop sessions, or quit the app.
Disable unused optional outputs. If Launch at Login was enabled, disable it
before removing the app. Remove the unpacked browser extension when no longer
needed. For Gopher64, quit/delete only the generated `Gopher64-Both.app` copy
and return to the original. Never remove an unrelated game or globally weaken
macOS security to undo this integration.
