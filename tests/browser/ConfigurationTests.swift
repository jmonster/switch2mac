import Foundation

@main enum ConfigurationTests {
    static func main() throws {
        let id = String(repeating: "a", count: 32)
        let other = String(repeating: "b", count: 32)
        let config = try BrowserBridgeConfiguration(enabled: true, extensionIDs: "\(other), \(id) \(id)")
        precondition(config.origins.count == 2 && config.extensionIDs == "\(id) \(other)")
        for bad in ["", "*", "https://example.com", id + "x", id.uppercased(), id + " invalid", String(repeating: "x", count: 513)] {
            do { _ = try BrowserBridgeConfiguration(enabled: true, extensionIDs: bad); fatalError("Invalid IDs accepted") }
            catch is BrowserBridgeConfiguration.ValidationError {}
        }
        let tooMany = (0..<9).map { String(repeating: Character(UnicodeScalar(97 + $0)!), count: 32) }.joined(separator: " ")
        precondition((try? BrowserBridgeConfiguration(enabled: true, extensionIDs: tooMany)) == nil)
        let suite = "browser-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(BrowserBridgeConfiguration.load(defaults: defaults) == .disabled)
        defaults.set(true, forKey: BrowserBridgeConfiguration.legacyEnabledKey)
        defaults.set(id, forKey: BrowserBridgeConfiguration.legacyIDsKey)
        precondition(BrowserBridgeConfiguration.load(defaults: defaults).enabled)
        config.save(defaults: defaults)
        precondition(BrowserBridgeConfiguration.load(defaults: defaults) == config)
        for invalid: Any in ["broken", ["schema": 99], ["schema": 1, "enabled": true, "extensionIDs": "*"]] {
            defaults.set(invalid, forKey: BrowserBridgeConfiguration.key)
            precondition(BrowserBridgeConfiguration.load(defaults: defaults) == .disabled,
                         "Corrupt new settings must not restore an old allowlist")
        }
        BrowserBridgeConfiguration.disabled.save(defaults: defaults)
        precondition(!BrowserBridgeConfiguration.load(defaults: defaults).enabled)
        print("PASS bounded exact IDs, atomic settings, legacy migration and fail-closed corruption")
    }
}
