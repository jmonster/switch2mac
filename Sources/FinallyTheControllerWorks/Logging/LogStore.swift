// LogStore.swift
// Diagnostics are accepted from hot paths without hopping to MainActor for
// every entry. A bounded pipeline batches UI delivery and serializes file IO.

import Foundation
import Combine
import os
import Synchronization

enum LogLevel: String, CaseIterable, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    var sortRank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }
}

struct LogEntry: Identifiable, Sendable {
    let id: UInt64
    let date: Date
    let level: LogLevel
    let subsystem: String
    let message: String
}

@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()
    private static let capacity = 5_000
    private static let trimBatch = 512

    @Published private(set) var entries: [LogEntry] = []
    private init() {}

    private struct Inbox: Sendable {
        var entries: [LogEntry] = []
        var scheduled = false
    }
    private nonisolated static let inbox = Mutex(Inbox())

    // Display only the newest window of logs if the main actor stalls. The
    // file writer remains independent, and at most one UI task is queued.
    nonisolated static func enqueue(_ batch: [LogEntry]) {
        let schedule = inbox.withLock { state in
            state.entries.append(contentsOf: batch.suffix(5_000))
            if state.entries.count > 5_000 { state.entries.removeFirst(state.entries.count - 5_000) }
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if schedule { Task { @MainActor in drainInbox() } }
    }

    nonisolated static var pendingPresentationCount: Int { inbox.withLock { $0.entries.count } }

    private static func drainInbox() {
        let batch = inbox.withLock { state in
            let entries = state.entries
            state.entries.removeAll(keepingCapacity: true)
            state.scheduled = false
            return entries
        }
        shared.append(batch)
    }

    fileprivate func append(_ batch: [LogEntry]) {
        guard !batch.isEmpty else { return }
        entries.append(contentsOf: batch)
        if entries.count > Self.capacity {
            let overflow = entries.count - Self.capacity
            entries.removeFirst(min(entries.count, max(overflow, Self.trimBatch)))
        }
    }

    var logFileURL: URL { LogPipeline.shared.fileURL }
}

final class LogPipeline: @unchecked Sendable {
    static let shared = LogPipeline()

    private struct Buffer {
        var pending: [LogEntry] = []
        var dropped = 0
        var scheduled = false
        var nextID: UInt64 = 0
    }

    let fileURL: URL
    private let oldFileURL: URL
    private let maxFileBytes: Int
    private let maxPending: Int
    private let batchSize: Int
    private let buffer = Mutex(Buffer())
    private let writerQueue = DispatchQueue(label: "io.github.jmonster.switch2mac.logging", qos: .utility)
    private let logger = Logger(subsystem: "io.github.jmonster.switch2mac", category: "bridge")
    private let formatter: DateFormatter
    private var fileHandle: FileHandle?
    private var fileBytes = 0
    private let deliver: @Sendable ([LogEntry]) -> Void

    convenience init() {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/io.github.jmonster.switch2mac", isDirectory: true)
        self.init(directory: directory)
    }

    init(directory: URL, maxFileBytes: Int = 5_000_000, maxPending: Int = 2_048,
         batchSize: Int = 256,
         deliver: @escaping @Sendable ([LogEntry]) -> Void = { entries in
             LogStore.enqueue(entries)
         }) {
        precondition(maxFileBytes > 0 && maxPending > 0 && batchSize > 0)
        fileURL = directory.appendingPathComponent("bridge.log")
        oldFileURL = directory.appendingPathComponent("bridge.log.old")
        self.maxFileBytes = maxFileBytes
        self.maxPending = maxPending
        self.batchSize = batchSize
        self.deliver = deliver
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        writerQueue.sync { openFile() }
    }

