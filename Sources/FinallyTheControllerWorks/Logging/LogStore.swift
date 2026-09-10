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
             Task { @MainActor in LogStore.shared.append(entries) }
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
                                              message: String(message.prefix(16_384))))
                state.nextID &+= 1
            }
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if shouldSchedule { writerQueue.async { [weak self] in self?.drain() } }
    }

    func flush() { writerQueue.sync { drainSynchronously() } }

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
            case .debug: logger.debug("[\(entry.subsystem, privacy: .public)] \(entry.message, privacy: .public)")
            case .info: logger.info("[\(entry.subsystem, privacy: .public)] \(entry.message, privacy: .public)")
            case .warning: logger.warning("[\(entry.subsystem, privacy: .public)] \(entry.message, privacy: .public)")
            case .error: logger.error("[\(entry.subsystem, privacy: .public)] \(entry.message, privacy: .public)")
            }
        }
        write(batch)
        deliver(batch)
        batch.removeAll(keepingCapacity: false)
    }

    private func openFile() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
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
            try? FileManager.default.moveItem(at: fileURL, to: oldFileURL)
        }
        openFile()
    }

    private func write(_ entries: [LogEntry]) {
        let text = entries.map { entry in
            "\(formatter.string(from: entry.date)) \(entry.level.rawValue) [\(entry.subsystem)] \(entry.message)\n"
        }.joined()
        guard let data = text.data(using: .utf8) else { return }
        rotateIfNeeded(incoming: data.count)
        do {
            try fileHandle?.write(contentsOf: data)
            fileBytes += data.count
        } catch {
            try? fileHandle?.close(); fileHandle = nil
            openFile()
        }
    }
}

func bridgeLog(_ level: LogLevel, _ subsystem: String, _ message: String) {
    LogPipeline.shared.submit(level, subsystem, message)
}
