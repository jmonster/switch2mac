import Foundation
import Synchronization

/// Presentation only: bounded newest snapshots and at most one main-queue task.
/// This is deliberately NOT used for game input, whose press/release edges matter.
final class VisualizerMailbox<State: Sendable>: Sendable {
    private struct Storage {
        var subscribers = Set<UUID>()
        var latest: [Int: State] = [:]
        var lastAdmission: TimeInterval = -.infinity
        var scheduled = false
    }
    private let storage = Mutex(Storage())
    private let maxSlots: Int
    private let interval: TimeInterval

    init(maxSlots: Int, interval: TimeInterval = 0.1) {
        precondition(maxSlots > 0 && interval.isFinite && interval > 0)
        self.maxSlots = maxSlots; self.interval = interval
    }
    var hasSubscribers: Bool { storage.withLock { !$0.subscribers.isEmpty } }
    func setSubscriber(_ id: UUID, visible: Bool) {
        storage.withLock { value in
            if visible { value.subscribers.insert(id) } else { value.subscribers.remove(id) }
            if value.subscribers.isEmpty {
                value.latest.removeAll(); value.lastAdmission = -.infinity
                // Do not release an already queued task's token. It will drain
                // the current generation (possibly empty), not its old snapshot.
            }
        }
    }
    func submit(slot: Int, state: State,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard (0..<maxSlots).contains(slot) else { return false }
        return storage.withLock { value in
            guard !value.subscribers.isEmpty else { return false }
            value.latest[slot] = state
            guard !value.scheduled, now - value.lastAdmission >= interval else { return false }
            value.lastAdmission = now; value.scheduled = true
            return true
        }
    }
    func clear(slot: Int) -> Bool {
        storage.withLock { value in
            value.latest.removeValue(forKey: slot)
            guard !value.subscribers.isEmpty, !value.scheduled else { return false }
            value.scheduled = true; return true
        }
    }
    func clearAll() -> Bool {
        storage.withLock { value in
            value.latest.removeAll(); value.lastAdmission = -.infinity
            guard !value.subscribers.isEmpty, !value.scheduled else { return false }
            value.scheduled = true; return true
        }
    }
    func take() -> [Int: State] {
        storage.withLock { value in
            value.scheduled = false
            return value.subscribers.isEmpty ? [:] : value.latest
        }
    }
}
