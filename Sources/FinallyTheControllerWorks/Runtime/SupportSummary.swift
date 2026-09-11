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

    /// Saves exactly the previewed bytes. Same-directory staging and rename
    /// preserve an existing file on failure; a completed export is mode 0600.
    /// Nothing is uploaded, and no parent directories are created.
    static func save(_ preview: Data, to destination: URL) throws {
        guard preview.count <= maximumBytes else { throw Failure.oversized }
        guard destination.isFileURL else { throw Failure.invalidDestination }
        let fm = FileManager.default
        if let type = try? fm.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType,
           type != .typeRegular { throw Failure.invalidDestination }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".switch2mac-support-" + UUID().uuidString + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.writeFailed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? fm.removeItem(at: temporary) }
        try handle.write(contentsOf: preview)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, destination.path) == 0 else { throw Failure.writeFailed }
    }
}
