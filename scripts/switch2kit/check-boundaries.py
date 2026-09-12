#!/usr/bin/env python3
"""Fail closed if application policy or duplicate production controller code returns."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
kit = root / 'Sources/Switch2Kit'
forbidden = re.compile(r'\b(CoreHID|CGEvent|AXIsProcessTrusted|AXIsProcessTrustedWithOptions|UserDefaults|SDL|UDPHub|WebSocketHub|KeyboardMapper|MouseController|DashboardView|FTCWApp|FinallyTheControllerWorks)\b|wabisabi\.ware\.gamecubed|SWITCH2MAC_|browser|WebSocket', re.I)
files = sorted(kit.rglob('*.swift'))
assert files, 'No library sources found'
for path in files:
    match = forbidden.search(path.read_text())
    assert match is None, f'Forbidden coupling in {path.relative_to(root)}: {match.group()}'
for filename in ['Switch2Protocol.swift', 'ControllerSession.swift', 'ControllerTransport.swift']:
    matches = list((root / 'Sources').rglob(filename))
    assert len(matches) == 1 and matches[0].is_relative_to(kit), f'Duplicate/wrong owner: {filename}: {matches}'
app = root / 'Sources/FinallyTheControllerWorks'
assert not (app / 'Bluetooth/ControllerSession.swift').exists()
assert not (app / 'Protocol/Switch2Protocol.swift').exists()
bridge = (app / 'Bluetooth/BridgeEngine.swift').read_text()
assert 'import Switch2Kit' in bridge
assert 'CBCentralManager' not in bridge and 'parseAdvertisement' not in bridge
manifest = (root / 'Package.swift').read_text()
assert '.library(name: "Switch2Kit", targets: ["Switch2Kit"])' in manifest
assert 'binaryTarget' not in manifest, 'Source integration must remain primary'
print(f'PASS {len(files)} controller-library files: no application coupling; one production protocol/session/transport implementation')
