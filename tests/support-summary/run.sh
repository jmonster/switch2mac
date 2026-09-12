#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc "${kit_flags[@]}" -swift-version 6 -warnings-as-errors \
 "${kit_sources[@]}" \
 Sources/FinallyTheControllerWorks/Runtime/OutputHealth.swift \
 Sources/FinallyTheControllerWorks/Runtime/SupportSummary.swift tests/support-summary/Tests.swift -o "$work/tests"
"$work/tests"
