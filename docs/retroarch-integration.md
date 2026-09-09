# RetroArch fork integration

Adapted from vialoh/switch2mac retroarch-network-gamepad at
2c7a396336f5a657a16a772b8c056d96ec6ff7f1 (upstream PR #1). The optional
configuration toggle and default-off behavior remain. No Nintendo command,
BLE handshake, decoding or entitlement changes are required.

The original desired-state timer erased taps completed before its next tick.
The corrected sink retains ordered button edges (up to 256 per player),
coalesces analog positions separately, and retains the existing 60/s pacing.
Overflow explicitly neutralizes that player's output and logs a failure;
disable/re-enable network output to retry. It never silently drops oldest
button edges while pretending the stream is intact.

Full periodic refreshes include zeros/releases, not only held values, so a
lost release can converge later. A disconnect/disable attempts repeated
neutral refreshes. Changing the destination first paces 20 neutral control
messages to the old port, then establishes current state at the new port;
input during that explicit configuration reset becomes the new initial state.
Normal input/taps do not use that reset policy. Send failures retain pending
work; sendto success means kernel acceptance, not remote acknowledgement.

The 20-byte native little-endian message layout was cross-checked against
libretro/RetroArch commit 81478f2aa2abb942cfacb2109cbc25a4bd3b46ca,
input/input_driver.h and tools/ra_stress.md. This legacy protocol updates one
control per datagram and receiver polling/pacing can lose UDP traffic. It is
not an atomic full-state or lossless channel, and it has no rumble return path.
GameCube analog triggers still map to digital L2/R2 at the inherited threshold;
this is not full analog-trigger fidelity. Use only on a trusted local network
when enabling RetroArch's unauthenticated listener.

Eight tests use the actual sink and real loopback sockets; four delivery cases
and the non-finite-axis case fail against the imported source and pass after
repair. The visibility-only test copy avoids unrelated UI initialization;
the complete app is separately built with Apple frameworks. Synthetic tests
do not establish gameplay, physical timing or controller compatibility.

Run bash tests/retroarch/run.sh. NODE/Swift framework dependencies are not
added by this feature. The per-report DispatchQueue itself is not byte-bounded;
this PR bounds retained digital edges and documents overload, not all memory.
