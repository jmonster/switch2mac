import Foundation
import Synchronization

/// A cancellable, bounded event observation. Retain it for as long as events are needed.
/// Cancellation is idempotent; queued work is discarded. A handler already executing
/// may finish, but no new handler invocation is started after cancellation is observed.
/// Delivery is serialized on the requested queue, including when that queue is concurrent.
public final class Switch2ControllerObservation: Sendable {
    private let mailbox: EventMailbox
    private let remove: @Sendable () -> Void
    package init(mailbox: EventMailbox, remove: @escaping @Sendable () -> Void) {
        self.mailbox = mailbox; self.remove = remove
    }
    /// Stops delivery and discards queued events without blocking on caller work.
    public func cancel() { mailbox.cancel(); remove() }
    deinit { cancel() }
}

// A token belongs to exactly one attempt. Retirement is terminal; a reconnect gets a NEW token.
package final class SessionLifetime: Sendable {
    package let id = UUID()
    private let active = Mutex(true)
    package var isActive: Bool { active.withLock { $0 } }
    package func retire() { active.withLock { $0 = false } }
}

package struct EventEnvelope: Sendable {
    package let sequence: UInt64
    package let event: Switch2ControllerEvent
    package let lifetime: SessionLifetime?
}

// Every mutable field is mutex-protected; handler calls are serialized by a single scheduled drain.
// The Bluetooth producer never invokes a handler, waits for a handler, or enqueues one task per report.
package final class EventMailbox: Sendable {
    private struct State: Sendable {
        var pending: [EventEnvelope] = []
        var overflow = false
        var scheduled = false
        var cancelled = false
        var delivered: UInt64 = 0
    }
    private let state = Mutex(State())
    private let capacity: Int
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private let current: @Sendable () -> EventEnvelope
    private let handler: @Sendable (Switch2ControllerEvent) -> Void
    package init(capacity: Int, queue: DispatchQueue, interval: TimeInterval = 0,
                 current: @escaping @Sendable () -> EventEnvelope,
                 handler: @escaping @Sendable (Switch2ControllerEvent) -> Void) {
        self.capacity = min(4096, max(1, capacity)); self.queue = queue
        self.interval = interval; self.current = current; self.handler = handler
    }
    package func enqueue(_ event: EventEnvelope) {
        let schedule = state.withLock { value in
            guard !value.cancelled, event.sequence > value.delivered else { return false }
            if value.pending.count >= capacity { value.pending.removeAll(keepingCapacity: true); value.overflow = true }
            if !value.overflow { value.pending.append(event) }
            guard !value.scheduled else { return false }
            value.scheduled = true; return true
        }
        if schedule { scheduleDrain() }
    }
    private func scheduleDrain() {
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in self?.drain() }
    }
    private func drain() {
        for _ in 0..<32 {
            let next: (Bool, EventEnvelope?) = state.withLock { value in
                guard !value.cancelled else { return (false, nil) }
                if value.overflow { value.overflow = false; return (true, nil) }
                guard !value.pending.isEmpty else { return (false, nil) }
                return (false, value.pending.removeFirst())
            }
            var envelope: EventEnvelope
            if next.0 { envelope = current() }
            else if let item = next.1 { envelope = item }
            else { break }
            // State snapshots are authoritative at delivery time, never historical ready sets.
            switch envelope.event {
            case .snapshot, .status: envelope = current()
            default: break
            }
            guard envelope.lifetime?.isActive != false else { continue }
            let deliver = state.withLock { value in
                guard !value.cancelled, envelope.sequence > value.delivered else { return false }
                value.delivered = envelope.sequence
                value.pending.removeAll { $0.sequence <= value.delivered }
                return true
            }
            if deliver { handler(envelope.event) }
        }
        let again = state.withLock { value in
            if value.cancelled || (!value.overflow && value.pending.isEmpty) {
                value.scheduled = false; return false
            }
            return true
        }
        if again { scheduleDrain() }
    }
    package func cancel() {
        state.withLock { $0.cancelled = true; $0.pending.removeAll(); $0.overflow = false }
    }
    package var pendingCount: Int { state.withLock { $0.pending.count } }
}

package final class ControllerEventHub: Sendable {
    private struct State: Sendable {
        var snapshot = Switch2ManagerSnapshot()
        var sequence: UInt64 = 1
        var nextObserver: UInt64 = 0
        var observers: [UInt64: EventMailbox] = [:]
    }
    private let state = Mutex(State())
    package var snapshot: Switch2ManagerSnapshot { state.withLock { $0.snapshot } }
    package func current() -> EventEnvelope {
        state.withLock { EventEnvelope(sequence: $0.sequence, event: .snapshot($0.snapshot), lifetime: nil) }
    }
    package func observe(queue: DispatchQueue, capacity: Int, interval: TimeInterval = 0,
                         handler: @escaping @Sendable (Switch2ControllerEvent) -> Void) throws -> Switch2ControllerObservation {
        guard (1...4096).contains(capacity), interval.isFinite, interval >= 0 else { throw Switch2KitError.invalidParameter }
        let mailbox = EventMailbox(capacity: capacity, queue: queue, interval: interval, current: { [weak self] in
            self?.current() ?? EventEnvelope(sequence: .max, event: .snapshot(.init()), lifetime: nil)
        }, handler: handler)
        let id = try state.withLock { value in
            guard value.observers.count < 32 else { throw Switch2KitError.observerLimitReached }
            value.nextObserver &+= 1
            let id = value.nextObserver; value.observers[id] = mailbox
            mailbox.enqueue(EventEnvelope(sequence: value.sequence, event: .snapshot(value.snapshot), lifetime: nil))
            return id
        }
        return Switch2ControllerObservation(mailbox: mailbox) { [weak self] in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
    }
    // Called only on the transport queue. Immutable snapshots leave that queue through this hub.
    package func publish(_ snapshot: Switch2ManagerSnapshot, event: Switch2ControllerEvent,
                         lifetime: SessionLifetime? = nil) {
        state.withLock { value in
            value.snapshot = snapshot; value.sequence &+= 1
            let envelope = EventEnvelope(sequence: value.sequence, event: event, lifetime: lifetime)
            for mailbox in value.observers.values { mailbox.enqueue(envelope) }
        }
    }
    package func cancelAll() {
        state.withLock { value in
            for mailbox in value.observers.values { mailbox.cancel() }
            value.observers.removeAll()
        }
    }
}
