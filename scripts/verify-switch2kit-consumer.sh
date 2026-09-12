#!/bin/bash
# Fresh consumers have no dependency on the dashboard or experimental product.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
[ "$(uname -s)" = Darwin ] || { echo 'Consumer verification requires macOS and Xcode.' >&2; exit 2; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/source/Sources/Consumer"
python3 - "$ROOT" "$WORK/source/Package.swift" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "IndependentConsumer", platforms: [.macOS(.v15)],
    dependencies: [.package(path: %s)],
    targets: [.executableTarget(name: "Consumer", dependencies: [.product(name: "Switch2Kit", package: %s)])])
''' % (json.dumps(str(root)), json.dumps(root.name.lower())))
PY
cat > "$WORK/source/Sources/Consumer/main.swift" <<'SWIFT'
import Foundation
import Switch2Kit

@MainActor
func checkConsumerAPI() throws {
    let manager = Switch2ControllerManager(configuration: .init(discoveryMode: .onDemand))
    let snapshot: Switch2ManagerSnapshot = manager.snapshot
    let observation = try manager.observe(on: DispatchQueue(label: "independent.consumer"), bufferingNewest: 8) { event in
        if case .input(let controller) = event {
            let _: Switch2ControllerID = controller.id
            let _: Switch2Buttons = controller.state.buttons
            let _: Switch2Stick? = controller.state.leftStick
            let _: UInt64 = controller.state.sequence
        }
    }
    // Type-check operations without opening a Bluetooth radio during CI.
    let start: () -> Void = manager.start
    let discover: (TimeInterval) throws -> Void = { try manager.discover(for: $0) }
    let rumble: (Switch2ControllerID) throws -> Void = { try manager.pulseRumble(for: $0, strong: 0.2, duration: 0.12) }
    _ = (snapshot, observation, start, discover, rumble)
    observation.cancel()
}
// Build/link only. No controller-support method is executed in this consumer.
SWIFT
swift package --package-path "$WORK/source" describe
swift build --package-path "$WORK/source" -Xswiftc -warnings-as-errors
FRAMEWORK=$(python3 - "$ROOT/build/Switch2Kit.xcframework" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
with (root / 'Info.plist').open('rb') as f: entry = plistlib.load(f)['AvailableLibraries'][0]
print(root / entry['LibraryIdentifier'] / entry['LibraryPath'])
PY
)
mkdir -p "$WORK/binary"
ditto "$FRAMEWORK" "$WORK/binary/Switch2Kit.framework"
# Force the compiler to consume .swiftinterface rather than same-toolchain binaries.
find "$WORK/binary/Switch2Kit.framework" -type f -name '*.swiftmodule' -delete
SDK=$(xcrun --sdk macosx --show-sdk-path)
for arch in arm64 x86_64; do
  xcrun --sdk macosx swiftc -swift-version 6 -warnings-as-errors -target "$arch-apple-macosx15.0" \
    -sdk "$SDK" -F "$WORK/binary" -framework Switch2Kit \
    "$WORK/source/Sources/Consumer/main.swift" -o "$WORK/Consumer-$arch" \
    -Xlinker -rpath -Xlinker "$WORK/binary"
  file "$WORK/Consumer-$arch"
  lipo -verify_arch "$arch" "$WORK/Consumer-$arch"
  if otool -L "$WORK/Consumer-$arch" | grep -q CoreHID; then
    echo 'Independent consumer unexpectedly links CoreHID.' >&2; exit 1
  fi
done
echo 'PASS fresh SwiftPM source consumer and both binary interface/link consumers (no radio opened)'
