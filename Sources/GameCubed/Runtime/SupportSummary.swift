import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Export a small allowlisted summary, never a best-effort regex scrub of raw
/// diagnostic messages. Messages, device identifiers and arbitrary preferences
/// are intentionally not accepted by this API.
enum SupportSummary {
    static let maximumBytes = 65_536
    static let maximumEvents = 5_000
    struct Event {
        let level: String
        let subsystem: String
    }
    enum Failure: Error { case invalidDestination, oversized, writeFailed }
    private static let subsystems: Set<String> = [
        "app", "engine", "session", "udphub", "wshub", "netpad", "virtualhid", "logging"
    ]
    private static let levels: Set<String> = ["DEBUG", "INFO", "WARN", "ERROR"]

    static func make(revision: String?, dirty: Bool?, os: OperatingSystemVersion,
                     architecture: String, engineState: String,
                     models: [Switch2.Model], outputs: [OutputHealth],
                     snapshotAge: TimeInterval?, events: [Event]) throws -> Data {
        let revision = revision ?? ""
        let source = revision.utf8.count == 40 && revision.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) ? revision : "unknown"
        func bounded(_ value: Int, _ maximum: Int = 999) -> Int { max(0, min(maximum, value)) }
        let states: Set<String> = ["paused", "off", "unauthorized", "scanning", "connecting", "idle", "ready"]
        var counts: [String: Int] = [:]
        for event in events.suffix(maximumEvents) {
            let category = subsystems.contains(event.subsystem) ? event.subsystem : "other"
            let level = levels.contains(event.level) ? event.level : "other"
            counts[category + "." + level, default: 0] += 1
        }
        var latest: [OutputBackend: OutputHealth] = [:]
        for output in outputs.prefix(4) { latest[output.backend] = output }
        let health: [[String: Any]] = OutputBackend.allCases.map { backend in
            guard let output = latest[backend] else {
                return ["backend": backend.rawValue, "state": "unknown"]
            }
            return ["backend": backend.rawValue, "state": output.state.rawValue,
                    "active_count": bounded(output.activeCount, 256),
                    "affected_slots": Array(Set(output.affectedSlots.prefix(4).filter { (0..<4).contains($0) })).sorted()]
        }
        let modelCounts = Dictionary(uniqueKeysWithValues: Switch2.Model.allCases.map { model in
            (String(format: "%04x", model.rawValue), models.prefix(8).filter { $0 == model }.count)
        })
        var result: [String: Any] = [
            "schema": 1, "source_revision": source, "source_dirty": dirty.map { $0 as Any } ?? "unknown",
            "macos": [bounded(os.majorVersion), bounded(os.minorVersion), bounded(os.patchVersion)],
            "architecture": ["arm64", "x86_64"].contains(architecture) ? architecture : "unknown",
            "engine_state": states.contains(engineState) ? engineState : "unknown",
            "logical_controller_model_counts": modelCounts, "outputs": health,
            "diagnostic_category_counts": counts, "counted_events": min(events.count, maximumEvents),
            "scope": "Snapshot only; no game receipt, hardware acceptance or battery measurement is implied.",
            "excluded": ["log messages", "names", "serials", "Bluetooth addresses", "extension IDs",
                         "application IDs", "filesystem paths", "raw input", "NFC contents", "audio", "preferences"]
        ]
        if let age = snapshotAge, age.isFinite, age >= 0 {
            result["output_snapshot_age_seconds"] = Int(min(86_400, age))
        } else { result["output_snapshot_age_seconds"] = "unknown" }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= maximumBytes else { throw Failure.oversized }
        return data
    }

    /// The real writer's three fallible stages are replaceable so regressions
    /// can prove preservation after partial writes, fsync and rename errors.
    struct SaveIO: Sendable {
        var writeAll: @Sendable (Int32, Data) throws -> Void
        var synchronize: @Sendable (Int32) throws -> Void
        var replace: @Sendable (Int32, String, String) throws -> Void
        static let system = SaveIO(writeAll: { fd, data in
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw Failure.writeFailed }
                    offset += count
                }
            }
        }, synchronize: { fd in
            while fsync(fd) != 0 {
                guard errno == EINTR else { throw Failure.writeFailed }
            }
        }, replace: { directory, temporary, destination in
            guard renameat(directory, temporary, directory, destination) == 0 else { throw Failure.writeFailed }
        })
    }

    /// Saves exactly the previewed bytes; no parent creation or network I/O.
    /// Pin the parent directory once: staging, inspection, cleanup and promotion
    /// stay on the same directory even if its pathname changes during the save.
    static func save(_ preview: Data, to destination: URL, using io: SaveIO = .system) throws {
        guard preview.count <= maximumBytes else { throw Failure.oversized }
        guard destination.isFileURL, !destination.path.utf8.contains(0),
              destination.host == nil || destination.host == "" || destination.host == "localhost"
        else { throw Failure.invalidDestination }
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw Failure.invalidDestination }
        let directory = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.writeFailed }
        defer { close(directory) }
        func validateDestination() throws {
            var info = stat()
            if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.invalidDestination }
            } else if errno != ENOENT { throw Failure.invalidDestination }
        }
        try validateDestination()
        let temporary = ".switch2mac-support-" + UUID().uuidString + ".tmp"
        var fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.writeFailed }
        defer {
            if fd >= 0 { close(fd) }
            _ = unlinkat(directory, temporary, 0)
        }
        try io.writeAll(fd, preview)
        try io.synchronize(fd)
        let closed = close(fd); fd = -1
        guard closed == 0 else { throw Failure.writeFailed }
        try validateDestination()
        try io.replace(directory, temporary, name)
    }
}
