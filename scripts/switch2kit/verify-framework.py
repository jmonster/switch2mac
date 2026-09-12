#!/usr/bin/env python3
"""Inspect a real Xcode-generated XCFramework; exit nonzero on any mismatch."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def run(*command: str) -> str:
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
    print(result.stdout, end="")
    return result.stdout


def verify(bundle: Path) -> Path:
    run("plutil", "-lint", str(bundle / "Info.plist"))
    with (bundle / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    entries = info.get("AvailableLibraries", [])
    if len(entries) != 1:
        raise ValueError("Expected one universal macOS library, not per-architecture or simulator archives")
    entry = entries[0]
    if entry.get("SupportedPlatform") != "macos" or entry.get("SupportedPlatformVariant"):
        raise ValueError("Expected native macOS, not Catalyst or a simulator")
    if set(entry.get("SupportedArchitectures", [])) != {"arm64", "x86_64"}:
        raise ValueError("XCFramework metadata must advertise both macOS architectures")
    framework = bundle / entry["LibraryIdentifier"] / entry["LibraryPath"]
    if framework.name != "Switch2Kit.framework":
        raise ValueError("Incorrect framework product name")
    binary = framework / "Switch2Kit"
    run("file", str(binary))
    run("lipo", "-verify_arch", "arm64", "x86_64", str(binary))
    if set(run("lipo", "-archs", str(binary)).split()) != {"arm64", "x86_64"}:
        raise ValueError("The actual Mach-O architectures differ from the advertised architectures")
    linked = run("otool", "-L", str(binary))
    if "CoreHID" in linked or "FinallyTheControllerWorks" in linked:
        raise ValueError("The controller library links application-only code")
    run("plutil", "-lint", str(framework / "Resources/Info.plist"))
    with (framework / "Resources/Info.plist").open("rb") as handle:
        framework_info = plistlib.load(handle)
    if framework_info.get("CFBundleIdentifier") != "org.switch2kit.framework":
        raise ValueError("Unexpected framework identity")
    if list(framework.rglob("*.provisionprofile")) or list(framework.rglob("*.entitlements")):
        raise ValueError("Framework includes host signing material")
    signature = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(framework)],
                               capture_output=True, text=True)
    if "<key>" in signature.stdout:
        raise ValueError("Framework unexpectedly carries entitlements")
    for architecture in ["arm64", "x86_64"]:
        interface = framework / f"Modules/Switch2Kit.swiftmodule/{architecture}-apple-macos.swiftinterface"
        text = interface.read_text()
        if not re.search(r"(?:final\s+)?public\s+(?:final\s+)?class\s+Switch2ControllerManager\b", text):
            raise ValueError("Missing public manager in the emitted Swift interface")
        if re.search(r"\b(CoreHID|CBPeripheral|FinallyTheControllerWorks|UserDefaults)\b", text):
            raise ValueError("Application/transport implementation leaked into the public interface")
        print(f"Verified Swift interface: {interface.name}")
    uuids = set(re.findall(r"UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)", run("dwarfdump", "--uuid", str(binary))))
    symbols = bundle / entry["LibraryIdentifier"] / entry.get("DebugSymbolsPath", "dSYMs") / "Switch2Kit.framework.dSYM"
    symbol_uuids = set(re.findall(r"UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)", run("dwarfdump", "--uuid", str(symbols))))
    if len(uuids) != 2 or uuids != symbol_uuids:
        raise ValueError("Both architecture dSYMs must match the actual framework")
    print("PASS XCFramework structure, identity, interfaces, architectures, dependencies and debug symbols")
    return framework


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify-framework.py PATH_TO_XCFRAMEWORK")
    verify(Path(sys.argv[1]).resolve())
