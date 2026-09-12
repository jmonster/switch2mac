# The SDL bridge (S2UDP)

Use this output for a **compatible SDL3 game or emulator**. It is not a
system-wide controller driver, and a successful bridge connection does not
establish compatibility with every game. RetroArch and Chromium have
[separate setup paths](../docs/quick-start.md).

## Choose the corrected library, not the historical binary

The tracked `sdl/libSDL3.0.dylib` is a historical binary. It does
**not** incorporate later input-edge, USB identity, or Pro Controller source
repairs. Editing a patch does not rebuild that binary.

The current build uses pinned SDL commit
`147a8ee32dbf9ac02f3794964490687b6bbda1bc` (`release-3.4.14`) plus all four
patches applied by [build-sdl.sh](build-sdl.sh). To build on macOS, install
the required C/C++ build tools, CMake, and libusb, then provide an SDL git
checkout containing that commit:

```sh
git clone https://github.com/libsdl-org/SDL.git /path/to/SDL
bash sdl/build-sdl.sh /path/to/SDL
```

Run the build command from the switch2mac checkout. Its output is
`build/sdl/libSDL3.0.dylib`; it leaves the historical tracked file untouched
and prints the new library's SHA-256. Alternatively, a successful **SDL input
regressions** workflow provides a `corrected-sdl-arm64` artifact. Check the
workflow's tested source commit and all job results before selecting an
artifact. Neither path implies physical-controller or real-game acceptance.

## Gopher64: keep the original app

The helper expects `/Applications/Gopher64.app` and defaults to the newly
built library, not the historical one:

```sh
bash sdl/make-gopher64-both.sh
```

It creates `~/Applications/Gopher64-Both.app` with the library bundled inside
and an `SDL3_DYNAMIC_API` override. `SDL3_LIBRARY=/absolute/path/to/libSDL3.0.dylib`
can explicitly select another compatible library. The helper refuses to
continue when the selected library does not exist.

The copy is **ad-hoc re-signed without hardened runtime/library validation**;
this changes its security properties and does not preserve notarization.
The original `/Applications/Gopher64.app` is not modified. The helper replaces
an existing `~/Applications/Gopher64-Both.app`, so preserve any wanted changes
to that generated copy before rebuilding it. Launch the copy using Finder or
`open`, not a bare executable, so its `LSEnvironment` setting is applied.

Check controls in the actual emulator. To stop using the integration, quit
the generated copy and launch the original app. Delete only the generated
copy when removing this integration; do not replace libraries in your original
game or disable system-wide security policy.

## Other SDL3 applications

For an application that supports SDL's dynamic API override and can load a
compatible library of the correct architecture:

```sh
SDL3_DYNAMIC_API=/absolute/path/to/build/sdl/libSDL3.0.dylib ./the-game
```

This is not a guarantee for arbitrary SDL3 apps, SDL2 games, anti-cheat
software, or signed applications that reject external libraries. Validate the
actual application's SDL version, architecture, loading policy, and controls.
Do not re-sign or modify an original game just to experiment. For an application
that already loads this backend, `SDL_S2UDP_DISABLE=1` disables S2UDP; remove
any library override to return to the application's original SDL.

## Protocol and acceptance

The menu-bar app serves logical players on loopback UDP ports 24800–24803.
The patched SDL backend subscribes and exposes SDL joystick/gamepad events.
`S2B1` state packets contain 44 bytes: sequence, buttons, sticks, triggers,
battery, gyro, and accelerometer. `S2R1` rumble requests contain six bytes.
Controller appearance and disappearance follow the input stream.

The corrected input-edge handling is documented in [INPUT-DELIVERY.md](INPUT-DELIVERY.md),
wired-device selection in [USB-IDENTITY.md](USB-IDENTITY.md), and model-specific
limits in the [Pro Controller guide](../docs/pro-controller-support.md).
Synthetic regression results do not establish gameplay latency, netplay,
firmware coverage, or every controller's rumble behavior.

## License and provenance

Based on SDL 3.4.14 by Sam Lantinga and the SDL contributors, under the
[zlib license](https://github.com/libsdl-org/SDL/blob/main/LICENSE.txt).
This is a modified SDL build, not an official SDL release. The original
`sdl3-3.4.14-s2udp.patch` and the three follow-up patches remain separately
tracked; [build-sdl.sh](build-sdl.sh) is the authoritative application order.
Application-wide licensing is documented separately in [CREDITS.md](../CREDITS.md).
