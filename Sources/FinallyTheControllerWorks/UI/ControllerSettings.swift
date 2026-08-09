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

    /// Forget everything stored about a controller (name, mappings, axis
    /// options, mouse mode, hold style).
    func removeSettings(forSerial serial: String) {
        store.removeValue(forKey: serial)
        persist()
        NotificationCenter.default.post(name: Self.namesChangedNotification, object: nil)
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

    // MARK: Mouse mode (Joy-Con 2 optical sensor)

    func mouseEnabled(forSerial serial: String) -> Bool {
        store[serial]?["mouseEnabled"] as? Bool ?? false
    }

    func setMouseEnabled(_ value: Bool, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["mouseEnabled"] = value
        store[serial] = entry
        persist()
    }

    func mouseSensitivity(forSerial serial: String) -> Double {
        store[serial]?["mouseSensitivity"] as? Double ?? 1.0
    }

    func setMouseSensitivity(_ value: Double, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["mouseSensitivity"] = value
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

    // MARK: Button mapping

    /// physical name -> output name; absent key = identity.
    func buttonMap(forSerial serial: String) -> [String: String] {
        store[serial]?["buttonMap"] as? [String: String] ?? [:]
    }

    func setButtonMapping(physical: String, output: String, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        var map = entry["buttonMap"] as? [String: String] ?? [:]
        if output == physical {
            map.removeValue(forKey: physical)   // identity = no entry
        } else {
            map[physical] = output
        }
        entry["buttonMap"] = map
        store[serial] = entry
        persist()
    }

    func resetButtonMap(forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["buttonMap"] = [String: String]()
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
