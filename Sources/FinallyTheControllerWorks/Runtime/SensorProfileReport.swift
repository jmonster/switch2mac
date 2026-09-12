import Foundation

/// Pure description of the exact process-stable flags used by the BLE
/// handshake. This is not a hardware probe and never starts a controller.
enum SensorProfileReport {
    static func data(revision: String?) throws -> Data {
        let profile = ApplicationSensorPolicy.selectedProfile
        let rawRevision = revision ?? ""
        let source = rawRevision.utf8.count == 40 && rawRevision.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        } ? rawRevision : "unknown"
        let models: [[String: Any]] = Switch2.Model.allCases.map { model in
            let flags = Switch2.Feature.flags(for: model, profile: profile)
            return ["model": String(format: "%04x", model.rawValue),
                    "feature_mask": String(format: "%02x", flags),
                    "motion_requested": flags & Switch2.Feature.motion != 0,
                    "pointer_requested": flags & Switch2.Feature.mouse != 0,
                    "magnetometer_requested": flags & Switch2.Feature.magnetometer != 0]
        }
        let report: [String: Any] = ["schema": 1, "source_revision": source,
            "selected_profile": profile.rawValue, "models": models,
            "scope": "configuration-only; no Bluetooth, listeners or permission prompts",
            "hardware_qualification": "not-run", "energy_measurement": "not-run",
            "scanning_policy": "unchanged", "keep_alive_policy": "unchanged",
            "rollback": "Quit and relaunch without experimental environment variables; reconnect controllers."]
        var data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        data.append(10)
        return data
    }
}
