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

    /// Stick axes that can be inverted, keyed by their UserDefaults name.
    enum StickAxis: String, CaseIterable {
        case leftX = "invertLX"
        case leftY = "invertLY"
        case rightX = "invertRX"
        case rightY = "invertRY"

        var label: String {
            switch self {
            case .leftX: return "Left thumbstick X"
            case .leftY: return "Left thumbstick Y"
            case .rightX: return "Right thumbstick X"
            case .rightY: return "Right thumbstick Y"
            }
        }
    }

    func invert(_ axis: StickAxis, forSerial serial: String) -> Bool {
        store[serial]?[axis.rawValue] as? Bool ?? false
    }

    func setInvert(_ axis: StickAxis, _ value: Bool, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry[axis.rawValue] = value
        store[serial] = entry
        persist()
    }

    // MARK: Joy-Con pair hold style

    /// How a linked pair is physically held: "grip" (controller grip shell)
    /// or "independent" (one Joy-Con per hand). Affects the input-test
    /// layout now and sensor orientation math later.
    func holdStyle(forSerial serial: String) -> String {
        store[serial]?["holdStyle"] as? String ?? "grip"
    }

    func setHoldStyle(_ value: String, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["holdStyle"] = value
        store[serial] = entry
        persist()
    }

    // MARK: Button layout

    func xboxLayout(forSerial serial: String) -> Bool {
        store[serial]?["xboxLayout"] as? Bool ?? false
    }

    func setXboxLayout(_ value: Bool, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["xboxLayout"] = value
        store[serial] = entry
        persist()
    }

    /// True when every axis is inverted (the "invert all" master state).
    func invertsAll(forSerial serial: String) -> Bool {
        StickAxis.allCases.allSatisfy { invert($0, forSerial: serial) }
    }

    func setInvertAll(_ value: Bool, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        for axis in StickAxis.allCases {
            entry[axis.rawValue] = value
        }
        store[serial] = entry
        persist()
    }
}
