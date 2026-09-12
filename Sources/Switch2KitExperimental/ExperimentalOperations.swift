import Foundation
import CoreFoundation
import Switch2Kit

// Queue-confined orchestration extracted from the dashboard. Neither UI policy nor
// NotificationCenter names nor default directories are part of these research operations.
final class ExperimentalOperations: @unchecked Sendable {
    let session: ExperimentalControllerSession
    let id: Switch2ControllerID
    let events: ExperimentalEventPipe
    var melodyTimer: DispatchSourceTimer?
    var captureDeadline: DispatchWorkItem?
    var capture: ExperimentalCaptureWriter?
    var btQueue: DispatchQueue { session.queue }
    init(session: ExperimentalControllerSession, events: ExperimentalEventPipe) {
        self.session = session; self.id = .init(rawValue: session.base.peripheral.identifier); self.events = events
    }
    var researchLog: @Sendable (Switch2LogLevel, String, String) -> Void {
        let diagnostics = session.base.diagnostics
        return { level, category, _ in
            diagnostics.emit(level, .experimental, category == "nfc"
                ? "NFC research operation progressed (tag contents and identifiers omitted)"
                : "Audio/haptic research operation progressed (payloads omitted)")
        }
    }
    func cancel() {
        melodyTimer?.cancel(); melodyTimer = nil
        captureDeadline?.cancel(); captureDeadline = nil
        capture?.finish(); capture = nil
    }
    func nfcProbe() {
        let bridgeLog = researchLog

        btQueue.async { [weak self] in
            guard let self, !self.session.ended else { return }
            let session = self.session
            guard session.beginAudioExperiment("nfc") else { events.submit(.failure(id, .busy)); return }
            bridgeLog(.info, "nfc",
                      "starting NFC discovery — place the tag on the touchpoint "
                      + "BEFORE clicking, or hold it on during the 30 s window")
            // Hunt for out-of-band data channels while the probe runs.
            session.setPromiscuousNotify(true)
            let startPayload = Data([0x00, 0xE8, 0x03, 0x2C, 0x01])
            session.experimentalCommand(0x01, 0x03, payload: startPayload) { resp in
                bridgeLog(.info, "nfc",
                          "discovery start response: \(resp.map(Self.hex) ?? "TIMEOUT")")
                self.nfcPollStatus(session: session, attempt: 0)
            }
        }
    }

