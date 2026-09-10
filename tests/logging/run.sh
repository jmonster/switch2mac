#!/bin/bash
set -euo pipefail
[ "$(uname -s)" = Darwin ] || exit 0
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
  Sources/FinallyTheControllerWorks/Logging/LogStore.swift \
  tests/logging/LogPipelineTests.swift -o "$work/log-tests"
"$work/log-tests"
