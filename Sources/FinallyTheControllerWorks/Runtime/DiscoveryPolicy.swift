import Foundation
import Switch2Kit

/// Application preference adapter. All discovery decisions and window timers live in Switch2Kit.
final class DiscoveryPolicy: @unchecked Sendable {
    static let enabledKey = "quietDiscoveryWhenReady"
    static let rememberedKey = "quietDiscoveryPeripheralIDs"
    static let windowSeconds: TimeInterval = 60
    private let queue: DispatchQueue
    private let defaults: UserDefaults
    private let policy: ControllerDiscoveryPolicy
    init(queue: DispatchQueue, defaults: UserDefaults = .standard, changed: @escaping @Sendable () -> Void) {
        self.queue = queue; self.defaults = defaults
        policy = ControllerDiscoveryPolicy(queue: queue, mode: defaults.bool(forKey: Self.enabledKey) ? .quietWhenReady : .automatic,
            remembered: Self.savedControllers(defaults: defaults).map(\.rawValue), capacity: 8, changed: changed)
    }
    static func savedControllers(defaults: UserDefaults = .standard) -> [Switch2ControllerID] {
        var result: [Switch2ControllerID] = []
        for value in (defaults.array(forKey: rememberedKey) ?? []).prefix(32) {
            guard let string = value as? String, let uuid = UUID(uuidString: string) else { continue }
            let id = Switch2ControllerID(rawValue: uuid)
            if !result.contains(id) { result.append(id) }
            if result.count == 8 { break }
        }
        return result
    }
    private func synchronizePreferences() {
        policy.configure(mode: defaults.bool(forKey: Self.enabledKey) ? .quietWhenReady : .automatic,
                         remembered: Self.savedControllers(defaults: defaults).map(\.rawValue))
    }
    private func save() {
        let ids = policy.remembered.map(\.uuidString)
        if defaults.stringArray(forKey: Self.rememberedKey) != ids { defaults.set(ids, forKey: Self.rememberedKey) }
    }
    func shouldScan(readyIDs: [UUID], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        synchronizePreferences()
        let value = policy.shouldScan(readyIDs: readyIDs, now: now)
        if defaults.bool(forKey: Self.enabledKey) { save() }
        return value
    }
    func windowIsOpen(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool { policy.windowIsOpen(now: now) }
    func openWindow(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        synchronizePreferences(); _ = policy.openWindow(now: now)
    }
    func cancelWindow() { policy.cancelWindow() }
    func useConnected(_ ids: [UUID]) {
        synchronizePreferences()
        guard defaults.bool(forKey: Self.enabledKey) else { return }
        policy.useConnected(ids); save()
    }
}
