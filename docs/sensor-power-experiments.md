# Opt-in sensor-demand experiments (not qualified defaults)

Normal app launches retain the existing `0xB7` Joy-Con / `0xA7` other-model
feature masks. This change adds explicit **process-scoped experiments**, not an
automatic low-power mode and not a measured battery-life improvement.

The real connection handshake uses one selected profile for both feature init
and enable commands. Buttons/sticks/triggers, battery flag, baseline bits, input
parsing, keep-alive timing, rumble safety and output ordering are unchanged.
Profiles affect the *next connection*; they do not switch features mid-session.

| Requested consumer | Profile | Joy-Con mask | Other-model mask |
|---|---|---|---|
| All existing features | compatibility | 0xB7 | 0xA7 |
| Buttons/sticks/triggers | gamepad | 0x23 | 0x23 |
| Gamepad plus motion | motion | 0x27 | 0x27 |
| Gamepad plus optical pointer | pointer | 0x33 | 0x23 |

Lower-sensor profiles require hardware/firmware qualification. Sensors excluded
by a profile must not be expected to work in SDL motion, gestures, the optical
mouse or sensor dashboards. Do not run NFC/audio experiments concurrently.
Unknown profiles or missing acknowledgment revert to compatibility, never `0xFF`.

Quit every running bridge copy. After building the reviewed branch, deliberately
launch the bundled executable from Terminal for the desired test:

```sh
SWITCH2MAC_ACKNOWLEDGE_UNQUALIFIED_POWER=1 \
SWITCH2MAC_EXPERIMENTAL_SENSORS=gamepad \
'build/Finally the Controller Works (jmonster).app/Contents/MacOS/FinallyTheControllerWorks'
```

Both environment variables are required. No preferences, firmware or bonding
keys are changed by selecting a profile. Quit the test process and launch the app
normally to restore compatibility. A controller must reconnect to apply either
selection. Use normal macOS security/permission policy; this is not an installer.

Compare compatibility and candidate on the same model/firmware, OS, game, output,
input trace, brightness, network/radio environment and charge state. Record host
energy separately from controller current/power; do not infer either from fewer
writes or a rough voltage percentage. Include active input, stationary input,
long held controls, rumble, sleep/wake and reconnection. Check both trigger travel
and digital clicks where supported. Record failures, not just mean power.

The new automated suite executes the real session command writer with a fake
CoreBluetooth boundary, checking all model/profile masks and both handshake
frames. It does not prove that any controller firmware accepts reduced masks,
that every omitted sensor powers down, or that current consumption decreases.
Promoting automatic demand negotiation requires physical acceptance and a
consumer-capability signal; the legacy SDL wire format does not supply one.

## Inspect the actual process selection before connecting

Append `--sensor-profile` to the executable command above to print the effective
profile, all four model masks, requested sensors and source revision as JSON.
This mode exits before application construction, Bluetooth, output listeners or
permission prompts. It is safe to use without a controller. Extra arguments are
rejected. Unknown/missing acknowledgment still reports compatibility. Normal
launches with a reduced profile emit one warning in the application log.

The packaged runtime CI executes this command with all four profiles on macOS
15/26, Intel/Apple silicon. It verifies the actual masks used by the handshake;
its output explicitly says hardware qualification and energy measurements were
**not run**. This completes the opt-in software tool, not physical qualification.

## Record and validate hardware and energy acceptance

See [acceptance records](acceptance-records.md) for an executable template,
validation and paired-comparison workflow. No measured records ship in this PR.
