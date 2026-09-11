#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
 Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
 Sources/FinallyTheControllerWorks/Runtime/OutputHealth.swift \
 Sources/FinallyTheControllerWorks/Runtime/SupportSummary.swift tests/support-summary/Tests.swift -o "$work/tests"
"$work/tests"
