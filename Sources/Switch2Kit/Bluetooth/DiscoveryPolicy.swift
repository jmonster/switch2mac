import Foundation

// Extracted ready-set/window state machine. Every mutable field and timer belongs to queue.
// Persistence is deliberately absent: the host supplies and saves remembered IDs explicitly.
package final class ControllerDiscoveryPolicy: @unchecked Sendable {
    package static let windowSeconds: TimeInterval = 60
    private let queue: DispatchQueue
    private let changed: @Sendable () -> Void
    private let capacity: Int
    private var wasQuiet = false
    private var until: TimeInterval?
    private var work: DispatchWorkItem?
    private var generation: UInt64 = 0
    package private(set) var mode: Switch2DiscoveryMode
    package private(set) var remembered: [UUID]
    package var deadline: TimeInterval? { until }

    package init(queue: DispatchQueue, mode: Switch2DiscoveryMode, remembered: [UUID] = [],
                 capacity: Int = 16, changed: @escaping @Sendable () -> Void) {
        self.queue = queue; self.mode = mode; self.changed = changed; self.capacity = min(64, max(1, capacity))
        var known: [UUID] = []
        for id in remembered.prefix(64) where !known.contains(id) { known.append(id) }
        self.remembered = Array(known.prefix(self.capacity))
    }
    deinit { work?.cancel() }

    package func configure(mode: Switch2DiscoveryMode, remembered: [UUID]) {
        dispatchPrecondition(condition: .onQueue(queue))
        if self.mode != mode { wasQuiet = false; cancelWindow() }
        self.mode = mode
        var known: [UUID] = []
        for id in remembered.prefix(64) where !known.contains(id) { known.append(id) }
        self.remembered = Array(known.prefix(capacity))
    }
    package func shouldScan(readyIDs: [UUID], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard now.isFinite else { cancelWindow(); return mode != .onDemand }
        if mode == .automatic { wasQuiet = false; cancelWindow(); return true }
        if mode == .onDemand {
            if let until, now >= until { cancelWindow() }
            return windowIsOpen(now: now)
        }
        let ready = Array(Set(readyIDs.prefix(capacity))).sorted { $0.uuidString < $1.uuidString }
        var known = remembered
        for id in ready where !known.contains(id) { known.append(id) }
        remembered = Array(known.suffix(capacity))
        if !wasQuiet {
            wasQuiet = true
            // Preserve the full setup window, including sequential Joy-Con halves.
            _ = openWindow(now: now)
        }
        if let until, now >= until { cancelWindow() }
        return windowIsOpen(now: now) || remembered.isEmpty || !Set(remembered).isSubset(of: Set(ready))
    }
    package func windowIsOpen(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return now.isFinite && (until.map { now < $0 } ?? false)
    }
    @discardableResult
    package func openWindow(seconds: TimeInterval = 60, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard seconds.isFinite, (0.1...300).contains(seconds), now.isFinite else { return false }
        guard mode != .automatic else { return true }
        cancelWindow()
        until = now + seconds
        let token = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.until != nil else { return }
            self.until = nil; self.work = nil
            self.changed()
        }
        work = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return true
    }
    package func cancelWindow() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation &+= 1; work?.cancel(); work = nil; until = nil
    }
    package func useConnected(_ ids: [UUID]) {
        dispatchPrecondition(condition: .onQueue(queue))
        remembered = Array(Set(ids.prefix(capacity))).sorted { $0.uuidString < $1.uuidString }
        cancelWindow()
    }
    package func forget(_ id: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        remembered.removeAll { $0 == id }
    }
}
