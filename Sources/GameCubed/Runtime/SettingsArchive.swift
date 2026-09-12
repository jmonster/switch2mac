import Foundation
import CoreFoundation

/// Validation and rollback support for whole-app settings imports.
///
/// Imports are intentionally fail-closed: the complete archive is decoded and
/// validated before either UserDefaults key is changed. A small on-disk
/// rollback record remains until both preference writes have been flushed, so
/// an interrupted import restores the previous pair on next launch.
enum SettingsArchive {
    static let version = 1
    static let maxArchiveBytes = 1_048_576
    static let maxControllers = 64
    static let maxLinks = 64
    static let recoveryFileName = "settings-import-rollback.plist"

    struct Payload: Codable {
        var controllerSettings: Data
        var joyConLinks: [String: String]
        var version: Int = SettingsArchive.version
    }

    struct Validated {
        let controllerSettings: [String: [String: Any]]
        let joyConLinks: [String: String]
    }

    private struct Rollback: Codable {
        let controllerSettings: Data
        let joyConLinks: Data
    }

    static func decode(_ data: Data) -> Validated? {
        guard data.count <= maxArchiveBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == version,
              payload.controllerSettings.count <= maxArchiveBytes,
              let raw = try? JSONSerialization.jsonObject(with: payload.controllerSettings),
              let settings = raw as? [String: [String: Any]],
              validate(settings: settings),
              validate(links: payload.joyConLinks) else { return nil }
        return Validated(controllerSettings: settings, joyConLinks: payload.joyConLinks)
    }

    static func encode(settings: [String: [String: Any]], links: [String: String]) -> Data? {
        guard validate(links: links), JSONSerialization.isValidJSONObject(settings),
              let controller = try? JSONSerialization.data(withJSONObject: settings),
              let normalized = try? JSONSerialization.jsonObject(with: controller) as? [String: [String: Any]],
              validate(settings: normalized) else { return nil }
        guard let archive = try? JSONEncoder().encode(Payload(controllerSettings: controller, joyConLinks: links)),
              archive.count <= maxArchiveBytes else { return nil }
        return archive
    }

    static func validate(settings: [String: [String: Any]]) -> Bool {
        guard settings.count <= maxControllers else { return false }
        for (serial, entry) in settings {
            guard validIdentifier(serial),
                  JSONSerialization.isValidJSONObject(entry),
                  (try? JSONSerialization.data(withJSONObject: entry).count).map({ $0 <= 131_072 }) == true,
                  validate(entry: entry) else { return false }
        }
        return true
    }

    static func validate(links: [String: String]) -> Bool {
        guard links.count <= maxLinks else { return false }
        var used = Set<String>()
        for (left, right) in links {
            guard validIdentifier(left), validIdentifier(right), left != right,
                  used.insert(left).inserted, used.insert(right).inserted else { return false }
        }
        return true
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")
    }

