import Foundation

/// Bluetooth-queue confined. The default remains continuous discovery while
/// capacity is available. The opt-in mode quiets discovery only when every
/// remembered physical controller is ready; losing one immediately permits
/// scanning again. It never disconnects a session or changes a keep-alive.
final class DiscoveryPolicy: @unchecked Sendable {
    static let enabledKey = "quietDiscoveryWhenReady"
    static let rememberedKey = "quietDiscoveryPeripheralIDs"
    static let windowSeconds: TimeInterval = 60
    private let queue: DispatchQueue
    private let defaults: UserDefaults
    private let changed: @Sendable () -> Void
    private var wasQuiet = false
    private var until: TimeInterval?
    private var work: DispatchWorkItem?
    private var generation: UInt64 = 0

    init(queue: DispatchQueue, defaults: UserDefaults = .standard,
         changed: @escaping @Sendable () -> Void) {
        self.queue = queue; self.defaults = defaults; self.changed = changed
    }
    deinit { work?.cancel() }

    private func remembered() -> [UUID] {
        var result: [UUID] = []
        for value in (defaults.array(forKey: Self.rememberedKey) ?? []).prefix(32) {
            guard let text = value as? String, let id = UUID(uuidString: text), !result.contains(id) else { continue }
            result.append(id)
            if result.count == 8 { break }
        }
        return result
    }
    private func save(_ ids: [UUID]) {
        let values = ids.map(\.uuidString)
        if defaults.stringArray(forKey: Self.rememberedKey) != values {
            defaults.set(values, forKey: Self.rememberedKey)
        }
    }
    func shouldScan(readyIDs: [UUID], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard now.isFinite else { cancelWindow(); return true }
        guard defaults.bool(forKey: Self.enabledKey) else {
            wasQuiet = false; cancelWindow(); return true
        }
        let ready = Array(Set(readyIDs.prefix(8))).sorted { $0.uuidString < $1.uuidString }
        var known = remembered()
        for id in ready where !known.contains(id) { known.append(id) }
        known = Array(known.suffix(8))
        save(known)
        if !wasQuiet {
            wasQuiet = true
            // Do not stop after the first new controller during initial setup;
            // give sequentially paired Joy-Con halves the full add-device window.
            openWindow(now: now)
        }
        if let until, now >= until { cancelWindow() }
        return windowIsOpen(now: now) || known.isEmpty || !Set(known).isSubset(of: Set(ready))
    }
    func windowIsOpen(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return now.isFinite && (until.map { now < $0 } ?? false)
    }
    func openWindow(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard defaults.bool(forKey: Self.enabledKey), now.isFinite else { return }
        cancelWindow()
        until = now + Self.windowSeconds
        let token = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.until != nil else { return }
            self.until = nil; self.work = nil
            self.changed()
        }
        work = item
        queue.asyncAfter(deadline: .now() + Self.windowSeconds, execute: item)
    }
    func cancelWindow() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation &+= 1
        work?.cancel(); work = nil; until = nil
    }
    func useConnected(_ ids: [UUID]) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard defaults.bool(forKey: Self.enabledKey) else { return }
        save(Array(Set(ids.prefix(8))).sorted { $0.uuidString < $1.uuidString })
        cancelWindow()
    }
}
