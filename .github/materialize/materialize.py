#!/usr/bin/env python3
"""Temporary transport bridge; this file is not part of the library PR.

The connector can write text but cannot upload a local patch file. Materialize
its checksum-verified bytes as a normal source commit on the explicit PR branch.
Never force-push or modify main. Abort on concurrent changes to the PR branch.
"""
from pathlib import Path
import base64
import hashlib
import json
import lzma
import os
import re
import subprocess
import sys


def git(*args: str, capture: bool = False) -> str:
    result = subprocess.run(["git", *args], check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ""


def main() -> None:
    if os.environ.get("GITHUB_REPOSITORY") != "jmonster/Switch2Kit":
        raise RuntimeError("This transport is restricted to jmonster/Switch2Kit")
    if os.environ.get("GITHUB_REF") != "refs/heads/automation/materialize-switch2kit":
        raise RuntimeError("This transport runs only on its dedicated branch")
    directory = Path(".github/materialize")
    manifest = json.loads((directory / "manifest.json").read_text())
    branch = manifest["branch"]
    if branch != "refactor/switch2kit-library":
        raise RuntimeError("Refusing to modify a branch other than the explicit draft PR")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest["base"]):
        raise RuntimeError("Invalid expected parent")
    count = manifest["parts"]
    if not isinstance(count, int) or not 1 <= count <= 100:
        raise RuntimeError("Invalid part count")
    encoded = "".join((directory / f"payload-{i:02d}.txt").read_text().strip()
                      for i in range(count))
    if len(encoded) > 2_000_000:
        raise RuntimeError("Transport payload too large")
    compressed = base64.b64decode(encoded, validate=True)
    decoder = lzma.LZMADecompressor(memlimit=512 * 1024 * 1024)
    patch = decoder.decompress(compressed, max_length=8 * 1024 * 1024)
    if not decoder.eof or decoder.unused_data:
        raise RuntimeError("Incomplete or oversized patch")
    digest = hashlib.sha256(patch).hexdigest()
    if digest != manifest["sha256"]:
        raise RuntimeError(f"Patch checksum mismatch: {digest}")
    print(f"Verified reviewed patch SHA-256: {digest}", flush=True)
    patch_path = Path(os.environ["RUNNER_TEMP"]) / "switch2kit-reviewed.patch"
    patch_path.write_bytes(patch)
    git("fetch", "--no-tags", "origin", f"refs/heads/{branch}")
    head = git("rev-parse", "FETCH_HEAD", capture=True)
    if head != manifest["base"]:
        raise RuntimeError(f"Concurrent PR changes: expected {manifest['base']}, found {head}")
    git("checkout", "--detach", head)
    git("diff", "--exit-code")
    git("apply", "--index", "--binary", str(patch_path))
    git("diff", "--cached", "--check")
    changed = git("diff", "--cached", "--name-only", capture=True).splitlines()
    allowed = ("Sources/", "Tests/", "tests/", "Examples/", "docs/switch2kit/",
               "scripts/", ".github/workflows/")
    for path in changed:
        if path not in ("Package.swift", "README.md", ".gitignore") and not path.startswith(allowed):
            raise RuntimeError(f"Unexpected patch path: {path}")
    git("config", "user.name", "github-actions[bot]")
    git("config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")
    git("commit", "-m", manifest["message"])
    revision = git("rev-parse", "HEAD", capture=True)
    # No --force: a race after the expected-parent check must reject the push.
    git("push", "origin", f"HEAD:refs/heads/{branch}")
    evidence = Path(os.environ["RUNNER_TEMP"]) / "switch2kit-verification"
    evidence.mkdir(exist_ok=True)
    (evidence / "revision.txt").write_text(revision + "\n")
    git("archive", "--format=zip", f"--output={evidence / 'source.zip'}", "HEAD")
    print(f"Published normal source commit: {revision}", flush=True)
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(f"Published source commit `{revision}` to `{branch}`.\n\n"
                      "This job's build logs refer to that source SHA, not the transport-branch SHA.\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Materialization refused: {error}", file=sys.stderr)
        raise
