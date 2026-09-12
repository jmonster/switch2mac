// Unsupported research companion. The stable target has no NFC/audio implementation.
import Foundation
import CoreBluetooth
import Switch2Kit

// Same serial executor as its base session. No unchecked mutable state crosses that queue.
package final class ExperimentalControllerSession: ControllerSessionCompanion, @unchecked Sendable {
    var operations: ExperimentalOperations?
    let base: ControllerSession
    init(base: ControllerSession) { self.base = base }
    var queue: DispatchQueue { base.queue }
    var peripheral: CBPeripheral { base.peripheral }
    var chars: [UUID: CBCharacteristic] { base.chars }
    var ended: Bool { base.isRetired }
    var isReady: Bool { base.isReady }
    var model: Switch2.Model { base.model }
    var serialNumber: String { base.serialNumber }
    var displayName: String { base.displayName }
    var isCommandIdle: Bool { base.isCommandIdle }
    var lastWriteAt: TimeInterval {
        get { base.lastWriteAt }
        set { base.lastWriteAt = newValue }
    }
    typealias CommandResult = ControllerSession.CommandResult
    func log(_ level: Switch2LogLevel, _ text: String) { base.diagnostics.emit(level, .experimental, text) }
    func pumpWrites() { base.pumpWrites() }
    func sendCommand(_ command: UInt8, _ subcommand: UInt8, _ data: Data, flag: UInt8 = 0x01,
                     completion: @escaping (CommandResult) -> Void) {
        base.sendCommand(command, subcommand, data, flag: flag, completion: completion)
    }
    func setRumble(strong: Double, weak: Double) { base.setRumble(strong: strong, weak: weak) }
    func applyRumblePulse(strong: Double, weak: Double, duration: Double) {
        base.applyRumblePulse(strong: strong, weak: weak, duration: duration)
    }
    @discardableResult func writeMotor(_ vibration: Switch2.Vibration) -> Bool { base.writeMotor(vibration) }
    private var lastRumbleTestAt: TimeInterval = -.infinity
    package var isExperimentActive: Bool { audioExperimentName != nil }
    package func didRetire() {
        finishAudioStream(); onAudioPacket = nil; audioExperimentName = nil
        operations?.cancel(); operations = nil
    }
    package func writeCapacityAvailable() { drainAudioStream() }
    package func receivedAuxiliaryValue(uuid: UUID?, data: Data) {
        if uuid == Self.audioInputUUID { onAudioPacket?(data) }
        else if promiscuousNotify { log(.debug, "Received experimental characteristic data (contents omitted)") }
    }
    // MARK: - Experiments (NFC probing, audio capture)

    /// Typed command access for protocol research. Rejections retain their
    /// header and payload. Timeout retires this ambiguous command stream.
    /// Like the session itself, this API is Bluetooth-queue confined.
    func experimentalCommandResult(_ command: UInt8, _ subcommand: UInt8,
                                   payload: Data, flag: UInt8 = 0x01,
                                   completion: @escaping (CommandResult) -> Void) {
        sendCommand(command, subcommand, payload, flag: flag, completion: completion)
    }

    /// Compatibility for existing NFC/audio probes: preserve status payloads
    /// they intentionally inspect (e.g. "not ready"), but never use this raw
    /// adapter for normal handshake success decisions. nil means no reply.
    func experimentalCommand(_ command: UInt8, _ subcommand: UInt8,
                             payload: Data, flag: UInt8 = 0x01,
                             completion: @escaping (Data?) -> Void) {
        experimentalCommandResult(command, subcommand, payload: payload, flag: flag) { result in
            switch result {
            case .success(let response), .failure(.rejected(let response)): completion(response.payload)
            case .failure: completion(nil)
            }
        }
    }

    /// NFC experiments: subscribe every notify-capable characteristic we are
    /// not already listening to and log whatever arrives — hunting for
    /// out-of-band bulk-data channels (the NFC tag payload may not travel on
    /// the main command-response characteristic).
    private(set) var promiscuousNotify = false
    func setPromiscuousNotify(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, !self.ended else { return }
            self.promiscuousNotify = enabled
            let known: Set<UUID> = [Switch2.GATT.inputReport,
                                    Switch2.GATT.commandResponse,
                                    Self.audioInputUUID]
            for (uuid, ch) in self.chars
            where ch.properties.contains(.notify) && !known.contains(uuid) {
                self.log(.debug, "experimental notification state changed")
                self.peripheral.setNotifyValue(enabled, for: ch)
            }
        }
    }

    /// Firmware 2.0+ Pro Controller audio input characteristic.
    static let audioInputUUID = UUID(uuidString: "7492866C-EC3E-4619-8258-32755FFCC0F9")!
    /// Firmware 2.0+ audio OUTPUT (host → controller headphone jack).
    static let audioOutputUUID = UUID(uuidString: "CC483F51-9258-427D-A939-630C31F72B06")!

    /// Write one raw frame to the audio output characteristic (Bluetooth
    /// queue only). Returns false when the characteristic is absent.
    @discardableResult
    func writeAudioFrame(_ data: Data) -> Bool {
        guard !ended, peripheral.canSendWriteWithoutResponse,
              data.count <= audioWriteChunkLimit,
              let ch = chars[Self.audioOutputUUID] else { return false }
        peripheral.writeValue(data, for: ch, type: .withoutResponse)
        lastWriteAt = ProcessInfo.processInfo.systemUptime
        return true
    }

    // MARK: Audio streaming (paced, backpressured)

    /// The largest single write-without-response the current link accepts
    /// (ATT MTU − 3). Audio frames larger than this must be split.
    var audioWriteChunkLimit: Int {
        peripheral.maximumWriteValueLength(for: .withoutResponse)
    }

    /// Whether the firmware exposes the audio output characteristic
    /// (2.0+ Pro Controller only). Bluetooth queue only.
    var hasAudioOutput: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return chars[Self.audioOutputUUID] != nil
    }

    /// Delivery accounting for one audio streaming run. `chunksDropped`
    /// counts writes shed because CoreBluetooth's outbound buffer stayed
    /// full for longer than the queue cap — the silent failure mode the
    /// old fire-and-forget path could never see.
    struct AudioStreamStats {
        var framesGenerated = 0
        var chunksWritten = 0
        var chunksDropped = 0
        var stalls = 0            // times the drain hit a full buffer
        var maxQueueDepth = 0
        var chunkLimit = 0
    }

    var audioStreamTimer: DispatchSourceTimer?
    var audioStreamQueue: [Data] = []      // pending chunks, FIFO
    var audioStreamStats = AudioStreamStats()
    var audioStreamNext: (() -> Data?)?
    var audioStreamDone: ((AudioStreamStats) -> Void)?
    /// Cap on queued chunks: for live audio, late data is worse than lost
    /// data, so beyond ~4 frames of backlog we shed the oldest.
    var audioStreamQueueCap = 8

    /// Guard so concurrent experiments cannot interleave on one controller.
    /// Both calls must run on the Bluetooth queue (as all experiment
    /// bodies already do) — they are simple flag operations, not locks.
    private(set) var audioExperimentName: String?
    func beginAudioExperiment(_ name: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !ended, audioExperimentName == nil else { return false }
        audioExperimentName = name
        return true
    }
    func endAudioExperiment() {
        queue.async { [weak self] in self?.audioExperimentName = nil }
    }

    /// Stream audio frames at a fixed cadence with real backpressure.
    ///
    /// Algorithm (producer–consumer with loss-preferring bounded queue):
    /// a strict timer enqueues one frame per `frameInterval` (split into
    /// ≤ chunk-limit writes); a drain loop issues writes only while
    /// CoreBluetooth reports `canSendWriteWithoutResponse`, resuming from
    /// the `peripheralIsReady` callback. `next` runs on the Bluetooth
    /// queue; returning nil ends the stream, after which `done` receives
    /// the delivery stats.
    ///
    /// Precondition: at most one stream per session (enforced by restart:
    /// starting a new stream cancels the previous one without stats).
    func startAudioStream(frameInterval: TimeInterval,
                      next: @escaping () -> Data?,
                      done: @escaping (AudioStreamStats) -> Void) {
        guard !ended else { return }
        audioStreamTimer?.cancel()
        audioStreamQueue.removeAll()
        audioStreamStats = AudioStreamStats(chunkLimit: audioWriteChunkLimit)
        audioStreamNext = next
        audioStreamDone = done
        // Queue cap = 4 frames' worth of chunks (min 1 chunk per frame).
        audioStreamQueueCap = 8
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: frameInterval,
                       leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.audioStreamTick() }
        timer.resume()
        audioStreamTimer = timer
    }

    /// Stop an in-flight stream early (Bluetooth queue or any thread);
    /// `done` still fires with the stats gathered so far.
    func stopAudioStream() {
        queue.async { [weak self] in self?.finishAudioStream() }
    }

    func audioStreamTick() {
        guard let next = audioStreamNext else { return }
        guard let frame = next() else { finishAudioStream(); return }
        audioStreamStats.framesGenerated += 1
        let limit = max(20, audioWriteChunkLimit)
        var offset = 0
        while offset < frame.count {
            let end = min(offset + limit, frame.count)
            audioStreamQueue.append(frame.subdata(in: offset..<end))
            offset = end
        }
        audioStreamStats.maxQueueDepth = max(audioStreamStats.maxQueueDepth,
                                             audioStreamQueue.count)
        while audioStreamQueue.count > audioStreamQueueCap {
            audioStreamQueue.removeFirst()
            audioStreamStats.chunksDropped += 1
        }
        drainAudioStream()
    }

    /// Write queued chunks until the stack refuses; `peripheralIsReady`
    /// re-enters. Runs on the Bluetooth queue only.
    func drainAudioStream() {
        pumpWrites()
        guard !ended, audioStreamNext != nil, let ch = chars[Self.audioOutputUUID] else { return }
        var budget = 8
        while !audioStreamQueue.isEmpty && budget > 0 {
            budget -= 1
            guard peripheral.canSendWriteWithoutResponse else {
                audioStreamStats.stalls += 1
                return
            }
            peripheral.writeValue(audioStreamQueue.removeFirst(),
                                  for: ch, type: .withoutResponse)
            audioStreamStats.chunksWritten += 1
            lastWriteAt = ProcessInfo.processInfo.systemUptime
        }
    }

    func finishAudioStream() {
        audioStreamTimer?.cancel()
        audioStreamTimer = nil
        audioStreamQueue.removeAll()
        audioStreamNext = nil
        let done = audioStreamDone
        audioStreamDone = nil
        done?(audioStreamStats)
    }

    /// One HD-rumble write on demand (haptic tones/melodies drive this at
    /// their own cadence; the packet sequence nibble increments per write —
    /// the controller de-duplicates packets with a stale sequence).
    func writeHapticSample(_ vib: Switch2.Vibration) {
        queue.async { [weak self] in self?.writeMotor(vib) }
    }

    /// Called per audio notification when capture is active.
    var onAudioPacket: ((Data) -> Void)?

    /// Subscribe (or unsubscribe) the audio input characteristic.
    /// Returns false via completion when the firmware doesn't expose it.
    func setAudioCapture(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        guard !ended, let ch = chars[Self.audioInputUUID] else { completion(false); return }
        peripheral.setNotifyValue(enabled, for: ch)
        completion(true)
    }


    func testRumble(intensity: Double) {
        queue.async { [weak self] in
            guard let self, !self.ended, self.isReady else { return }
            let level = intensity.isFinite ? max(0, min(1, intensity)) : 0
            guard level > 0 else {
                self.log(.info, "rumble test muted: raise Rumble above 0%")
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastRumbleTestAt >= 0.5 else { return }
            if self.model.hasHDRumble {
                self.lastRumbleTestAt = now
                // Pro has independent left/strong and right/weak actuators.
                // A test must exercise BOTH, unlike a single-motor effect.
                self.applyRumblePulse(strong: level, weak: self.model == .proController2 ? level : 0,
                                      duration: 0.4)
                self.log(.info, "direct rumble test requested: verify vibration by touch")
            } else if self.model == .nsoGameCube,
                      let preset = Switch2.GameCubeRumblePreset.forTest(intensity: level) {
                // A preset cannot be cancelled after submission. Never let a
                // test accumulate behind commands or radio backpressure and
                // buzz unexpectedly later. Retry is an explicit user action.
                guard self.isCommandIdle,
                      self.peripheral.canSendWriteWithoutResponse else {
                    self.log(.warning, "rumble test not sent: Bluetooth is busy; press Test again")
                    return
                }
                self.lastRumbleTestAt = now
                self.sendCommand(Switch2.Command.vibration, Switch2.Subcommand.vibrationPlayPreset,
                                 preset.payload) { [weak self] result in
                    switch result {
                    case .success:
                        self?.log(.info, "GameCube rumble preset acknowledged: verify vibration by touch")
                    case .failure:
                        self?.log(.warning, "GameCube rumble preset was not acknowledged")
                    }
                }
            }
        }
    }
}
