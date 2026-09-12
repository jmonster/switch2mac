# Switch 2 Pro Controller support

GameCubed recognizes Nintendo VID `057e`, PID `2069`. This document describes
implemented paths and their limits; it is **not** a physical-controller
acceptance certificate. Tests use synthetic reports, fake Apple radio
boundaries, and real loopback sockets. Record the commit, macOS version,
controller firmware, transport and output backend when reporting results.

## Bluetooth gamepad path

Hold Sync to advertise for pairing, then connect through this app. Do not run
another bridge against the same controller. The app discovers proprietary GATT
characteristics, subscribes to command replies, validates controller identity,
reads both stick calibrations, sets player LEDs, enables the Pro feature mask
`a7`, performs application-level bonding when the Mac's Bluetooth address is
available, and subscribes to input. A session is ready only after a valid report.
This is not macOS Bluetooth SMP pairing. Button-wake reconnection still depends
on the controller's stored host address and macOS radio behavior.

All 21 physical buttons are decoded: A/B/X/Y, four D-pad directions, L/R,
ZL/ZR, Minus/Plus, Home, Capture, C, both stick clicks, and GL/GR. ZL/ZR are
**digital**, not analog trigger travel. Both sticks have independent user →
factory → nominal calibration fallback. Empty, truncated or zero-span
calibration cannot silently freeze an axis. The nominal fallback is usable but
is not factory accuracy.

C, GL and GR are independently remappable in Controller Settings, including
to ZL/ZR or keyboard actions. C is a button, not Nintendo GameChat integration.
Battery voltage, charging/current, IMU temperature, gyro, accelerometer and
magnetometer values remain available to the app; not every output protocol
has fields for all telemetry.

## Rumble

Game strong/weak magnitudes drive separate Pro left/right motor blocks rather
than a duplicated mono mix. Both use the existing resonant waveform: this is
an amplitude mapping, not a recreation of arbitrary console HD Rumble 2 effects.
Haptic tones retain their uniform two-motor behavior. Single Joy-Con mixing is
unchanged, and GameCube never receives this unsupported HD motor protocol.

Motor frames remain atomic (33 bytes for Pro), use one sequence number per
submitted write, and replace stale intents under Bluetooth backpressure. Stops
and the 500 ms failsafe silence both channels. A missing motor characteristic
or inadequate write size disables that write, logs the limitation, and does
not suppress the LED keep-alive needed for input connectivity.

## Output compatibility

| Output | Pro controls | Rumble | Motion |
| --- | --- | --- | --- |
| Rebuilt SDL3 bridge | 19 button slots plus two digital trigger axes; GL/GR and C mapped to paddles and Misc2 | Two-channel return path; stop on handle close/retirement | Opt-in SDL gyro/accelerometer API, with limits below |
| Chromium extension | Standard controls plus the extension's extra button slots | Existing browser vibration return path | No standard Gamepad API motion forwarding |
| RetroArch network gamepad | Standard controls; remap GL/GR/C to supported buttons or keys | No return channel in the legacy protocol | Not carried |
| CoreHID virtual gamepad | Both sticks, triggers, hat, GL/GR/C | No standardized output report in this descriptor | Not carried |

CoreHID requires Apple's restricted virtual-device entitlement; neither a
successful build nor a generic descriptor proves compatibility with every game.
USB uses the separate patched SDL HIDAPI driver, not this app's BLE session.
The existing USB identity tests are retained. USB hardware acceptance is still
required; no audio/NFC claim follows from the USB gamepad path.

## SDL motion and rebuilding

The historical tracked `sdl/libSDL3.0.dylib` does **not** contain these changes.
Build the corrected library using `bash sdl/build-sdl.sh /path/to/SDL-checkout`,
then recreate any game wrapper using it. The builder pins SDL commit
`147a8ee32dbf9ac02f3794964490687b6bbda1bc` and applies the original bridge,
input-edge, USB-identity and Pro-controller patches in that order.

The existing 44-byte S2B1 wire format is unchanged. Its signed gyro and accel
fields now reach SDL. Games must enable sensors explicitly. Only newly received
reports generate samples; repeated polling does not invent motion events.
Closing/reopening does not inherit an enabled sensor or active rumble intent.

Conversion follows the pinned SDL Switch 2 driver's **nominal Pro** convention:
raw `(X,Y,Z)` → SDL `(X,Z,-Y)`, gyro `34.8 / 32767` radians/s per count,
accelerometer `9.80665 * 8 / 32767` m/s² per count. S2B1 carries neither IMU
calibration nor device timestamps or model/firmware metadata. Accordingly this
path uses host receipt timestamps, reports an unknown sample rate (`0`), and
does not reproduce SDL's firmware-dependent sensitivity detection or bias
calibration. Non-Pro controller orientation and per-unit motion accuracy must
not be inferred from these Pro tests. See the pinned
[SDL driver](https://github.com/libsdl-org/SDL/blob/147a8ee32dbf9ac02f3794964490687b6bbda1bc/src/joystick/hidapi/SDL_hidapi_switch2.c)
and the repository's [protocol notes](../research/PROTOCOL.md).

## Validation

`bash tests/run.sh` includes `tests/pro-controller/run.sh`: real session and
protocol method bodies against fake Apple framework boundaries, covering a
complete pairing handshake, identity rejection, all buttons, sliced reports,
telemetry, separate calibration, digital trigger remaps, asymmetric rumble,
sequence wrap, backpressure, expiry and keep-alive without motor support.

The SDL CI workflow compiles `tests/sdl-pro-controller/check.c` against the
pinned SDL headers and runs it against the rebuilt library through actual SDL
gamepad and sensor APIs and localhost UDP. Existing queued-edge and USB
negative controls remain in place. The macOS workflow also compiles and checks
the complete ad-hoc-signed app. Check CI results for the exact source revision.

Before calling this hardware-qualified, exercise initial pairing and button
wake, both stick endpoints/centers, every button and remap, LEDs/battery while
charging, asymmetric rumble and consumer exit, six-axis motion directions,
radio loss/reconnect, sleep/wake, multiple players, USB and an actual game.
Repeat across supported firmware/macOS versions and output backends.

## Experimental features and limits

NFC/amiibo and headphone/microphone audio remain experiments. No audio codec,
macOS audio device, Nintendo GameChat service, arbitrary HD Rumble 2 renderer,
firmware updater or universally compatible system-wide controller driver is
added. Hardware timing, reconnection and per-firmware sensor sensitivity have
not been validated by the synthetic tests.
