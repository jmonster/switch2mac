// ControllerSettings.swift
// Per-controller preferences (custom name, rumble strength), keyed by the
// controller's serial number so they survive reconnects, slot shuffles, and
// app restarts. Backed by UserDefaults.

import Foundation
import Combine

final class ControllerSettings: ObservableObject {
    static let shared = ControllerSettings()

    private static let defaultsKey = "controllerSettings"

    /// serial -> {"name": String, "rumble": Double}
    @Published private var store: [String: [String: Any]]

    private init() {
        store = UserDefaults.standard.dictionary(forKey: Self.defaultsKey)
            as? [String: [String: Any]] ?? [:]
    }

    private func persist() {
        UserDefaults.standard.set(store, forKey: Self.defaultsKey)
    }

    // MARK: Custom name

    func customName(forSerial serial: String) -> String {
        store[serial]?["name"] as? String ?? ""
    }

    /// The name shown in UI: the custom name when set, else the model name.
    func displayName(forSerial serial: String, modelName: String) -> String {
        let custom = customName(forSerial: serial)
        return custom.isEmpty ? modelName : custom
    }

    func setCustomName(_ name: String, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["name"] = name.trimmingCharacters(in: .whitespaces)
        store[serial] = entry
        persist()
    }

    // MARK: Rumble strength

    func rumbleIntensity(forSerial serial: String) -> Double {
        store[serial]?["rumble"] as? Double ?? 1.0
    }

    func setRumbleIntensity(_ value: Double, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["rumble"] = value
        store[serial] = entry
        persist()
    }
}
