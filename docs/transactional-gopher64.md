# Safe Gopher64 copy installation

`bash sdl/make-gopher64-both.sh` requires macOS, Python 3, Apple's command-line
tools, the original `/Applications/Gopher64.app`, and the rebuilt compatible
`build/sdl/libSDL3.0.dylib`. It never modifies the original app. Quit any running
Gopher64-Both processes before replacing the generated copy.

Use `--source`, `--destination`, and `--library` for explicit paths; the existing
`SDL3_LIBRARY` environment variable still selects the library. Both `gopher64`
and `gopher64-cli` are required, because the CLI runs the game. All native pieces
must support the architecture executing the installer. This is not a claim
that the resulting app is universal or works on a different Mac architecture.

The installer validates inputs and the original signature, stages beside the
destination on the same filesystem, signs the generated pieces, and verifies
the staged bundle before moving the old generated app to a backup. Promotion
uses a rename, then verifies the installed bundle. Ordinary copying, signing,
verification, or promotion failures leave or restore the previous copy. Only
an existing app with bundle ID `io.github.gopher64.both` may be replaced. A lock
prevents two cooperating installers from racing for the same destination.

Staging is removed after successful installation or a successful rollback. If
rollback itself fails, its directory and `recovery.json` are retained and the
error reports their location. A force kill, power loss, or disk failure cannot
run Python cleanup: inspect the `.switch2mac-install-*` directory beside the
destination, quit the generated app, and restore `previous.app` to the destination
listed in `recovery.json`. Remove an abandoned `.APPNAME.install-lock` only after
confirming no installer is running. Do not delete a retained backup before
checking which app remains at the destination. Promotion has a brief two-rename
gap; it is recoverable, not a filesystem transaction or crash-proof atomic swap.

The generated copy remains ad-hoc signed **without hardened runtime/library
validation** to permit the SDL override. System-wide security settings are not
changed, and the original app keeps its signature. No Gatekeeper bypass,
quarantine removal, or automatic launch is performed. The bundled installation
record lists input hashes and the architecture checked. Signature validation
does not establish actual SDL compatibility, controller input, or netplay.

For reversal, quit and remove only the generated copy and use the untouched
original. The installer does not edit game preferences, ROMs, or save files.

`bash tests/installer/run.sh` injects copy/sign/verify/rename failures against
real temporary directories. On macOS it also builds a disposable Mach-O app
and library and runs actual signing, verification, installation and replacement.
