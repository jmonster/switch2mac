import Foundation
import Synchronization

@main
enum LogPipelineTests {
    static func main() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ftcw-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let received = Mutex<[LogEntry]>([])
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let deliveries = Mutex(0)
        let pipeline = LogPipeline(directory: root, maxFileBytes: 320, maxPending: 8, batchSize: 4) { entries in
            received.withLock { $0.append(contentsOf: entries) }
            let shouldBlock = deliveries.withLock { count -> Bool in
                defer { count += 1 }
                return count == 0
            }
            if shouldBlock { entered.signal(); release.wait() }
        }

        pipeline.submit(.info, "test", "first")
        precondition(entered.wait(timeout: .now() + 2) == .success)
        for n in 0..<100 { pipeline.submit(.debug, "burst", "item \(n)") }
        release.signal()
        pipeline.flush()
        let entries = received.withLock { $0 }
        precondition(entries.contains { $0.subsystem == "logging" && $0.message.contains("dropped") })
        precondition(entries.count <= 10, "bounded queue admitted too many messages")

        for n in 0..<8 {
            pipeline.submit(.info, "rotate", String(repeating: "x", count: 100) + "-\(n)")
            pipeline.flush()
        }
        precondition(FileManager.default.fileExists(atPath: pipeline.fileURL.path))
        precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("bridge.log.old").path))
        let current = (try? Data(contentsOf: pipeline.fileURL)) ?? Data()
        precondition(!current.isEmpty && current.count <= 320)
        let old = try! Data(contentsOf: root.appendingPathComponent("bridge.log.old"))
        precondition(old.count <= 320)

        // UI admission is bounded even when MainActor does not drain its tasks.
        DispatchQueue.global().sync {
            let entry = LogEntry(id: 1, date: Date(), level: .info, subsystem: "test", message: "test")
            for _ in 0..<100 { LogStore.enqueue(Array(repeating: entry, count: 256)) }
            precondition(LogStore.pendingPresentationCount <= 5_000)
        }
        // Flush must drain every batch present at entry, not only the first one.
        let all = Mutex<[LogEntry]>([])
        let bulk = LogPipeline(directory: root.appendingPathComponent("bulk"), maxPending: 1000, batchSize: 4) { batch in
            all.withLock { $0.append(contentsOf: batch) }
        }
        for index in 0..<300 { bulk.submit(.info, "flush", "item \(index)") }
        bulk.flush()
        precondition(all.withLock { $0.count } == 300)
        print("PASS bounded asynchronous logging and runtime rotation")
    }
}
