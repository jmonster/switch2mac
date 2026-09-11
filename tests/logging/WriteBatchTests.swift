// Appended to a temporary production source copy by run.sh. The injected
// write counter does not ship in the application.
import Foundation
import Synchronization

enum TestWrites {
    private static let sizes = Mutex<[Int]>([])
    static func record(_ bytes: Int) { sizes.withLock { $0.append(bytes) } }
    static func reset() { sizes.withLock { $0.removeAll() } }
    static var snapshot: [Int] { sizes.withLock { $0 } }
}

extension LogPipeline {
    static func verifyBatchedWrites() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ftcw-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 0)
        func entries(_ count: Int, message: String = "line\nbreak\rtest") -> [LogEntry] {
            (0..<count).map { LogEntry(id: UInt64($0), date: date, level: .info,
                                      subsystem: "batch", message: "\($0):\(message)") }
        }
        let small = LogPipeline(directory: root.appendingPathComponent("small"), deliver: { _ in })
        let smallEntries = entries(100)
        TestWrites.reset()
        small.writerQueue.sync {
            small.write(smallEntries)
            let text = try! String(contentsOf: small.fileURL, encoding: .utf8)
            let expected = smallEntries.map {
                "\(small.formatter.string(from: $0.date)) INFO [batch] "
                    + $0.message.replacingOccurrences(of: "\n", with: "\\n")
                        .replacingOccurrences(of: "\r", with: "\\r") + "\n"
            }.joined()
            precondition(text == expected, "Batch changed line order, escaping, or formatting")
            precondition(TestWrites.snapshot.count == 1, "100 small entries should need one disk write")
            small.write([])
            precondition(TestWrites.snapshot.count == 1, "Empty batch wrote to disk")
        }
        let large = LogPipeline(directory: root.appendingPathComponent("large"), deliver: { _ in })
        let largeEntries = entries(2_000, message: String(repeating: "x", count: 100))
        TestWrites.reset()
        large.writerQueue.sync {
            large.write(largeEntries)
            let writes = TestWrites.snapshot
            let data = try! Data(contentsOf: large.fileURL)
            precondition(writes.count > 1 && writes.count < 10, "Large batch was not bounded and batched")
            precondition(writes.allSatisfy { $0 <= 64 * 1024 })
            precondition(writes.reduce(0, +) == data.count)
            let text = String(data: data, encoding: .utf8)!
            precondition(text.split(separator: "\n").count == largeEntries.count)
        }
        let rotated = LogPipeline(directory: root.appendingPathComponent("rotation"), maxFileBytes: 130,
                                  deliver: { _ in })
        rotated.writerQueue.sync {
            // Each long line must fit in its own bounded file; truncation must
            // not leave a split multibyte scalar at the rotation boundary.
            rotated.write(entries(3, message: String(repeating: "é😀", count: 100)))
            for url in [rotated.oldFileURL, rotated.fileURL] {
                let data = try! Data(contentsOf: url)
                precondition(!data.isEmpty && data.count <= 130 && data.last == 10)
                precondition(String(data: data, encoding: .utf8) != nil)
            }
            let old = try! String(contentsOf: rotated.oldFileURL, encoding: .utf8)
            let current = try! String(contentsOf: rotated.fileURL, encoding: .utf8)
            precondition(old.contains("[batch] 1:") && current.contains("[batch] 2:"))
        }
        print("PASS batched disk writes, 64 KiB chunks, byte fidelity, and UTF-8 rotation")
    }
}

@main enum WriteBatchTests {
    static func main() { LogPipeline.verifyBatchedWrites() }
}
