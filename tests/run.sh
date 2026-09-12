#!/bin/bash
# Compile the production protocol decoder directly, without opening Bluetooth.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc "${kit_flags[@]}" -swift-version 5 \
  "${kit_sources[@]}" \
  tests/ProtocolTests.swift -o "$work/protocol-tests"
"$work/protocol-tests"
for suite in tests/*/run.sh; do
  [ -f "$suite" ] || continue
  bash "$suite"
done
