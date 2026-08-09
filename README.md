# Finally the Controller Works

Nintendo Switch 2 controllers (Pro Controller 2, Joy-Con 2, NSO GameCube) on
macOS, over Bluetooth, as a native menu-bar app. The first of its kind.

## What it does

- Speaks the community-reverse-engineered Switch 2 BLE protocol directly via
  CoreBluetooth (no drivers, no SMP pairing — the controllers refuse it).
- Holds up to 4 controllers at once (player LEDs 1-4), auto-reconnecting on
  any button press once a controller has been paired (Sync button) to this Mac.
- Sends the 1 Hz keep-alive write that stops macOS from silently dropping the
  link ~15 s in (empirically discovered; Linux/Windows don't need it).
- Publishes controllers to games two ways:
  1. **CoreHID virtual gamepads** (macOS 15+): every app on the system sees a
     normal HID gamepad. Requires signing with the
     `com.apple.developer.hid.virtual.device` entitlement (Apple Developer).
  2. **UDP compat streams** (`udp://127.0.0.1:24800-24803`, one port per
     player): consumed by our patched SDL's `SDL_S2UDP` joystick backend
     (see the Gopher64-Both setup). Carries rumble back to the controller.
- Live log with BLE gap diagnostics, battery readout, launch-at-login.

## Build

```sh
./scripts/build-app.sh                    # ad-hoc: everything except virtual HID
SIGN_IDENTITY="Developer ID Application: …" \
PROVISIONING_PROFILE=path/to.provisionprofile \
  ./scripts/build-app.sh                  # full build incl. virtual gamepads
```

Output: `build/Finally the Controller Works.app`. Swift 6 toolchain,
macOS 15+ target, no external dependencies.

## Architecture

```
Controller ──BLE──> BridgeEngine ──> ControllerSession (per slot)
                       │  handshake, keep-alive, decode, rumble
                       ▼
              ControllerOutputSink protocol
               ├── VirtualHIDSink (CoreHID; entitlement-gated)
               └── UDPHub        (SDL-compat, ports 24800-24803)
```

- `Protocol/Switch2Protocol.swift` — the wire protocol, transport-free.
- `Bluetooth/` — CoreBluetooth engine + per-controller session state machine.
- `Output/` — the two sinks.
- `UI/` — SwiftUI dashboard (status cards + live log) and menu bar.

## Credits

Protocol research: trevlars/switch2-controllers-linux (MIT),
Nadeflore/switch2-controllers, and the wider Switch 2 RE community.
macOS keep-alive discovery and CoreBluetooth port: this project.
