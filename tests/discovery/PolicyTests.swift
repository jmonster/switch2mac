import Foundation
import Synchronization
@main enum PolicyTests {
    static func main() {
        let suite = "discovery-policy-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = DispatchQueue(label: "policy-test"), changes = Mutex(0)
        let policy = DiscoveryPolicy(queue: queue, defaults: defaults) { changes.withLock { $0 += 1 } }
        queue.sync {
            let a = UUID(), b = UUID()
            precondition(policy.shouldScan(readyIDs: [a], now: 0))
            precondition(defaults.object(forKey: DiscoveryPolicy.rememberedKey) == nil)
            precondition(policy.work == nil)
            defaults.set(true, forKey: DiscoveryPolicy.enabledKey)
            precondition(policy.shouldScan(readyIDs: [a], now: 0))
            let firstDeadline = policy.work!
            precondition(policy.shouldScan(readyIDs: [a, b], now: 30))
            precondition(policy.work === firstDeadline, "unrelated state must not extend the setup window")
            precondition(!policy.shouldScan(readyIDs: [a, b], now: 60))
            precondition(policy.work == nil)
            precondition(policy.shouldScan(readyIDs: [a], now: 61))
            precondition(!policy.shouldScan(readyIDs: [a, b], now: 62))
            policy.openWindow(now: 62)
            let stale = policy.work!
            policy.openWindow(now: 63)
            stale.perform()
            precondition(changes.withLock { $0 } == 0 && policy.windowIsOpen(now: 70))
            policy.work!.perform()
            precondition(changes.withLock { $0 } == 1 && policy.work == nil)
            precondition(!policy.windowIsOpen(now: 70))
            policy.useConnected([a])
            precondition(!policy.shouldScan(readyIDs: [a], now: 100))
            _ = policy.shouldScan(readyIDs: (0..<100).map { _ in UUID() }, now: 101)
            precondition((defaults.stringArray(forKey: DiscoveryPolicy.rememberedKey) ?? []).count <= 8)
            defaults.set(["bad", "", a.uuidString, a.uuidString], forKey: DiscoveryPolicy.rememberedKey)
            precondition(!policy.shouldScan(readyIDs: [a], now: 102))
            defaults.set(false, forKey: DiscoveryPolicy.enabledKey)
            precondition(policy.shouldScan(readyIDs: [a], now: 103) && policy.work == nil)
            precondition(policy.shouldScan(readyIDs: [a], now: .nan))
        }
        print("PASS default discovery, bounded remembered set, full setup window, missing-unit wake and timer generations")
    }
}
