// ControllerSettings.swift
// Per-controller preferences (custom name, rumble strength), keyed by the
// controller's serial number so they survive reconnects, slot shuffles, and
// app restarts. Backed by UserDefaults.

import Foundation
import Combine

final class ControllerSettings: ObservableObject {
    static let shared = ControllerSettings()

    /// Posted after a custom name changes so the engine can re-announce
    /// controller names to games.
    static let namesChangedNotification = Notification.Name("ftcw.namesChanged")

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
        NotificationCenter.default.post(name: Self.namesChangedNotification, object: nil)
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

    // MARK: Axis options

    func deadzone(forSerial serial: String) -> Double {
        store[serial]?["deadzone"] as? Double ?? 0.0
    }

    func setDeadzone(_ value: Double, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["deadzone"] = value
        store[serial] = entry
        persist()
    }

    func invertLeftY(forSerial serial: String) -> Bool {
        store[serial]?["invertLY"] as? Bool ?? false
    }

    func invertRightY(forSerial serial: String) -> Bool {
        store[serial]?["invertRY"] as? Bool ?? false
    }

    func setInvertLeftY(_ value: Bool, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["invertLY"] = value
        store[serial] = entry
        persist()
    }

    func setInvertRightY(_ value: Bool, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["invertRY"] = value
        store[serial] = entry
        persist()
    }
}
