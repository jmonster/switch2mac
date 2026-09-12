import Foundation
import Synchronization
import Switch2Kit

// Inbox is mutex-protected; file handles and counters are confined to writerQueue.
// Initialization runs on a utility queue BEFORE publication to the Bluetooth executor.
final class ExperimentalCaptureWriter: @unchecked Sendable {
    private struct Inbox: Sendable {
        var packets: [(TimeInterval, Data)] = []
        var dropped = 0
        var scheduled = false
        var finishing = false
    }
    private let inbox = Mutex(Inbox())
    private let writerQueue = DispatchQueue(label: "Switch2KitExperimental.capture", qos: .utility)
    private let fullFile: FileHandle
    private let regionFile: FileHandle
    private let fullURL: URL
    private let regionURL: URL
    private let start = ProcessInfo.processInfo.systemUptime
    private let completion: @Sendable (Switch2ExperimentalCapture) -> Void
    private var packetCount = 0
    private var closed = false

    init(directory: URL, completion: @escaping @Sendable (Switch2ExperimentalCapture) -> Void) throws {
        let run = UUID().uuidString
        fullURL = directory.appendingPathComponent("Switch2Kit-audio-\(run).bin")
        regionURL = directory.appendingPathComponent("Switch2Kit-audio-\(run)-frames.bin")
        self.completion = completion
        // Never replace existing user files, even if a path unexpectedly already exists.
        try Data("FTCWAUD2".utf8).write(to: fullURL, options: .withoutOverwriting)
        do {
            try Data("FTCWAUD2".utf8).write(to: regionURL, options: .withoutOverwriting)
            fullFile = try FileHandle(forWritingTo: fullURL)
            regionFile = try FileHandle(forWritingTo: regionURL)
            try fullFile.seekToEnd(); try regionFile.seekToEnd()
        } catch {
            try? FileManager.default.removeItem(at: fullURL)
            throw error
        }
    }
    func submit(_ bytes: Data) {
        let schedule = inbox.withLock { value in
            guard !value.finishing else { return false }
            guard bytes.count <= 4096, value.packets.count < 128 else { value.dropped += 1; return false }
            value.packets.append((ProcessInfo.processInfo.systemUptime - start, Data(bytes)))
            guard !value.scheduled else { return false }
            value.scheduled = true; return true
        }
        if schedule { writerQueue.async { [self] in drain() } }
    }
    private func writeBatch() {
        let packets = inbox.withLock { value in
            let result = Array(value.packets.prefix(32)); value.packets.removeFirst(result.count); return result
        }
        guard !closed else { return }
        for (elapsed, data) in packets {
            do {
                try record(data, elapsed: elapsed, to: fullFile)
                if data.count >= 65 {
                    let state = data[data.startIndex + 13], length = Int(data[data.startIndex + 14])
                    if state & 0x08 != 0, length > 0, 15 + length <= data.count {
                        try record(Data(data.dropFirst(15).prefix(length)), elapsed: elapsed, to: regionFile)
                    }
                }
                packetCount += 1
            } catch { inbox.withLock { $0.dropped += 1 } }
        }
    }
    private func record(_ data: Data, elapsed: TimeInterval, to file: FileHandle) throws {
        var record = Data()
        withUnsafeBytes(of: elapsed.bitPattern.littleEndian) { record.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(data.count).littleEndian) { record.append(contentsOf: $0) }
        record.append(data)
        try file.write(contentsOf: record)
    }
    private func drain() {
        writeBatch()
        let again = inbox.withLock { value in
            if value.finishing || value.packets.isEmpty { value.scheduled = false; return false }
            return true
        }
        if again { writerQueue.async { [self] in drain() } }
    }
    func finish() {
        let close = inbox.withLock { value in
            guard !value.finishing else { return false }; value.finishing = true; return true
        }
        guard close else { return }
        writerQueue.async { [self] in
            // At most 128 accepted packets remain; new submissions have been disabled.
            for _ in 0..<4 { writeBatch() }
            guard !closed else { return }
            closed = true
            try? fullFile.synchronize(); try? regionFile.synchronize()
            try? fullFile.close(); try? regionFile.close()
            completion(.init(packetsURL: fullURL, framesURL: regionURL, packetCount: packetCount,
                             droppedPacketCount: inbox.withLock { $0.dropped }))
        }
    }
}

extension ExperimentalOperations {
    func captureAudio(directory: URL, seconds: TimeInterval) {
        guard !session.ended else { return }
        guard session.beginAudioExperiment("capture") else { events.submit(.failure(id, .busy)); return }
        let events = events, id = id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result {
                try ExperimentalCaptureWriter(directory: directory) { result in
                    events.submit(.audioCaptureFinished(id, result))
                }
            }
            self.btQueue.async { [weak self] in
                guard let self, !self.session.ended else {
                    if case .success(let writer) = result { writer.finish() }
                    return
                }
                switch result {
                case .failure:
                    self.session.endAudioExperiment(); events.submit(.failure(id, .captureFileUnavailable))
                case .success(let writer):
                    self.capture = writer
                    self.session.setAudioCapture(true) { [weak self] available in
                        guard let self, available else {
                            writer.finish()
                            self?.session.endAudioExperiment()
                            events.submit(.failure(id, .unsupported)); return
                        }
                        self.session.onAudioPacket = { [writer] packet in writer.submit(packet) }
                        let config = Data([0x80, 0xBB, 0, 0, 0x02, 0xF0, 0])
                        self.session.experimentalCommand(0x17, 0x02, payload: config) { _ in }
                        let deadline = DispatchWorkItem { [weak self] in
                            guard let self else { return }
                            self.session.onAudioPacket = nil
                            self.session.setAudioCapture(false) { _ in }
                            self.session.endAudioExperiment()
                            self.capture?.finish(); self.capture = nil; self.captureDeadline = nil
                        }
                        self.captureDeadline = deadline
                        self.btQueue.asyncAfter(deadline: .now() + seconds, execute: deadline)
                    }
                }
            }
        }
    }
}
