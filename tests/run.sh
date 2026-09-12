#!/bin/bash
# Compile the production protocol decoder directly, without opening Bluetooth.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 5 \
  Sources/GameCubed/Protocol/Switch2Protocol.swift \
  tests/ProtocolTests.swift -o "$work/protocol-tests"
"$work/protocol-tests"
for suite in tests/*/run.sh; do
  [ -f "$suite" ] || continue
  bash "$suite"
done
