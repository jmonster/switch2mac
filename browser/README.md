# The browser bridge

This optional output lets supported Chromium web games consume controller
state from the native menu-bar app without a system-wide virtual HID device.
It adapts Andrei-Kondrykau's browser-bridge contribution; the current fork's
access and lifecycle changes are described in [FORK-INTEGRATION.md](FORK-INTEGRATION.md).

```
Controller ──BLE──> menu-bar app ──ws://127.0.0.1:24810──> extension ──> navigator.getGamepads()
                                <──────── rumble ─────────────────── vibrationActuator
```

| File | Purpose |
|---|---|
| `extension/manifest.json` | Manifest V3; injection is limited to named game/test sites. |
| `extension/background.js` | Owns the WebSocket and complete connection/state replay for tabs. |
| `extension/bridge.js` | Relays messages between the service worker and page. |
| `extension/shim.js` | Exposes standard-mapping gamepad snapshots and forwards supported rumble. |

## Install in this fork

1. Build and run this branch's menu-bar app. The browser listener is disabled
   by default; the upstream release does not include these fork repairs.
2. In a Chromium browser open `chrome://extensions`, enable **Developer mode**,
   click **Load unpacked**, and select `browser/extension`. Copy its 32-letter ID.
3. Open **Browser Bridge Settings** in the menu-bar app. Enter that extension
   ID, enable the bridge, and click **Apply Changes**. Empty/invalid IDs do not
   open a listener. Moving the unpacked extension can change its ID.
4. Open <https://hardwaretester.com/gamepad> and verify every control, then
   test the intended game. Reload the extension after editing its files.

The provided extension targets Chromium; no Safari or Firefox package is
included. The original contributor reported Xbox Cloud Gaming with a Pro
Controller 2. This fork has automated Node and real macOS WebSocket tests,
not a new physical-controller/cloud-game acceptance result.

The listener accepts only configured extension Origins, not arbitrary
websites. Local native programs can forge Origin, so this is not authentication
against other software running as the same user. See the integration notes
for connection, message, and pending-send limits.

GameCube HD rumble is intentionally not forwarded; verified preset rumble
remains unavailable. Other models' effects refresh only for their requested
lifetime, within the native session's existing 0.5-second intent timeout.

## Live settings

Applying changes closes existing clients, stops their owned rumble, invalidates
queued input from the previous configuration, and restarts the loopback listener.
The extension reconnects without re-pairing the controller. Unchanged settings
do not restart it. Bind failures retry while enabled; disabling cancels retries.
No input reports are queued or encoded when disabled. Four small lifecycle/name
records are retained so enabling does not require a controller reconnect.

The settings window validates the entire entry (at most eight IDs), rather than
silently keeping valid IDs from an invalid list. Enabled state and IDs are saved
as one `browserBridgeConfiguration` preference dictionary. Legacy preferences
are read only until this new value exists. Malformed new settings disable access
rather than restoring an older allowlist. A saved setting is not proof that a
listener bound, the extension connected, or a game received input.

## Troubleshooting

Check the dashboard log for `opt-in browser bridge on 127.0.0.1:24810`.
Verify the toggle and exact extension ID, then click **Apply Changes**. A second running
copy can occupy the port. The controller must separately appear connected in
the dashboard before its input can reach the browser.

Confirm that the extension is enabled and the current site matches an entry
in `manifest.json`. After loading/reloading the extension, reload game tabs:
the shim installs when the page loads. The service-worker console is available
under `chrome://extensions` → Inspect views. Include its errors, browser/OS
version and the tested app commit when reporting a problem.

## Layout

The inherited positional layout maps Switch B/A/Y/X to standard gamepad
indices 0/1/2/3. Set `NINTENDO_LABELS` to `true` in `shim.js` for label-based
mapping, then reload the extension. Check the GameCube's different physical
layout in the intended game rather than assuming Pro Controller ergonomics.

| Standard index | Xbox name | Switch 2 control |
|---|---|---|
| 0 / 1 / 2 / 3 | A / B / X / Y | B / A / Y / X |
| 4 / 5 | LB / RB | L / R |
| 6 / 7 | LT / RT | ZL / ZR, with analog values on GameCube |
| 8 / 9 | View / Menu | − / + |
| 10 / 11 | LS / RS | stick clicks |
| 12–15 | D-pad | D-pad |
| 16 | Xbox | Home |
| 17 | Share | Capture |
| 18 / 19 / 20 | — | C / GL / GR, only with `EXTRA_BUTTONS = true` |

App-side remapping runs before this output. Trigger travel, physical clicks,
and per-game mappings still require hardware acceptance.

## Identity and sites

The default is a Nintendo compatibility persona (`Vendor: 057e Product: 2069`),
not an assertion of every model's physical product ID. `PERSONA_DEFAULT` in
`shim.js` can select the inherited Xbox persona. A site's local override is
`localStorage.ftcwPersona = 'xbox'` (or `'nintendo'`), followed by reload.

The extension injects only into the sites listed in its manifest. Adding a
site broadens that access; add only intended game sites and reload. Multiple
tabs receive the same controllers. Native-client rumble ownership does not
arbitrate competing pages sharing the same extension connection.

## Protocol

JSON text frames on `ws://127.0.0.1:24810`, loopback only:

```
hub → page   {"t":"hello","v":1}
             {"t":"connected","slot":0,"model":"Pro Controller 2","name":"…"}
             {"t":"name","slot":0,"name":"…"}
             {"t":"state","slot":0,"seq":123,"b":<buttons u32>,
              "lx":…, "ly":…, "rx":…, "ry":…, "lt":0-255,"rt":0-255}   (+y = up)
             {"t":"disconnected","slot":0}
             {"t":"ping"}
page → hub   {"t":"rumble","slot":0,"strong":0…1,"weak":0…1}
```

`b` retains the app's Switch2.Buttons layout. Approved clients receive hello,
complete current identity/name, and the last state for each active player.
A rename no longer replaces the connection record in replay. All controller
protocol decoding remains in the existing native implementation.
