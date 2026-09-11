import Foundation

@main enum Tests {
    static func main() throws {
        let secret = "serial-JOHN AA:BB:CC:DD:EE:FF /Users/private NFC-payload 🕵"
        let events = Array(repeating: SupportSummary.Event(level: secret, subsystem: secret), count: 6000)
        let data = try SupportSummary.make(revision: secret, dirty: nil,
            os: OperatingSystemVersion(majorVersion: -1, minorVersion: 99_999, patchVersion: 1),
            architecture: secret, engineState: secret, models: Array(repeating: .nsoGameCube, count: 100),
            outputs: [OutputHealth(backend: .sdl, state: .clientConnected, activeCount: Int.max,
                                   affectedSlots: [-1, 2, 2, 999])], snapshotAge: .nan, events: events)
        let text = String(decoding: data, as: UTF8.self)
        precondition(!text.contains(secret) && !text.contains("AA:BB") && !text.contains("/Users"))
        precondition(data.count < SupportSummary.maximumBytes)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(object["source_revision"] as? String == "unknown")
        precondition(object["counted_events"] as? Int == 5000)
        precondition((object["diagnostic_category_counts"] as? [String: Int]) == ["other.other": 5000])
        let minimal = try SupportSummary.make(revision: String(repeating: "a", count: 40), dirty: false,
            os: OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 9),
            architecture: "arm64", engineState: "scanning", models: [], outputs: [], snapshotAge: nil, events: [])
        precondition(String(decoding: minimal, as: UTF8.self).contains(String(repeating: "a", count: 40)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("summary.json")
        try SupportSummary.save(data, to: url)
        let saved = try Data(contentsOf: url)
        precondition(saved == data, "export must equal the preview byte-for-byte")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        try SupportSummary.save(minimal, to: url)
        precondition(tryRead(url) == minimal)
        do { try SupportSummary.save(Data(count: 65_537), to: url); fatalError("accepted oversized output") }
        catch SupportSummary.Failure.oversized {}
        precondition(tryRead(url) == minimal, "failed export changed existing file")
        let alias = root.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        do { try SupportSummary.save(data, to: alias); fatalError("accepted symbolic link") }
        catch SupportSummary.Failure.invalidDestination {}
        do { try SupportSummary.save(data, to: root); fatalError("accepted directory") }
        catch SupportSummary.Failure.invalidDestination {}
        do { try SupportSummary.save(data, to: root.appendingPathComponent("missing/file")); fatalError("created parent") }
        catch {}
        precondition(tryRead(url) == minimal)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(!files.contains { $0.hasPrefix(".switch2mac-support-") })
        print("PASS allowlisted bounded summary, identifier exclusion, preview fidelity, private atomic replacement and failure preservation")
    }
    static func tryRead(_ url: URL) -> Data { try! Data(contentsOf: url) }
}
