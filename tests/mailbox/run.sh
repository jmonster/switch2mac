#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
  Sources/GameCubed/Runtime/BoundedStateMailbox.swift \
  tests/mailbox/MailboxTests.swift -o "$work/mailbox-tests"
"$work/mailbox-tests"
