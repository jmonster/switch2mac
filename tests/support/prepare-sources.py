"""Build radio-free fixtures from production method bodies.

Only imports, outer platform guards and access control change. CoreBluetooth is
replaced by tests/session/FrameworkFakes.swift. Never change protocol/transport
method bodies here: fixes belong in Sources and tests must exercise them there.
"""
from pathlib import Path
import os
import re
import sys


def fixture(source: str) -> str:
    if source.startswith("#if canImport(CoreBluetooth)\n"):
        assert source.rstrip().endswith("#endif")
        source = source.split("\n", 1)[1].rstrip().removesuffix("#endif")
    source = re.sub(r"^import (CoreBluetooth|IOBluetooth|Switch2Kit)$", "", source, flags=re.M)
    source = re.sub(r"\b(?:fileprivate|private)(?:\(set\))?\s+", "", source)
    source = re.sub(r"\bpackage\s+", "", source)
    return "import CoreFoundation\n" + source


def extract(source: str, marker: str) -> str:
    start = source.index(marker)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


if __name__ == "__main__":
    mode, destination = sys.argv[1:]
    out = Path(destination)
    out.mkdir(parents=True, exist_ok=True)
    if mode == "session":
        src = Path(os.environ.get("SESSION_SOURCE", "Sources/Switch2Kit/Bluetooth/ControllerSession.swift"))
        (out / "ControllerSession.swift").write_text(fixture(src.read_text()))
        src = Path("Sources/Switch2KitExperimental/ExperimentalControllerSession.swift")
        (out / "ExperimentalControllerSession.swift").write_text(fixture(src.read_text()))
    elif mode == "transport":
        for name in ["ControllerTransport", "DiscoveryPolicy"]:
            src = Path(f"Sources/Switch2Kit/Bluetooth/{name}.swift")
            (out / f"{name}.swift").write_text(fixture(src.read_text()))
    elif mode == "policy":
        src = Path("Sources/Switch2Kit/Bluetooth/DiscoveryPolicy.swift")
        (out / "ControllerPolicy.swift").write_text(fixture(src.read_text()))
        src = Path("Sources/FinallyTheControllerWorks/Runtime/DiscoveryPolicy.swift")
        (out / "AppPolicy.swift").write_text(fixture(src.read_text()))
    elif mode == "rumble":
        src = Path("Sources/FinallyTheControllerWorks/Bluetooth/BridgeEngine.swift").read_text()
        body = extract(src, "private struct Logical") + "\n" + extract(src, "func testRumble(serial:")
        header = """import Foundation
typealias ApplicationController = ControllerSession
final class RumbleTestEngine: @unchecked Sendable {
    let btQueue: DispatchQueue
    var sessions: [Int: ControllerSession] = [:]
    var players: [Int: Logical] = [:]
    init(queue: DispatchQueue) { btQueue = queue }
"""
        (out / "RumbleEngine.swift").write_text(header + fixture(body).removeprefix("import CoreFoundation\n") + "\n}\n")
    else:
        raise SystemExit(f"Unknown fixture mode: {mode}")
