import Foundation

/// One preference value is the commit boundary for enabled + allowed origins.
/// A malformed new-format value never falls back to an older, permissive value.
struct BrowserBridgeConfiguration: Equatable, Sendable {
    static let key = "browserBridgeConfiguration"
    static let legacyEnabledKey = "browserBridgeEnabled"
    static let legacyIDsKey = "browserBridgeExtensionIDs"
    let enabled: Bool
    let extensionIDs: String
    let origins: Set<String>

    enum ValidationError: Error, LocalizedError {
        case invalidIDs, missingIDs
        var errorDescription: String? {
            switch self {
            case .invalidIDs: return "Use at most eight exact 32-letter extension IDs (letters a–p), separated by spaces or commas."
            case .missingIDs: return "Add at least one extension ID before enabling the browser bridge."
            }
        }
    }
    init(enabled: Bool, extensionIDs: String) throws {
        guard extensionIDs.utf8.count <= 512 else { throw ValidationError.invalidIDs }
        let ids = Set(extensionIDs.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init))
        guard ids.count <= 8, ids.allSatisfy({ id in
            id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains($0) }
        }) else { throw ValidationError.invalidIDs }
        guard !enabled || !ids.isEmpty else { throw ValidationError.missingIDs }
        self.enabled = enabled
        self.extensionIDs = ids.sorted().joined(separator: " ")
        self.origins = Set(ids.map { "chrome-extension://" + $0 })
    }
    static var disabled: Self { try! Self(enabled: false, extensionIDs: "") }
    static func load(defaults: UserDefaults = .standard) -> Self {
        if let raw = defaults.object(forKey: key) {
            guard let value = raw as? [String: Any], value["schema"] as? Int == 1,
                  let enabled = value["enabled"] as? Bool,
                  let ids = value["extensionIDs"] as? String else { return .disabled }
            return (try? Self(enabled: enabled, extensionIDs: ids)) ?? .disabled
        }
        return (try? Self(enabled: defaults.bool(forKey: legacyEnabledKey),
                          extensionIDs: defaults.string(forKey: legacyIDsKey) ?? "")) ?? .disabled
    }
    func save(defaults: UserDefaults = .standard) {
        defaults.set(["schema": 1, "enabled": enabled, "extensionIDs": extensionIDs], forKey: Self.key)
    }
}
