// LogStore.swift
// In-app log: an observable ring buffer feeding the live log view, mirrored
// to a rotating file in ~/Library/Logs/FinallyTheControllerWorks/ so
// diagnostics survive crashes and can be exported.

import Foundation
import os

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

    /// Ring-buffer cap: plenty for a play session, bounded for memory.
    private static let capacity = 5_000

    @Published private(set) var entries: [LogEntry] = []
    private var nextID: UInt64 = 0
    private let osLog = Logger(subsystem: "com.petersharma.finallythecontrollerworks",
                               category: "bridge")
    private let fileHandle: FileHandle?
    private let fileFormatter: DateFormatter

    private init() {
        fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let logsDir = FileManager.default.urls(for: .libraryDirectory,
                                               in: .userDomainMask)[0]
            .appendingPathComponent("Logs/FinallyTheControllerWorks", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir,
                                                 withIntermediateDirectories: true)
        let fileURL = logsDir.appendingPathComponent("bridge.log")

        // Rotate at 5 MB: single .old generation is enough for diagnostics.
        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
           size > 5_000_000 {
            let old = logsDir.appendingPathComponent("bridge.log.old")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: fileURL, to: old)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        _ = try? fileHandle?.seekToEnd()
    }

    var logFileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/FinallyTheControllerWorks/bridge.log")
    }

    func log(_ level: LogLevel, _ subsystem: String, _ message: String) {
        let entry = LogEntry(id: nextID, date: Date(), level: level,
                             subsystem: subsystem, message: message)
        nextID += 1
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }

        switch level {
        case .debug: osLog.debug("[\(subsystem)] \(message)")
        case .info: osLog.info("[\(subsystem)] \(message)")
        case .warning: osLog.warning("[\(subsystem)] \(message)")
        case .error: osLog.error("[\(subsystem)] \(message)")
        }

        let line = "\(fileFormatter.string(from: entry.date)) \(level.rawValue) [\(subsystem)] \(message)\n"
        if let data = line.data(using: .utf8) {
            try? fileHandle?.write(contentsOf: data)
        }
    }
}

/// Fire-and-forget logging from any actor/queue.
func bridgeLog(_ level: LogLevel, _ subsystem: String, _ message: String) {
    Task { @MainActor in
        LogStore.shared.log(level, subsystem, message)
    }
}
