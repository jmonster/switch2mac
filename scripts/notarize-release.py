#!/usr/bin/env python3
"""Validate, notarize and package an explicitly supplied Developer ID app.

Invoking this command submits a staged ZIP to Apple. It does not build, sign,
install, publish a GitHub release, modify the source app or enable an updater.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile

BUNDLE_ID = "io.github.switch2mac.gamecubed"
UNSAFE_ENTITLEMENTS = (
    "get-task-allow", "com.apple.security.get-task-allow",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.allow-dyld-environment-variables",
)


class ReleaseError(RuntimeError):
    pass


def command(args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=900)


def bounded_json(text):
    if len(text.encode("utf-8")) > 1_048_576:
        raise ReleaseError("Notary response exceeds the evidence size limit")
    value = json.loads(text)
    if not isinstance(value, dict):
        raise ReleaseError("Expected a structured notary response")
    return value


def verify_app(app, team, revision, run):
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    result = run(["codesign", "--display", "--verbose=4", str(app)])
    signature = result.stdout + "\n" + result.stderr
    if not re.search(r"^Authority=Developer ID Application:", signature, re.M):
        raise ReleaseError("A Developer ID Application signature is required; ad-hoc builds are not releases")
    if not re.search(r"^TeamIdentifier=" + re.escape(team) + r"$", signature, re.M):
        raise ReleaseError("Signing team does not match the explicitly expected team")
    if not re.search(r"^CodeDirectory .*flags=.*\bruntime\b", signature, re.M):
        raise ReleaseError("Hardened runtime is required")
    if not re.search(r"^Timestamp=.+", signature, re.M):
        raise ReleaseError("A secure signing timestamp is required")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if not isinstance(info, dict) or info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise ReleaseError("Bundle identity is not GameCubed")
    if info.get("FTCWSourceRevision") != revision or info.get("FTCWSourceDirty") is not False:
        raise ReleaseError("Bundle must identify the exact clean source revision")
    executable = info.get("CFBundleExecutable", "")
    if not isinstance(executable, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", executable):
        raise ReleaseError("Unexpected executable path")
    binary = app / "Contents/MacOS" / executable
    if not binary.is_file() or binary.is_symlink():
        raise ReleaseError("Expected a regular bundled executable")
    result = run(["codesign", "--display", "--entitlements", ":-", str(app)])
    entitlements = plistlib.loads(result.stdout.encode()) if result.stdout.strip() else {}
    if not isinstance(entitlements, dict) or any(entitlements.get(key) for key in UNSAFE_ENTITLEMENTS):
        raise ReleaseError("Debugging or library-validation exceptions are not allowed in this release path")
    arches = run(["lipo", "-archs", str(binary)]).stdout.strip().split()
    if not arches or not set(arches) <= {"arm64", "x86_64"}:
        raise ReleaseError("Unknown or missing architecture in the signed app")
    return info, sorted(set(arches))


def package(app, output, team, profile, run=command):
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ReleaseError("Expected an explicit ten-character signing Team ID")
    if not profile.strip() or len(profile) > 128 or any(ord(c) < 32 for c in profile):
        raise ReleaseError("Specify the name of an existing notarytool keychain profile")
    app = Path(app).expanduser().resolve(strict=True)
    output = Path(output).expanduser().absolute()
    output = output.parent.resolve() / output.name
    if output.exists() or output.is_symlink() or app == output or app in output.parents:
        raise ReleaseError("Choose a new output directory outside the source app")
    revision = run(["git", "rev-parse", "HEAD"]).stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ReleaseError("Cannot establish source revision")
    if run(["git", "status", "--porcelain", "--untracked-files=normal"]).stdout.strip():
        raise ReleaseError("Commit or remove local changes before packaging a release")
    verify_app(app, team, revision, run)
    output.parent.mkdir(parents=True, exist_ok=True)
    # A failed operation leaves no distribution directory. Private same-volume
    # staging keeps the source untouched and final promotion is a rename.
    stage = Path(tempfile.mkdtemp(prefix=".switch2mac-notary-", dir=output.parent))
    try:
        staged_app = stage / app.name
        run(["ditto", "--rsrc", "--extattr", str(app), str(staged_app)])
        info, arches = verify_app(staged_app, team, revision, run)
        archive = stage / "submission.zip"
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(staged_app), str(archive)])
        receipt = bounded_json(run(["xcrun", "notarytool", "submit", str(archive),
                                    "--keychain-profile", profile, "--wait", "--output-format", "json"]).stdout)
        request_id = receipt.get("id", "")
        if not isinstance(request_id, str) or not re.fullmatch(r"[0-9a-fA-F-]{36}", request_id):
            raise ReleaseError("Notary service returned no valid submission ID")
        log = bounded_json(run(["xcrun", "notarytool", "log", request_id,
                                "--keychain-profile", profile]).stdout)
        if receipt.get("status") != "Accepted" or log.get("status") != "Accepted":
            raise ReleaseError("Notarization was not accepted; inspect submission " + request_id)
        run(["xcrun", "stapler", "staple", str(staged_app)])
        run(["xcrun", "stapler", "validate", str(staged_app)])
        verify_app(staged_app, team, revision, run)
        run(["spctl", "--assess", "--type", "execute", "--verbose=2", str(staged_app)])
        # Staple the app, then recreate the ZIP; the submitted ZIP has no ticket.
        archive.unlink()
        final_zip = stage / "switch2mac-notarized.zip"
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(staged_app), str(final_zip)])
        checksum = hashlib.sha256()
        with final_zip.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                checksum.update(chunk)
        (stage / "SHA256SUMS").write_text(checksum.hexdigest() + "  " + final_zip.name + "\n")
        # Notary logs may name bundle internals. They remain local and must be
        # reviewed before sharing; no credentials/profile name are included.
        (stage / "notary-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        (stage / "notary-log.json").write_text(json.dumps(log, indent=2) + "\n")
        (stage / "provenance.json").write_text(json.dumps({
            "schema": 1, "bundle_id": BUNDLE_ID, "source_revision": revision,
            "source_dirty": False, "signing_team": team, "architectures": arches,
            "declared_minimum_macos": info.get("LSMinimumSystemVersion"),
            "archive_sha256": checksum.hexdigest(), "notary_submission": request_id,
            "notary_status": "Accepted", "ticket_validated": True,
            "gatekeeper_assessed": True, "hardware_game_acceptance": "not-run",
            "automatic_updates": "disabled; no feed or signing key configured by this tool",
        }, indent=2) + "\n")
        # Keep only the distributable ZIP and evidence, not a second app copy.
        shutil.rmtree(staged_app)
        # mkdir reserves the name against cooperating/racing installations.
        output.mkdir(mode=0o700)
        try:
            stage.rename(output)
        except BaseException:
            output.rmdir()
            raise
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--keychain-profile", required=True)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Developer ID and notarization validation require macOS")
    try:
        print("Prepared locally: " + str(package(args.app, args.output, args.team_id, args.keychain_profile)))
    except (OSError, ValueError, ReleaseError, subprocess.SubprocessError) as error:
        parser.exit(1, "Release packaging failed: " + str(error) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
