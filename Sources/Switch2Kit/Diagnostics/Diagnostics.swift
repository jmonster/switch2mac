import Foundation
import Synchronization
#if canImport(os)
import os
#endif

/// Diagnostic severity; increasing raw values indicate greater severity.
public enum Switch2LogLevel: Int, Comparable, Sendable {
    /// Protocol progress useful during development, with no raw frame contents.
    case debug
    /// Normal controller lifecycle progress.
    case info
    /// Recoverable failures or diagnostic backpressure.
    case warning
    /// A connection or operation could not complete.
    case error
    /// Compares diagnostic severity.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Fixed categories prevent a caller-supplied identifier from becoming a log category.
public enum Switch2LogCategory: String, Sendable {
    /// Bluetooth adapter, discovery and connection management.
    case bluetooth
    /// Controller handshake, command serialization and input health.
    case session
    /// Rumble or indicator-light commands.
    case control
    /// Bounded diagnostic-delivery backpressure.
    case diagnostics
    /// Unsupported, explicitly enabled experimental operations.
    case experimental
}

/// A bounded, privacy-safe diagnostic value. Switch2Kit never persists this value itself.
public struct Switch2LogRecord: Sendable {
    /// Host wall-clock creation time; not a controller timestamp.
    public let date: Date
    /// Diagnostic severity.
    public let level: Switch2LogLevel
    /// A fixed subsystem category.
    public let category: Switch2LogCategory
    /// A maximum 512-character message with no controller serial, peripheral ID, frame or sensor contents.
    public let message: String
}

/// Optional host diagnostic receiver. Calls are serialized on a private utility queue,
/// never on the Bluetooth queue or main actor. Hosts choose their own UI hop/persistence.
public typealias Switch2LogHandler = @Sendable (Switch2LogRecord) -> Void

// Mutable inbox is protected by Mutex; one utility-queue drain owns all handler calls.
// No file handles, directories, app preferences, or raw transport data are accepted here.
package final class Switch2Diagnostics: Sendable {
    private struct Inbox: Sendable { var records: [Switch2LogRecord] = []; var scheduled = false; var dropped = 0 }
    private let inbox = Mutex(Inbox())
    private let queue = DispatchQueue(label: "Switch2Kit.diagnostics", qos: .utility)
    private let handler: Switch2LogHandler?
    private let minimum: Switch2LogLevel
    #if canImport(os)
    private let logger = Logger(subsystem: "Switch2Kit", category: "controller")
    #endif
    package init(minimum: Switch2LogLevel = .info, handler: Switch2LogHandler? = nil) {
        self.minimum = minimum; self.handler = handler
    }
    // Call sites supply only reviewed, non-identifying text. No arbitrary Error.description forwarding.
    package func emit(_ level: Switch2LogLevel, _ category: Switch2LogCategory, _ message: String) {
        guard level >= minimum else { return }
        let record = Switch2LogRecord(date: Date(), level: level, category: category,
                                      message: String(message.prefix(512)))
        let schedule = inbox.withLock { state in
            if state.records.count < 128 { state.records.append(record) } else { state.dropped += 1 }
            guard !state.scheduled else { return false }
            state.scheduled = true; return true
        }
        if schedule { queue.async { [weak self] in self?.drain() } }
    }
    private func drain() {
        let batch = inbox.withLock { state -> [Switch2LogRecord] in
            var result = Array(state.records.prefix(32)); state.records.removeFirst(result.count)
            if state.dropped > 0 {
                result.append(Switch2LogRecord(date: Date(), level: .warning, category: .diagnostics,
                    message: "Dropped \(state.dropped) diagnostic records because the host consumer was slow."))
                state.dropped = 0
            }
            return result
        }
        for record in batch {
            #if canImport(os)
            switch record.level {
            case .debug: logger.debug("[\(record.category.rawValue, privacy: .public)] \(record.message, privacy: .public)")
            case .info: logger.info("[\(record.category.rawValue, privacy: .public)] \(record.message, privacy: .public)")
            case .warning: logger.warning("[\(record.category.rawValue, privacy: .public)] \(record.message, privacy: .public)")
            case .error: logger.error("[\(record.category.rawValue, privacy: .public)] \(record.message, privacy: .public)")
            }
            #endif
            handler?(record)
        }
        let again = inbox.withLock { state in
            if state.records.isEmpty && state.dropped == 0 { state.scheduled = false; return false }
            return true
        }
        if again { queue.async { [weak self] in self?.drain() } }
    }
    package var pendingCount: Int { inbox.withLock { $0.records.count } }
}