    private static func validate(entry: [String: Any]) -> Bool {
        func number(_ key: String, range: ClosedRange<Double>) -> Bool {
            guard let raw = entry[key] else { return true }
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
            let value = n.doubleValue
            return value.isFinite && range.contains(value)
        }
        func boolean(_ key: String) -> Bool {
            guard let raw = entry[key], let n = raw as? NSNumber else { return entry[key] == nil }
            return CFGetTypeID(n) == CFBooleanGetTypeID()
        }
        func vector(_ key: String, count: Int, magnitude: Double) -> Bool {
            guard let raw = entry[key] else { return true }
            let values: [Double]
            if let ns = raw as? [NSNumber] {
                guard ns.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() }) else { return false }
                values = ns.map(\.doubleValue)
            }
            else if let ds = raw as? [Double] { values = ds }
            else { return false }
            return values.count == count && values.allSatisfy { $0.isFinite && abs($0) <= magnitude }
        }
        guard number("rumble", range: 0...1),
              number("deadzone", range: 0...0.95),
              number("triggerThreshold", range: 0...1),
              number("mouseSensitivity", range: 0.1...5),
              boolean("invertLX"), boolean("invertLY"), boolean("invertRX"), boolean("invertRY"),
              boolean("mouseEnabled"), boolean("captureScreenshot"),
              vector("stickCenterL", count: 2, magnitude: 1),
              vector("stickCenterR", count: 2, magnitude: 1),
              vector("magBias", count: 3, magnitude: 1_000_000) else { return false }
        if let name = entry["name"] {
            guard let text = name as? String, text.utf8.count <= 256 else { return false }
        }
        if let pattern = entry["ledPattern"] {
            guard let n = pattern as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  (0...15).contains(n.intValue), n.doubleValue == Double(n.intValue) else { return false }
        }
        if let style = entry["holdStyle"] {
            guard let text = style as? String, text == "grip" || text == "independent" else { return false }
        }
        if let map = entry["buttonMap"] {
            guard let buttons = map as? [String: String], buttons.count <= 64,
                  buttons.allSatisfy({ Switch2.button(named: $0.key) != nil && Switch2.button(named: $0.value) != nil }) else { return false }
        }
        if let map = entry["keyMap"], !validateKeyMap(map) { return false }
        if let raw = entry["keyMapByApp"] {
            guard let apps = raw as? [String: Any], apps.count <= 128 else { return false }
            for (bundleID, map) in apps {
                guard !bundleID.isEmpty, bundleID.utf8.count <= 512, validateKeyMap(map) else { return false }
            }
        }
        return true
    }

    private static func validateKeyMap(_ raw: Any) -> Bool {
        guard let map = raw as? [String: [String: Any]], map.count <= 32 else { return false }
        return map.allSatisfy { name, spec in
            guard Switch2.button(named: name) != nil, KeySpec(dictionary: spec) != nil else { return false }
            return ["keyCode", "modifiers"].allSatisfy { key in
                guard let n = spec[key] as? NSNumber else { return false }
                return CFGetTypeID(n) != CFBooleanGetTypeID()
            }
        }
    }

    static func defaultRecoveryURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.switch2mac.gamecubed", isDirectory: true)
        return root.appendingPathComponent(recoveryFileName)
    }

    @discardableResult
    static func stageRollback(defaults: UserDefaults = .standard,
                              recoveryURL: URL = defaultRecoveryURL()) -> Bool {
        guard let previousSettings = plistData(defaults.dictionary(forKey: "controllerSettings") ?? [:]),
              let previousLinks = plistData(defaults.dictionary(forKey: "joyConLinks") ?? [:]),
              let rollback = try? PropertyListEncoder().encode(
                Rollback(controllerSettings: previousSettings, joyConLinks: previousLinks)) else { return false }
        do {
            try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try rollback.write(to: recoveryURL, options: [.atomic])
            return true
        } catch { return false }
    }

    @discardableResult
    static func apply(_ validated: Validated, defaults: UserDefaults = .standard,
                      recoveryURL: URL = defaultRecoveryURL()) -> Bool {
        // Never overwrite evidence of an interrupted import with half-written values.
        if FileManager.default.fileExists(atPath: recoveryURL.path),
           !recover(defaults: defaults, recoveryURL: recoveryURL) { return false }
        guard validate(settings: validated.controllerSettings), validate(links: validated.joyConLinks),
              stageRollback(defaults: defaults, recoveryURL: recoveryURL) else { return false }
        defaults.set(validated.controllerSettings, forKey: "controllerSettings")
        defaults.set(validated.joyConLinks, forKey: "joyConLinks")
        guard defaults.synchronize() else {
            _ = recover(defaults: defaults, recoveryURL: recoveryURL)
            return false
        }
        do { try FileManager.default.removeItem(at: recoveryURL) }
        catch { _ = recover(defaults: defaults, recoveryURL: recoveryURL); return false }
        return true
    }

    @discardableResult
    static func recover(defaults: UserDefaults = .standard,
                        recoveryURL: URL = defaultRecoveryURL()) -> Bool {
        guard let values = try? recoveryURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 16 * maxArchiveBytes,
              let data = try? Data(contentsOf: recoveryURL),
              let rollback = try? PropertyListDecoder().decode(Rollback.self, from: data),
              let settings = plistDictionary(rollback.controllerSettings),
              let links = plistDictionary(rollback.joyConLinks) else { return false }
        defaults.set(settings, forKey: "controllerSettings")
        defaults.set(links, forKey: "joyConLinks")
        guard defaults.synchronize() else { return false }
        do { try FileManager.default.removeItem(at: recoveryURL) }
        catch { return false }
        return true
    }

    private static func plistData(_ dictionary: [String: Any]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }
    private static func plistDictionary(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}
