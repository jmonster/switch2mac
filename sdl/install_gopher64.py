#!/usr/bin/env python3
"""Assemble and verify a generated app before replacing the previous copy.

Only the generated destination is replaced. The original app is read-only.
Staging and backup live beside the destination so promotion uses rename, not
cross-volume copying. A failed rollback retains the backup and prints its path.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import subprocess
import tempfile
from typing import Callable

BUNDLE_ID = "io.github.gopher64.both"
RUNTIME_DYLIB = "@executable_path/../Frameworks/libSDL3.0.dylib"
REQUIRED_FILES = (
    "Contents/Info.plist", "Contents/MacOS/gopher64",
    "Contents/MacOS/gopher64-cli", "Contents/Frameworks/libMoltenVK.dylib",
)


class InstallError(RuntimeError):
    pass


def run(command):
    return subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def read_plist(path: Path):
    with path.open("rb") as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        raise InstallError("Expected an app property-list dictionary: " + str(path))
    return value


def verify(app: Path, runner: Callable):
    runner(["codesign", "--verify", "--deep", "--strict", str(app)])
    signature = runner(["codesign", "--display", "--verbose=4", str(app)])
    if "runtime" in signature.stderr.lower() or "runtime" in signature.stdout.lower():
        raise InstallError("Generated copy still has hardened runtime; refusing installation")


def install(source: Path, destination: Path, library: Path, runner: Callable = run):
    source = source.expanduser().resolve(strict=True)
    library = library.expanduser().resolve(strict=True)
    destination = destination.expanduser().absolute()
    if destination.is_symlink():
        raise InstallError("Destination must not be a symbolic link")
    # Resolve parent aliases before comparing with the read-only source.
    destination = destination.parent.resolve() / destination.name
    if destination.suffix != ".app" or source == destination or source in destination.parents or destination in source.parents:
        raise InstallError("Choose a separate .app destination outside the original app")
    for name in REQUIRED_FILES:
        if not (source / name).is_file():
            raise InstallError("Required source file missing: " + name)
    if not (source / "Contents/Resources").is_dir() or not library.is_file():
        raise InstallError("Source resources or selected SDL library missing")
    if destination.exists():
        if not destination.is_dir() or read_plist(destination / "Contents/Info.plist").get("CFBundleIdentifier") != BUNDLE_ID:
            raise InstallError("Refusing to replace an app not identified as Gopher64-Both")
    # Require both executables: the CLI actually runs the game. Never ignore a
    # failed copy and then discover its absence halfway through signing.
    arch = platform.machine()
    for binary in (source / "Contents/MacOS/gopher64", source / "Contents/MacOS/gopher64-cli",
                   source / "Contents/Frameworks/libMoltenVK.dylib", library):
        runner(["lipo", "-verify_arch", arch, str(binary)])
    runner(["codesign", "--verify", "--deep", "--strict", str(source)])
    destination.parent.mkdir(parents=True, exist_ok=True)
    lock = destination.parent / ("." + destination.name + ".install-lock")
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError as error:
        raise InstallError("Another installation or interrupted lock exists: " + str(lock)) from error

    transaction = None
    moved_old = False
    installed = False
    preserve = False
    try:
        transaction = Path(tempfile.mkdtemp(prefix=".switch2mac-install-", dir=destination.parent))
        staged = transaction / destination.name
        backup = transaction / "previous.app"
        (transaction / "recovery.json").write_text(json.dumps({
            "destination": str(destination), "backup": str(backup),
            "note": "If interrupted after the old app was moved, quit the generated app and restore previous.app to destination."
        }, indent=2) + "\n", encoding="utf-8")
        (staged / "Contents/MacOS").mkdir(parents=True)
        (staged / "Contents/Frameworks").mkdir()
        shutil.copytree(source / "Contents/Resources", staged / "Contents/Resources")
        for name in REQUIRED_FILES:
            shutil.copy2(source / name, staged / name)
        shutil.copy2(library, staged / "Contents/Frameworks/libSDL3.0.dylib")
        info = read_plist(staged / "Contents/Info.plist")
        info["CFBundleIdentifier"] = BUNDLE_ID
        info["CFBundleName"] = "Gopher64-Both"
        info["LSEnvironment"] = {"SDL3_DYNAMIC_API": RUNTIME_DYLIB}
        with (staged / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)
        (staged / "Contents/Resources/switch2mac-install.json").write_text(json.dumps({
            "schema": 1, "architecture_checked": arch, "sdl_sha256": digest(library),
            "gopher64_source_sha256": digest(source / "Contents/MacOS/gopher64"),
            "cli_source_sha256": digest(source / "Contents/MacOS/gopher64-cli"),
            "signing": "ad-hoc; hardened runtime disabled in generated copy only",
        }, indent=2) + "\n", encoding="utf-8")
        for name in ("Contents/Frameworks/libSDL3.0.dylib", "Contents/MacOS/gopher64", "Contents/MacOS/gopher64-cli"):
            target = staged / name
            target.chmod(target.stat().st_mode | 0o111)
            runner(["codesign", "--force", "--sign", "-", "--options=0x0", "--timestamp=none", str(target)])
        runner(["codesign", "--force", "--sign", "-", "--options=0x0", "--timestamp=none", str(staged)])
        verify(staged, runner)
        # From here on, any exception attempts to roll back. There is no rm -rf
        # of the previous destination and no unverified copy promoted in place.
        if destination.exists():
            os.replace(destination, backup)
            moved_old = True
        os.replace(staged, destination)
        installed = True
        verify(destination, runner)
    except BaseException as error:
        try:
            if installed:
                os.replace(destination, transaction / "rejected.app")
            if moved_old:
                os.replace(transaction / "previous.app", destination)
        except BaseException as rollback_error:
            preserve = True
            raise InstallError("Rollback could not complete. Recovery files retained at "
                               + str(transaction) + ": " + str(rollback_error)) from error
        raise
    finally:
        if transaction is not None and not preserve:
            shutil.rmtree(transaction)
        # Never remove another process's lock, nor recurse through an unexpected directory.
        lock.rmdir()
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("/Applications/Gopher64.app"))
    parser.add_argument("--destination", type=Path, default=Path.home() / "Applications/Gopher64-Both.app")
    parser.add_argument("--library", type=Path, default=Path(os.environ.get(
        "SDL3_LIBRARY", str(Path(__file__).resolve().parent.parent / "build/sdl/libSDL3.0.dylib"))))
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Installation and code-signature verification require macOS")
    def interrupted(signum, frame):
        raise InterruptedError("Installation interrupted; restoring previous copy")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        result = install(args.source, args.destination, args.library)
    except (OSError, ValueError, plistlib.InvalidFileException, InstallError, subprocess.CalledProcessError) as error:
        print("Installation failed: " + str(error), file=__import__("sys").stderr)
        return 1
    print("Installed and signature-verified: " + str(result))
    print("Original app unchanged. Generated copy is ad-hoc signed without hardened runtime.")
    print("Verify actual game input and netplay separately; installation does not establish compatibility.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