    private func nfcPollStatus(session: ExperimentalControllerSession, attempt: Int) {
        guard !session.ended else { return }
        let bridgeLog = researchLog

        guard attempt < 60 else {
            bridgeLog(.warning, "nfc", "no tag detected after 30 s — probe over")
            self.nfcStopDiscovery(session: session)
            return
        }
        // Empirical: detection only ever succeeded when the tag was already
        // on the antenna at discovery start — the start command appears to
        // fire a short poll burst, and state 07 41 means "burst over, idle".
        // Re-kick discovery every ~3 s so a tag placed late is still caught.
        if attempt > 0, attempt % 6 == 0 {
            session.experimentalCommand(0x01, 0x03,
                                        payload: Data([0x00, 0xE8, 0x03, 0x2C, 0x01])) { resp in
                bridgeLog(.debug, "nfc",
                          "discovery re-kick: \(resp.map(Self.hex) ?? "TIMEOUT")")
            }
        }
        btQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            session.experimentalCommand(0x01, 0x05, payload: Data()) { resp in
                guard let resp else {
                    bridgeLog(.warning, "nfc", "status poll timed out; retrying")
                    self.nfcPollStatus(session: session, attempt: attempt + 1)
                    return
                }
                bridgeLog(.debug, "nfc", "status: \(Self.hex(resp))")
                // Observed layout: ... byte[8] = UID length, bytes 9.. = UID.
                if resp.count > 9, resp[resp.startIndex + 8] > 0,
                   resp.count >= 9 + Int(resp[resp.startIndex + 8]) {
                    let len = Int(resp[resp.startIndex + 8])
                    let uid = resp.subdata(in: resp.startIndex + 9 ..< resp.startIndex + 9 + len)
                    bridgeLog(.info, "nfc",
                              "🎉 TAG DETECTED — UID \(uid.map { String(format: "%02X", $0) }.joined(separator: ":"))")
                    bridgeLog(.info, "nfc", "full status: \(Self.hex(resp))")
                    // Tactile ack, like the console does on an amiibo scan.
                    session.setRumble(strong: 0.6, weak: 0)
                    self.btQueue.asyncAfter(deadline: .now() + 0.15) {
                        session.setRumble(strong: 0, weak: 0)
                    }
                    self.nfcReadTag(session: session, uid: uid)
                } else {
                    self.nfcPollStatus(session: session, attempt: attempt + 1)
                }
            }
        }
    }

    /// Observed console "read device" payload: d0 07 = 2000 (ms timeout?),
    /// then what appear to be NTAG page-range descriptors covering pages
    /// 0x00–0x3B, 0x3C–0x77, 0x78–0x86 — all 135 pages = 540 bytes.
    private static let nfcReadDevicePayload =
        Data([0xD0, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
              0x01, 0x03, 0x00, 0x3B, 0x3C, 0x77, 0x78, 0x86, 0x00, 0x00])

    /// After a tag is detected, read its data buffer. Sends "read device"
    /// (0x01/0x06) to start the controller's RF read of the whole tag, then
    /// loops "read buffer" (0x01/0x15) over increasing offsets, logging each
    /// chunk as hex + ASCII so text records (e.g. an NDEF "banans") are
    /// visible.
    ///
    /// Timing: 0x06 only ACKs — the controller then reads all 135 NTAG215
    /// pages over RF, which is not instantaneous. We deliberately send NO
    /// other NFC command for 1.2 s (a status poll mid-read may abort the RF
    /// transaction), then log one status + the console's 0x0C "result info"
    /// before pulling the buffer.
    /// One stage of the read-unlock hunt: send each command in `sequence` in
    /// order, wait `delay`, then try up to `readTries` chunk reads before
    /// moving on to the next stage.
    private struct NFCStage {
        let label: String
        let sequence: [(subcommand: UInt8, payload: Data)]
        let delay: Double
        let readTries: Int
    }

    private func nfcReadTag(session: ExperimentalControllerSession, uid: Data) {
        guard !session.ended else { return }
        let bridgeLog = researchLog

        // Top hypothesis: an NFC reader must STOP POLLING before it can
        // transact with the selected tag — 0x04 (previously assumed to be
        // plain "stop discovery") is likely that halt, and belongs BETWEEN
        // detection and read-device. Fall back to the UID-in-payload variant
        // and a fresh-restart control if the halt alone doesn't unlock it.
        // Suspected "authenticate as amiibo" flag at payload index 9 — try
        // the read with it cleared, in case the firmware aborts full-tag
        // reads of non-amiibo NTAGs (state 07 48) on failed validation.
        var noAuth = Self.nfcReadDevicePayload
        noAuth[noAuth.startIndex + 9] = 0x00
        let stages = [
            NFCStage(label: "read-device, byte9=00 (no amiibo auth?)",
                     sequence: [(0x06, noAuth)],
                     delay: 0.8, readTries: 4),
            NFCStage(label: "read-device standard, patient 10 s poll",
                     sequence: [(0x06, Self.nfcReadDevicePayload)],
                     delay: 1.0, readTries: 40),   // 40 × 0.25 s = 10 s
        ]
        // Read-only probe: map which feature-mask bits exist beyond the
        // documented byte 0 — candidate NFC-enable bits for the next round.
        session.experimentalCommand(0x0C, 0x01, payload: Data([0xFF, 0xFF, 0xFF, 0xFF])) { resp in
            bridgeLog(.info, "nfc", "feature info (mask FFFFFFFF): \(resp.map(Self.hex) ?? "TIMEOUT")")
        }
        nfcRunStage(session: session, uid: uid, stages: stages, index: 0)
    }

    private func nfcRunStage(session: ExperimentalControllerSession, uid: Data,
                             stages: [NFCStage], index: Int) {
        guard !session.ended else { return }
        let bridgeLog = researchLog

        guard index < stages.count else {
            bridgeLog(.warning, "nfc", "all read strategies exhausted — dumping final status")
            session.experimentalCommand(0x01, 0x05, payload: Data()) { [weak self] resp in
                guard let self else { return }
                bridgeLog(.info, "nfc", "final status: \(resp.map(Self.hex) ?? "TIMEOUT")")
                self.nfcFinish(session: session, assembled: Data(), uid: uid)
            }
            return
        }
        let stage = stages[index]
        bridgeLog(.info, "nfc", "stage \(index + 1)/\(stages.count): \(stage.label)")
        nfcSendSequence(session: session, stage.sequence, at: 0) { [weak self] in
            guard let self else { return }
            self.btQueue.asyncAfter(deadline: .now() + stage.delay) {
                self.nfcReadBuffer(session: session, assembled: Data(),
                                   chunks: 0, retries: 0,
                                   maxRetries: stage.readTries, uid: uid,
                                   onNoData: {
                    self.nfcRunStage(session: session, uid: uid,
                                     stages: stages, index: index + 1)
                })
            }
        }
    }

    /// Send a stage's commands strictly in order (each waits for the
    /// previous response), logging every reply, then call `done`.
    private func nfcSendSequence(session: ExperimentalControllerSession,
                                 _ sequence: [(subcommand: UInt8, payload: Data)],
                                 at index: Int, done: @escaping () -> Void) {
        guard !session.ended else { return }
        let bridgeLog = researchLog

        guard index < sequence.count else { done(); return }
        let (sub, payload) = sequence[index]
        session.experimentalCommand(0x01, sub, payload: payload) { [weak self] resp in
            bridgeLog(.info, "nfc",
                      "  0x\(String(format: "%02x", sub)) → \(resp.map(Self.hex) ?? "TIMEOUT")")
            self?.nfcSendSequence(session: session, sequence, at: index + 1, done: done)
        }
    }

    /// One step of the buffer dump.
    ///
    /// Wire format (reverse-engineered from the console's traffic + our own
    /// probes): 0x01/0x15 is a CURSOR-based stream read, not offset-based.
    /// Request payload = requested byte count as LE u16 (console always asks
    /// for 0x46 = 70). Response payload = [status][valid-count LE u16][data];
    /// status 0x00 = OK, non-zero (with response class 0x02) = not ready /
    /// nothing to read. Identical requests return SUCCESSIVE chunks.
    ///
    /// `chunks` bounds the loop (12 × 70 > 540); `retries` counts consecutive
    /// not-ready replies at the current cursor — the RF read may still be
    /// filling the buffer, so an error only ends the dump once we have data
    /// or patience runs out.
    private func nfcReadBuffer(session: ExperimentalControllerSession,
                               assembled: Data, chunks: Int, retries: Int,
                               maxRetries: Int = 6, uid: Data,
                               onNoData: (@Sendable () -> Void)? = nil) {
        guard !session.ended else { return }
        let bridgeLog = researchLog

        guard assembled.count < 540, chunks < 12 else {
            self.nfcFinish(session: session, assembled: assembled, uid: uid)
            return
        }
        let request = Data([0x46, 0x00])   // next 70 bytes, as the console asks
        session.experimentalCommand(0x01, 0x15, payload: request) { [weak self] resp in
            guard let self else { return }
            let status: UInt8? = resp.flatMap { $0.isEmpty ? nil : $0[$0.startIndex] }
            guard let resp, let status, status == 0, resp.count > 3 else {
                if retries < maxRetries {
                    bridgeLog(.debug, "nfc",
                              "chunk \(chunks) not ready (status \(status.map(String.init) ?? "none"), try \(retries + 1)/\(maxRetries))")
                    self.btQueue.asyncAfter(deadline: .now() + 0.25) {
                        self.nfcReadBuffer(session: session, assembled: assembled,
                                           chunks: chunks, retries: retries + 1,
                                           maxRetries: maxRetries, uid: uid,
                                           onNoData: onNoData)
                    }
                } else if assembled.isEmpty, let onNoData {
                    onNoData()
                } else {
                    bridgeLog(.info, "nfc",
                              "buffer stream ended at \(assembled.count) bytes (status \(status.map(String.init) ?? "none"))")
                    self.nfcFinish(session: session, assembled: assembled, uid: uid)
                }
                return
            }
            // [status][valid-count LE][data...] — trust valid-count, capped
            // by what actually arrived.
            let declared = Int(resp[resp.startIndex + 1]) | Int(resp[resp.startIndex + 2]) << 8
            let available = resp.count - 3
            let take = min(declared, available)
            guard take > 0 else {
                bridgeLog(.info, "nfc", "zero-length chunk — stream complete at \(assembled.count) bytes")
                self.nfcFinish(session: session, assembled: assembled, uid: uid)
                return
            }
            let chunk = resp.subdata(in: resp.startIndex + 3 ..< resp.startIndex + 3 + take)
            bridgeLog(.debug, "nfc", "chunk \(chunks) (\(take)B): \(Self.hex(chunk))")
            var acc = assembled
            acc.append(chunk)
            self.nfcReadBuffer(session: session, assembled: acc,
                               chunks: chunks + 1, retries: 0, uid: uid)
        }
    }

    /// Dump the assembled tag image, decode any NDEF text, notify the user,
    /// and end discovery so the NFC radio doesn't stay on.
    private func nfcFinish(session: ExperimentalControllerSession, assembled: Data, uid: Data) {
        guard !session.ended else { return }
        let bridgeLog = researchLog

        defer { nfcStopDiscovery(session: session) }
        guard !assembled.isEmpty else {
            bridgeLog(.warning, "nfc", "no tag data — keep the tag flat and still on the touchpoint and try again")
            return
        }
        bridgeLog(.info, "nfc",
                  "tag dump (\(assembled.count) bytes):\n\(Self.hexAscii(assembled))")
        if assembled.allSatisfy({ $0 == 0 }) {
            bridgeLog(.warning, "nfc",
                      "buffer was all zeros — the tag likely moved before the read finished; try again")
            return
        }
        let uidString = uid.map { String(format: "%02X", $0) }.joined(separator: ":")
        let text = Self.extractNDEFText(assembled)
        if let text {
            bridgeLog(.info, "nfc", "📖 decoded text record: \"\(text)\"")
        }
        events.submit(.nfcTagRead(id, Switch2ExperimentalTag(uid: uidString,
            text: text, byteCount: assembled.count)))
    }

    /// End discovery (0x01/0x04 per the sniffed console traffic — sent with
    /// an empty payload once the console is done with the tag).
    private func nfcStopDiscovery(session: ExperimentalControllerSession) {
        guard !session.ended else { return }
        let bridgeLog = researchLog

        session.endAudioExperiment()
        session.setPromiscuousNotify(false)
        session.experimentalCommand(0x01, 0x04, payload: Data()) { resp in
            bridgeLog(.debug, "nfc", "discovery stop response: \(resp.map(Self.hex) ?? "TIMEOUT")")
        }
    }

    /// Minimal NDEF Text-record extractor: finds a well-known Text record
    /// (type 'T', TNF 0x01) and returns its UTF-8 payload.
    ///
    /// Precondition: `data` is a raw Type 2 tag image. Its TLV area begins at
    /// byte 16 (after UID/lock/capability pages), so scanning starts there —
    /// UID bytes can contain a spurious 0x03 that would misparse.
    private static func extractNDEFText(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        var i = bytes.count > 16 ? 16 : 0
        while i + 3 < bytes.count {
            // NDEF TLV: 0x03 = NDEF message, then length.
            if bytes[i] == 0x03 {
                var j = i + 2                     // skip TLV type + length
                // Short-record header: flags, type-length, payload-length.
                while j + 3 < bytes.count {
                    let flags = bytes[j]
                    let typeLen = Int(bytes[j + 1])
                    let payLen = Int(bytes[j + 2])
                    let typeStart = j + 3
                    guard typeStart + typeLen + payLen <= bytes.count else { break }
                    let type = bytes[typeStart..<typeStart + typeLen]
                    if type.first == 0x54, payLen > 0 {       // 'T' text record
                        let payStart = typeStart + typeLen
                        let status = bytes[payStart]
                        let langLen = Int(status & 0x3F)
                        let textStart = payStart + 1 + langLen
                        let textEnd = payStart + payLen
                        if textStart <= textEnd, textEnd <= bytes.count {
                            return String(bytes: bytes[textStart..<textEnd], encoding: .utf8)
                        }
                    }
                    if flags & 0x40 != 0 { break }  // ME (last record)
                    j = typeStart + typeLen + payLen
                }
            }
            i += 1
        }
        return nil
    }

    private static func hexAscii(_ data: Data) -> String {
        var out = ""
        let bytes = [UInt8](data)
        for row in stride(from: 0, to: bytes.count, by: 16) {
            let slice = Array(bytes[row..<min(row + 16, bytes.count)])
            let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
                .padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = String(slice.map { (32...126).contains($0)
                ? Character(UnicodeScalar($0)) : "." })
            out += String(format: "  %04x: ", row) + hex + " |" + ascii + "|\n"
        }
        return out
    }

    // MARK: - Audio lab
    //
    // Ground truth so far (our captures + ndeadly/switch2_controller_research):
    //  * Audio and rumble are SEPARATE lanes: rumble on ...2b05, headset
    //    audio on ...2b06 (out) / 7492866c... (in). No documented
    //    audio-driven-haptics mode.
    //  * The 112-byte input notification is: [seq][0x20][buttons][sticks]
    //    [jack-state @13][audio-len @14][audio frame @15, 50 B]
    //    [zeros][telemetry-len @65][packed motion telemetry @66][zeros].
    //    Jack state: 0x00 nothing, 0x05 headphones, 0x07 headset(mic);
    //    bit 3 = "this report carries an audio frame" (alternates).
    //  * Idle audio frames are f8 ff fe + 47 zero bytes. The codec for
    //    live frames is publicly unknown (~10:1 vs the configured
    //    240-sample/5 ms PCM rate).
    //  * Capture starves regular input reports for its whole window.

    /// The audio-state byte's human reading (provisional decode).
    private static func jackStateName(_ b: UInt8) -> String {
        switch b & ~0x08 {
        case 0x00: return "nothing plugged"
        case 0x05: return "headphones (no mic)"
        case 0x07: return "headset (mic present)"
        default:   return "unknown"
        }
    }

    /// Audio capture v2: subscribe the headset-audio characteristic and
    /// record timestamped notifications, decoding the report layout live.
    /// Writes two files to ~/Documents (names carry a run timestamp):
    /// the full packets, and just the 50-byte audio-region frames for
    /// offline codec work. File format: "FTCWAUD2" magic, then records of
    /// [f64 LE seconds since start][u32 LE length][bytes].


    /// Build one PCM sine frame: `samples` × s16 LE mono, advancing the
    /// caller's phase for a true `freq` Hz tone at `sampleRate`.
    private static func sineFrame(samples: Int, freq: Double,
                                  sampleRate: Double, phase: inout Double) -> Data {
        var payload = Data(capacity: samples * 2)
        for _ in 0..<samples {
            let sample = Int16(sin(phase) * 20000)
            phase += 2 * .pi * freq / sampleRate
            withUnsafeBytes(of: sample.littleEndian) { payload.append(contentsOf: $0) }
        }
        if phase > 2 * .pi { phase -= (2 * .pi) * (phase / (2 * .pi)).rounded(.down) }
        return payload
    }

    /// Play a 440 Hz tone for 4 s at the FULL configured rate: 240 s16
    /// samples per 5 ms frame (48 kHz real time — 9.6× the data the old
    /// probe sent), with MTU splitting and true backpressure. If the
    /// format is right, this is the first honest test of where the audio
    /// goes: listen at the actuator AND with headphones plugged in.
    func audioPlayTone() {
        let bridgeLog = researchLog

        btQueue.async { [weak self] in
            guard let self, !self.session.ended else { return }
            let session = self.session
            guard session.hasAudioOutput else {
                bridgeLog(.warning, "audio",
                          "audio characteristic not found — controller firmware "
                          + "may be older than 2.0 (update it via a Switch 2 console)")
                return
            }
            guard session.beginAudioExperiment("tone") else {
                bridgeLog(.warning, "audio", "another audio experiment is running — wait for it to finish")
                return
            }
            bridgeLog(.info, "audio",
                      "real-time tone: 4 s of 440 Hz, 480 B/5 ms; link accepts "
                      + "\(session.audioWriteChunkLimit) B per write. A clean A4 tone "
                      + "= PCM format confirmed; a garble = wrong encoding; silence "
                      + "= wrong lane/config")
            let config = Data([0x80, 0xBB, 0x00, 0x00, 0x02, 0xF0, 0x00])
            session.experimentalCommand(0x17, 0x02, payload: config) { resp in
                bridgeLog(.info, "audio",
                          "config → \(resp.map(Self.hex) ?? "none"); streaming")
            }
            var phase = 0.0
            var frames = 0
            session.startAudioStream(frameInterval: 0.005) {
                guard frames < 800 else { return nil }
                frames += 1
                return Self.sineFrame(samples: 240, freq: 440,
                                      sampleRate: 48000, phase: &phase)
            } done: { stats in
                session.endAudioExperiment()
                bridgeLog(.info, "audio",
                          "tone done: \(stats.framesGenerated) frames, "
                          + "\(stats.chunksWritten) writes, \(stats.chunksDropped) dropped, "
                          + "\(stats.stalls) stalls, peak queue \(stats.maxQueueDepth) "
                          + "— what did you hear, and where (actuator vs headphones)?")
            }
        }
    }

    /// Audio OUTPUT format probe — four phases, ears as the detector.
    /// Run it twice: once with nothing plugged in (listen at the
    /// controller body) and once with headphones in (listen there).
    ///
    /// Phase 1  raw PCM at the full configured rate (480 B / 5 ms):
    ///          a clean 440 Hz tone anywhere = PCM confirmed.
    /// Phase 2  the legacy 50 B / 5 ms frames, but with the sine generated
    ///          for the effective 5 kHz rate (the old probe generated
    ///          48 kHz samples at this rate, so its "440 Hz" actually came
    ///          out near 46 Hz — sub-bass, felt as haptics).
    /// Phase 3  the input lane's own idle-frame shape: f8 ff fe header +
    ///          47 B — tests "output frames mirror input framing".
    /// Phase 4  exponential sweep 100→3000 Hz at full rate: the actuator
    ///          physically rolls off above ~1 kHz, headphones don't, so
    ///          where the sound dies reveals which transducer plays it.
    func audioToneTest() {
        let bridgeLog = researchLog

        btQueue.async { [weak self] in
            guard let self, !self.session.ended else { return }
            let session = self.session
            guard session.hasAudioOutput else {
                bridgeLog(.warning, "audio",
                          "audio characteristic not found — controller firmware "
                          + "may be older than 2.0 (update it via a Switch 2 console)")
                return
            }
            guard session.beginAudioExperiment("format probe") else {
                bridgeLog(.warning, "audio", "another audio experiment is running — wait for it to finish")
                return
            }
            let config = Data([0x80, 0xBB, 0x00, 0x00, 0x02, 0xF0, 0x00])
            session.experimentalCommand(0x17, 0x02, payload: config) { resp in
                bridgeLog(.info, "audio",
                          "config → \(resp.map(Self.hex) ?? "none") — starting phases")
            }
            bridgeLog(.info, "audio",
                      "FORMAT PROBE — four phases. For each, note: clean tone / "
                      + "garble / silence, and from WHERE (controller body vs headphones)")

            struct Phase {
                let name: String
                let frames: Int
                let make: (Int, inout Double) -> Data
            }
            let phases: [Phase] = [
                Phase(name: "1/4 raw PCM, full rate (expect 440 Hz if PCM)",
                      frames: 600) { _, ph in
                    Self.sineFrame(samples: 240, freq: 440, sampleRate: 48000, phase: &ph)
                },
                Phase(name: "2/4 legacy 50 B frames at true pitch (the old buzz, corrected)",
                      frames: 600) { _, ph in
                    Self.sineFrame(samples: 25, freq: 440, sampleRate: 5000, phase: &ph)
                },
                Phase(name: "3/4 idle-frame mimic: f8 ff fe + 47 B",
                      frames: 600) { _, ph in
                    var d = Data([0xF8, 0xFF, 0xFE])
                    d.append(Self.sineFrame(samples: 23, freq: 440, sampleRate: 4600, phase: &ph))
                    d.append(0)
                    return d
                },
                Phase(name: "4/4 sweep 100→3000 Hz (where does it die?)",
                      frames: 1200) { i, ph in
                    let freq = 100 * pow(30, Double(i) / 1200)   // exponential sweep
                    if i % 200 == 0 {
                        bridgeLog(.info, "audio", "  sweep at \(Int(freq)) Hz")
                    }
                    return Self.sineFrame(samples: 240, freq: freq, sampleRate: 48000, phase: &ph)
                },
            ]
            var phaseIndex = 0, frameInPhase = 0
            var sinePhase = 0.0
            session.startAudioStream(frameInterval: 0.005) {
                guard phaseIndex < phases.count else { return nil }
                if frameInPhase == 0 {
                    bridgeLog(.info, "audio", "phase \(phases[phaseIndex].name)")
                    sinePhase = 0
                }
                let data = phases[phaseIndex].make(frameInPhase, &sinePhase)
                frameInPhase += 1
                if frameInPhase >= phases[phaseIndex].frames {
                    phaseIndex += 1
                    frameInPhase = 0
                }
                return data
            } done: { stats in
                session.endAudioExperiment()
                bridgeLog(.info, "audio",
                          "probe done: \(stats.chunksWritten) writes, "
                          + "\(stats.chunksDropped) dropped, \(stats.stalls) stalls — "
                          + "which phases made sound, and where?")
            }
        }
    }

    /// Actuator melody on the DOCUMENTED rumble lane (no audio mystery
    /// involved): frequency-controlled HD-rumble tones, resent every
    /// 25 ms with an incrementing sequence nibble. If this plays a clean
    /// little tune, the actuators are fully under our control.
    func hapticMelody() {
        let bridgeLog = researchLog

        btQueue.async { [weak self] in
            guard let self, !self.session.ended else { return }
            let session = self.session
            guard session.beginAudioExperiment("haptic melody") else {
                bridgeLog(.warning, "audio", "another audio experiment is running — wait for it to finish")
                return
            }
            // C major arpeggio up and back — all within the actuator's
            // 1...511 Hz field. (freq, beats); a beat is 90 ms.
            let notes: [(freq: Int, beats: Int)] = [
                (262, 2), (330, 2), (392, 2), (494, 2), (392, 2), (330, 2),
                (262, 4), (0, 1), (392, 1), (0, 1), (392, 2), (262, 4),
            ]
            let beat = 0.090
            let tick = 0.025
            var elapsed = 0.0
            let total = Double(notes.reduce(0) { $0 + $1.beats }) * beat
            bridgeLog(.info, "audio", "haptic melody: \(String(format: "%.1f", total)) s "
                      + "on the rumble lane — should be clean notes, not buzz")
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.btQueue)
            timer.schedule(deadline: .now(), repeating: tick, leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                // Stop silently if the controller vanished mid-tune —
                // writing to a disconnected peripheral is API misuse.
                guard self != nil, !session.ended else {
                    timer.cancel()
                    return
                }
                guard elapsed < total else {
                    timer.cancel()
                    session.writeHapticSample(Switch2.Vibration.tone(freqHz: 200, amp: 0))
                    session.endAudioExperiment()
                    bridgeLog(.info, "audio", "melody done — clean notes = actuator control verified")
                    return
                }
                // Locate the current note and its age (for the envelope).
                var t = elapsed
                var current: (freq: Int, beats: Int) = (0, 1)
                for n in notes {
                    let dur = Double(n.beats) * beat
                    if t < dur { current = n; break }
                    t -= dur
                }
                if current.freq > 0 {
                    // Exponential decay envelope makes notes articulate
                    // instead of running together.
                    let amp = 0.95 * exp(-t * 6)
                    session.writeHapticSample(.tone(freqHz: current.freq, amp: amp))
                } else {
                    session.writeHapticSample(.tone(freqHz: 200, amp: 0))
                }
                elapsed += tick
            }
            self.melodyTimer = timer
            timer.resume()
        }
    }


    private static func hex(_ data: Data) -> String {
        data.prefix(48).map { String(format: "%02x", $0) }.joined(separator: " ")
            + (data.count > 48 ? " …(\(data.count)B)" : "")
    }
}