    func submit(_ level: LogLevel, _ subsystem: String, _ message: String) {
        let shouldSchedule = buffer.withLock { state -> Bool in
            if state.pending.count >= maxPending {
                state.dropped += 1
            } else {
                state.pending.append(LogEntry(id: state.nextID, date: Date(), level: level,
                                              subsystem: String(subsystem.prefix(64)),
                                              message: String(decoding: message.utf8.prefix(16_384), as: UTF8.self)))
                state.nextID &+= 1
            }
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if shouldSchedule { writerQueue.async { [weak self] in self?.drain() } }
    }

    /// Drain the work present at entry, without waiting indefinitely for new producers.
    func flush() {
        writerQueue.sync {
            let batches = buffer.withLock { ($0.pending.count + batchSize - 1) / batchSize + 1 }
            for _ in 0..<batches { drainSynchronously() }
            try? fileHandle?.synchronize()
        }
    }

    private func drain() {
        drainSynchronously()
        let needsMore = buffer.withLock { state -> Bool in
            if state.pending.isEmpty && state.dropped == 0 {
                state.scheduled = false
                return false
            }
            return true
        }
        if needsMore { writerQueue.async { [weak self] in self?.drain() } }
    }

    private func drainSynchronously() {
        var batch = buffer.withLock { state -> [LogEntry] in
            var out: [LogEntry] = []
            if state.dropped > 0 {
                out.append(LogEntry(id: state.nextID, date: Date(), level: .warning,
                                    subsystem: "logging",
                                    message: "dropped \(state.dropped) diagnostic messages due to backpressure"))
                state.nextID &+= 1
                state.dropped = 0
            }
            let count = min(batchSize - min(1, out.count), state.pending.count)
            if count > 0 {
                out.append(contentsOf: state.pending.prefix(count))
                state.pending.removeFirst(count)
            }
            return out
        }
        guard !batch.isEmpty else { return }
        for entry in batch {
            switch entry.level {
            case .debug: logger.debug("[\(entry.subsystem, privacy: .public)] \(entry.message, privacy: .private)")
            case .info: logger.info("[\(entry.subsystem, privacy: .public)] \(entry.message, privacy: .private)")
            case .warning: logger.warning("[\(entry.subsystem, privacy: .public)] \(entry.message, privacy: .private)")
            case .error: logger.error("[\(entry.subsystem, privacy: .public)] \(entry.message, privacy: .private)")
            }
        }
        write(batch)
        deliver(batch)
        batch.removeAll(keepingCapacity: false)
    }

    private func openFile() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        fileBytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        _ = try? fileHandle?.seekToEnd()
    }

    private func rotateIfNeeded(incoming: Int) {
        guard fileBytes + incoming > maxFileBytes else { return }
        try? fileHandle?.close(); fileHandle = nil
        try? FileManager.default.removeItem(at: oldFileURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.moveItem(atPath: fileURL.path, toPath: oldFileURL.path)
        }
        openFile()
    }

    private func write(_ entries: [LogEntry]) {
        // Batch disk writes as well as UI delivery. Keep complete lines on
        // either side of rotation and cap ordinary chunks at 64 KiB. submit()
        // already bounds each message to 16 KiB (plus its small header).
        let chunkLimit = 64 * 1024
        var pending = Data(capacity: min(chunkLimit, maxFileBytes))
        func flushPending() {
            guard !pending.isEmpty else { return }
            let data = pending
            pending.removeAll(keepingCapacity: true)
            guard let handle = fileHandle else { return }
            do {
                try handle.write(contentsOf: data)
                fileBytes += data.count
            } catch {
                // A partial write may have reached disk. Reopen to refresh the
                // byte count; do not retry the chunk and duplicate its prefix.
                try? handle.close(); fileHandle = nil
                openFile()
            }
        }
        for entry in entries {
            let message = entry.message.replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            let line = "\(formatter.string(from: entry.date)) \(entry.level.rawValue) [\(entry.subsystem)] \(message)"
            var data = Data(line.utf8.prefix(maxFileBytes - 1))
            while String(data: data, encoding: .utf8) == nil { data.removeLast() }
            data.append(10)
            if !pending.isEmpty && (pending.count + data.count > chunkLimit
                || fileBytes + pending.count + data.count > maxFileBytes) {
                flushPending()
            }
            if pending.isEmpty { rotateIfNeeded(incoming: data.count) }
            guard fileHandle != nil, fileBytes + pending.count + data.count <= maxFileBytes else { continue }
            pending.append(data)
        }
        flushPending()
    }

}

func bridgeLog(_ level: LogLevel, _ subsystem: String, _ message: String) {
    LogPipeline.shared.submit(level, subsystem, message)
}
