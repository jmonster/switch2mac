#!/bin/bash
# Shared source list. Legacy fixtures compile the production kit values/decoder
# and the separate dashboard capability policy, never copied protocol methods.
kit_flags=(-package-name Switch2Kit)
kit_sources=(
  Sources/Switch2Kit/Public/ControllerTypes.swift
  Sources/Switch2Kit/Public/Lifecycle.swift
  Sources/Switch2Kit/Protocol/Switch2Protocol.swift
  Sources/Switch2Kit/Protocol/DecodedState.swift
  Sources/FinallyTheControllerWorks/Runtime/DirectRumbleCapability.swift
)
prepare_session_sources() {
  local destination="$1"
  python3 tests/support/prepare-sources.py session "$destination"
  kit_session_sources=(
    "${kit_sources[@]}"
    Sources/Switch2Kit/Public/Observation.swift
    Sources/Switch2Kit/Diagnostics/Diagnostics.swift
    "$destination/ControllerSession.swift"
    "$destination/ExperimentalControllerSession.swift"
    tests/session/FrameworkFakes.swift
    tests/support/ExperimentalFixture.swift
  )
}
