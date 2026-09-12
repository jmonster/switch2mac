# RetroArch integration

GameCubed can send controller input to RetroArch's network gamepad receiver.
The output is disabled by default and does not require a custom SDL library.

## Setup

In RetroArch, enable **Settings → Network → Network Gamepad** and the desired
**Network Gamepad Users**, then restart RetroArch. In GameCubed's Dashboard,
enable **Configuration → Network gamepad output (RetroArch)**. Both base ports
must match: the default is 55400, with one port per player.

GameCubed sends only to `127.0.0.1`. RetroArch's unauthenticated receiver may
listen on other interfaces; enable it only on a trusted network.

## Delivery behavior

The sink retains ordered button edges, up to 256 per player, coalesces analog
positions separately, and uses 60/s pacing. Overflow neutralizes that player's
output and logs a failure. Disable and re-enable network output to retry.

Periodic refreshes include zeros and releases, allowing a lost release to
converge later. Disconnect and disable attempt repeated neutral refreshes.
Changing destination first paces 20 neutral control messages to the old port,
then establishes state at the new port. Input received during that configuration
reset becomes the new initial state. Cancelling the change reasserts state at
the original port and resumes ordered edge delivery. Normal taps do not use
that reset policy. Send failures retain pending work; `sendto` success means
kernel acceptance, not remote acknowledgment.

## Protocol limits

The 20-byte native little-endian layout follows `input/input_driver.h` and
`tools/ra_stress.md` in libretro/RetroArch revision
`81478f2aa2abb942cfacb2109cbc25a4bd3b46ca`. The protocol updates one control per
datagram. Receiver polling and UDP loss can discard traffic; this is not an
atomic full-state or lossless channel. There is no rumble return path.
GameCube analog triggers map to digital L2/R2 at the configured threshold,
not full analog-trigger travel.

## Testing

Run `bash tests/retroarch/run.sh`. Tests use the actual sink and real loopback
sockets to cover taps, release refreshes, and cancelled destination changes.
The test copy adjusts visibility without initializing unrelated UI; macOS
build checks compile the complete application with Apple frameworks.

Retained digital edges are bounded; the per-report DispatchQueue is not
byte-bounded. Automated tests do not establish gameplay timing or physical
controller compatibility. Browser and RetroArch outputs can run together;
both are disabled by default.
