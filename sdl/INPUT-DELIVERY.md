# Input delivery correction

The tracked upstream libSDL3.0.dylib predates this fix. Editing a source patch
cannot change that binary. Build the corrected library on macOS:

```sh
git clone https://github.com/libsdl-org/SDL /tmp/SDL
bash sdl/build-sdl.sh /tmp/SDL
```

The script exports exact commit 147a8ee32dbf9ac02f3794964490687b6bbda1bc,
applies the original patch and then s2udp-input-edges.patch, and writes
build/sdl/libSDL3.0.dylib without modifying the checkout or tracked binary.
Use that library for SDL3_DYNAMIC_API. The corrected-sdl-arm64 CI artifact
is also a development build, not a notarized application.

Every received state now reaches an open SDL joystick before the next state
is read. The test sends complete button taps and analog-trigger excursions
between updates through actual localhost UDP sockets and SDL event APIs.
The CI negative control must fail with exit 42 before the correction; other
errors are not accepted as a reproduced defect. The same executable must
then pass against the rebuilt corrected library.

Nintendo BLE commands, bonding, keep-alives and report decoding are untouched.
This does not recover datagrams lost before receipt, nor guarantee that a
state-polling game observes arbitrarily short transitions. Physical gameplay
and controller latency still need hardware acceptance.
