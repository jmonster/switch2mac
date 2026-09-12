#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
prepare_session_sources "$work"
for suite in SessionTests FlowTests ResponseTests ResultTests; do
  swiftc -swift-version 5 "${kit_flags[@]}" "${kit_session_sources[@]}" \
    "tests/session/$suite.swift" -o "$work/$suite"
  "$work/$suite" "${SESSION_CASE:-all}"
done
