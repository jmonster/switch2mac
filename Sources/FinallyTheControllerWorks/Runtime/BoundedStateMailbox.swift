import Foundation
import Synchronization

/// Bounded, single-consumer admission for high-rate state streams.
///
/// Callers enqueue from any thread. At most one drain callback needs to be
/// scheduled at a time. Normal traffic is preserved in order per slot. If a
/// slot outruns its consumer or waits too long, its queued states are replaced
/// by an explicit recovery containing the newest state so the sink can
/// neutralize before reasserting it instead of silently losing a release.
final class BoundedStateMailbox<State: Sendable>: Sendable {
    struct Item: Sendable {
        let slot: Int
        let state: State
        let enqueuedAt: TimeInterval
    }

    struct Batch: Sendable {
        let items: [Item]
        let recoveries: [(slot: Int, latest: State)]
        var isEmpty: Bool { items.isEmpty && recoveries.isEmpty }
    }

    private struct Storage {
        var pending: [Int: [Item]] = [:]
        var recovery: [Int: State] = [:]
        var drainScheduled = false
    }

    private let storage = Mutex(Storage())
    private let perSlotCapacity: Int
    private let maxAge: TimeInterval
    private let batchLimit: Int

    init(perSlotCapacity: Int = 64, maxAge: TimeInterval = 0.25,
         batchLimit: Int = 32) {
        precondition(perSlotCapacity > 0 && maxAge > 0 && batchLimit > 0)
        self.perSlotCapacity = perSlotCapacity
        self.maxAge = maxAge
        self.batchLimit = batchLimit
    }

    /// Returns true exactly when the caller must schedule a drain callback.
    @discardableResult
    func submit(slot: Int, state: State,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        storage.withLock { value in
            if value.recovery[slot] != nil {
                value.recovery[slot] = state
            } else {
                var queue = value.pending[slot] ?? []
                if queue.count >= perSlotCapacity {
                    // We can no longer prove that every digital edge will be
                    // delivered. Discard this slot's stale backlog and require
                    // the sink to send neutral + newest state.
                    queue.removeAll(keepingCapacity: true)
                    value.pending[slot] = queue
                    value.recovery[slot] = state
                } else {
                    queue.append(Item(slot: slot, state: state, enqueuedAt: now))
                    value.pending[slot] = queue
                }
            }
            if value.drainScheduled { return false }
            value.drainScheduled = true
            return true
        }
    }

    /// Discard queued work for a retired logical slot.
    func clear(slot: Int) {
        storage.withLock { value in
            value.pending.removeValue(forKey: slot)
            value.recovery.removeValue(forKey: slot)
        }
    }

    func clearAll() {
        storage.withLock { value in
            value.pending.removeAll(keepingCapacity: false)
            value.recovery.removeAll(keepingCapacity: false)
        }
    }

    /// Take a bounded round-robin batch. Stale queues become recoveries.
    func take(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Batch {
        storage.withLock { value in
            for slot in Array(value.pending.keys) {
                guard let queue = value.pending[slot], let first = queue.first else {
                    value.pending.removeValue(forKey: slot)
                    continue
                }
                if now - first.enqueuedAt > maxAge {
                    if let latest = queue.last?.state { value.recovery[slot] = latest }
                    value.pending.removeValue(forKey: slot)
                }
            }

            let recoveries = value.recovery.keys.sorted().compactMap { slot in
                value.recovery[slot].map { (slot, $0) }
            }
            value.recovery.removeAll(keepingCapacity: true)

            var items: [Item] = []
            items.reserveCapacity(batchLimit)
            var slots = value.pending.keys.sorted()
            while items.count < batchLimit && !slots.isEmpty {
                var nextSlots: [Int] = []
                for slot in slots where items.count < batchLimit {
                    guard var queue = value.pending[slot], !queue.isEmpty else {
                        value.pending.removeValue(forKey: slot)
                        continue
                    }
                    items.append(queue.removeFirst())
                    if queue.isEmpty { value.pending.removeValue(forKey: slot) }
                    else { value.pending[slot] = queue; nextSlots.append(slot) }
                }
                slots = nextSlots
            }
            return Batch(items: items, recoveries: recoveries)
        }
    }

    /// Call after processing one batch. True means enqueue another drain
    /// callback; false releases the scheduled token for the next submitter.
    func completeDrain() -> Bool {
        storage.withLock { value in
            if !value.pending.isEmpty || !value.recovery.isEmpty { return true }
            value.drainScheduled = false
            return false
        }
    }
}
