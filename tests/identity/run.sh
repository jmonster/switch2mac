#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 tests/identity/check.py "$work/UpdatePolicyTests.swift"
swiftc -swift-version 5 -parse-as-library "$work/UpdatePolicyTests.swift" -o "$work/test"
"$work/test"
bash -n scripts/build-app.sh scripts/notarize.sh
