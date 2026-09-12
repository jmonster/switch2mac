# Direct rumble tests and game-rumble limits

## Why the Test button was disabled

The old Dashboard enabled Test only for an assigned player with an HD-rumble
model. That incorrectly made a physical test depend on one of the four game
player slots, and also left NSO GameCube owners with a slider but no test.
Removing the model guard alone is not a fix: GameCube cannot use Pro/Joy-Con
HD-format motor packets.

The direct test now resolves the controller card's serial (or linked-pair ID),
not its reusable player number. Connected, unassigned controllers can be tested.
An obsolete card cannot accidentally test another controller that has taken its
player number. A linked Joy-Con pair tests both current physical sessions.

## What to try

Build the PR revision before testing; an older installed application will not
include these changes. Quit other bridge copies before opening it. On the
Dashboard, expand the connected controller's card and raise Rumble above 0%.

- **Pro Controller 2:** Test requests a 0.4-second pulse on both independent
  motors. Both strong/left and weak/right amplitudes honor the slider.
- **Joy-Con 2:** Test drives its one actuator at the selected intensity. A
  linked pair tests both units using the pair's saved intensity.
- **NSO GameCube:** Test preset sends one built-in clip: soft below 50%,
  strong at 50–100%. At 0% nothing is sent. This is a two-level selection,
  not continuously variable strength or a duration-controlled effect.

The Output Status window uses the same direct test and the same saved
Dashboard intensity, even with no game-player slot. Its output selector does
not select the transport for this test.

Check **Logs** when a test remains silent. A GameCube acknowledgement means the
controller accepted the preset command; it does not prove the motor moved.
A busy Bluetooth command channel or unavailable write capacity refuses the
preset test immediately with an explicit retry message, rather than queuing an
unexpected buzz for later. Tests are admitted no more than twice per second
per physical session. Missing characteristics, insufficient write size, or a
rejected command are logged; they do not fall back to HD packets.

A command-response timeout follows the existing session rule: retire and
reconnect the ambiguous command stream rather than misattribute a late reply.
No automatic preset retry, preset-stop command, or persistent motor effect is
invented. A submitted GameCube clip finishes in controller firmware.

## Direct tests are not game-rumble support

This change adds a **direct GameCube preset diagnostic**, not a general
GameCube game-rumble implementation. SDL/browser GameCube capability gates
remain unchanged, and HD writes remain forbidden on this model. The preset
path does not yet implement a cancellable game effect, continuous magnitude
control, or arbitrary duration.

Pro/Joy-Con game-rumble requests still use the existing SDL or browser return
path. A successful direct test does not validate that return path in a game.
RetroArch's legacy network protocol and the current CoreHID output have no
rumble return path. See the corresponding output guide before testing a game.

## Protocol provenance

The preset command is `0x0A`, subcommand `0x02`, with a four-byte payload
`[presetID, 0, 0, 0]` on the normal command characteristic. Soft is preset 3;
strong is preset 2. These wire facts are independently implemented here from
[trevlars/switch2-controllers-linux, ngc/device.py at a0a36e6](https://github.com/trevlars/switch2-controllers-linux/blob/a0a36e6b88ed5500f60cac29815aabad0d8956bd/ngc/device.py),
particularly `play_vibration_preset` and `_gc_preset_for_magnitude`.
The 50% test threshold is this application's UI policy, not a protocol field
or a claim about linear motor amplitude. The repository's existing
[protocol notes](../research/PROTOCOL.md#7-rumble-and-leds) also describe the
separate preset route and the danger of HD-format GameCube writes.

## Validation and remaining hardware acceptance

Run `bash tests/rumble/run.sh` for direct-test regressions and
`bash tests/run.sh` for the complete available regression suite. The new tests
compile the production protocol, session, and engine routing method with
simulated CoreBluetooth boundaries; they do not reimplement rumble routing.
They cover exact preset frames, muted/invalid intensities, ACK correlation,
rejection, bounded repeated clicks, busy/blocked/undersized writes, no unsafe
motor fallback, both Pro motors, single Joy-Con gain, pulse stop and ordering,
retired sessions, pair settings, unassigned hardware, and stale player identity.

No physical Mac/controller acceptance is established by these synthetic tests.
Before treating a build as hardware-qualified, record its source revision,
macOS version, controller model and firmware, then check: soft and strong
GameCube clips really finish; buttons and sticks keep responding; disconnect
and reconnect work; mute remains silent; Pro vibrates on both sides and stops;
and the appropriate game's own rumble test works separately. A missing GameCube
ACK or absent physical vibration is a failed hardware check, not a passing test.
