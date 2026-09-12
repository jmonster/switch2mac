# Browser bridge

The browser output lets Chromium web games consume controller state from
GameCubed without a system-wide virtual HID device. See
[access and lifecycle](INTEGRATION.md) for listener limits and security details.

```
Controller ──BLE──> GameCubed ──ws://127.0.0.1:24810──> extension ──> navigator.getGamepads()
                            <──────── rumble ─────────────────── vibrationActuator
```

| File | Purpose |
|---|---|
| `extension/manifest.json` | Manifest V3; injection is limited to named game/test sites. |
| `extension/background.js` | Owns the WebSocket and complete connection/state replay for tabs. |
| `extension/bridge.js` | Relays messages between the service worker and page. |
| `extension/shim.js` | Exposes standard-mapping gamepad snapshots and forwards supported rumble. |

## Install

1. Build and run GameCubed. The browser listener is disabled by default.
2. In Chromium, open `chrome://extensions`, enable **Developer mode**, click
   **Load unpacked**, and select `browser/extension` or the folder opened by
   **Browser Bridge Settings → Show bundled extension**. Copy its 32-letter ID.
3. In **Browser Bridge Settings**, enter the ID, enable the bridge, and click
   **Apply Changes**. Empty or invalid IDs do not open a listener. Moving the
   unpacked extension can change its ID.
4. Open <https://hardwaretester.com/gamepad> and verify every control, then test
   the intended game. Reload the extension after editing its files.

No Safari or Firefox package is included. Automated Node and macOS WebSocket
tests do not replace physical-controller and real-browser/game testing.

The listener accepts only configured extension Origins. Other native programs
can forge Origin, so this does not authenticate software running as the same
user. GameCube HD rumble is not forwarded; verified preset rumble remains
unavailable. Other models' effects refresh only for their requested lifetime,
within the native session's existing 0.5-second intent timeout.

## Live settings

Applying changes closes clients, stops their owned rumble, invalidates queued
input from the previous configuration, and restarts the loopback listener.
The extension reconnects without re-pairing the controller. Unchanged settings
do not restart it. Bind failures retry while enabled; disabling cancels retries.
No input reports are queued or encoded when disabled. Four small lifecycle/name
records are retained so enabling does not require a controller reconnect.

The settings window validates the entire entry, with at most eight IDs.
Enabled state and IDs are saved together as `browserBridgeConfiguration`.
Legacy preferences are read only until that dictionary exists. Malformed new
settings disable access rather than restoring an older allowlist. A saved
setting does not prove that the listener bound or that a game received input.

## Troubleshooting

Check the dashboard log for `opt-in browser bridge on 127.0.0.1:24810`. Verify
the toggle and exact extension ID, then click **Apply Changes**. A second copy
can occupy the port. The controller must appear connected in Dashboard before
its input can reach the browser.

Confirm that the extension is enabled and the site matches its manifest.
Reload game tabs after loading or reloading the extension: the shim installs
when the page loads. The service-worker console is available under
`chrome://extensions` → Inspect views. Include its errors, browser/OS version,
and the app's source revision when reporting a problem.

## Layout

The positional layout maps Switch B/A/Y/X to standard gamepad indices 0/1/2/3.
Set `NINTENDO_LABELS` to `true` in `shim.js` for label-based mapping, then reload
the extension. Check the GameCube's different physical layout in the game.

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

App-side remapping runs before this output. Check trigger travel, physical
clicks, and per-game mappings on hardware.

## Identity and sites

The default Nintendo compatibility persona is `Vendor: 057e Product: 2069`,
not a claim about every model's physical product ID. `PERSONA_DEFAULT` in
`shim.js` selects the Xbox persona. A site's override is
`localStorage.ftcwPersona = 'xbox'` (or `'nintendo'`), followed by reload.

The extension injects only into sites listed in its manifest. Add only intended
game sites and reload. Multiple tabs receive the same controllers. Native-client
rumble ownership does not arbitrate pages sharing an extension connection.

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

`b` retains the `Switch2.Buttons` layout. Approved clients receive hello,
complete current identity/name, and the last state for each active player.
Renames preserve the connection record in replay. Controller protocol decoding
runs in the native application.
