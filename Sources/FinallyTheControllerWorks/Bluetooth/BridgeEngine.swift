// BridgeEngine.swift
// The conductor: owns the CBCentralManager, scans for Switch 2 controller
// advertisements, and maps PHYSICAL Bluetooth sessions onto LOGICAL players.
//
// Two-level model:
//  * Physical: up to 8 concurrent BLE sessions (8 Joy-Cons = 4 grips).
//  * Logical: up to 4 player outputs (what games can see). A logical
//    player is either one controller or a linked Joy-Con L+R pair.
//  Links are persisted per serial pair, so grips re-form on reconnect.
//  Player LEDs show the LOGICAL player number; both halves of a grip match.
//
// Threading model: ALL engine state is confined to `btQueue` — the queue the
// central manager and every delegate callback run on. The only main-thread
// state is the @Published properties, updated via explicit hops.

import Foundation
import Synchronization
import CoreBluetooth

/// UI-facing snapshot of one logical controller (single or Joy-Con pair).
struct ControllerStatus: Identifiable, Sendable {
    let id: Int                 // stable UI identity (player, or 100+slot when unassigned)
    let player: Int             // 0-based logical player, -1 when unassigned
    let name: String
    let serial: String          // pair: "Lserial+Rserial"
    let batteryMillivolts: UInt16
    let connectedAt: Date
    var model: Switch2.Model = .proController2
    var isJoyConPair: Bool = false

    /// Rough Li-ion percentage from voltage (3.30 V empty, 4.15 V full).
    var batteryPercent: Int {
        guard batteryMillivolts > 0 else { return 0 }
        let pct = (Double(batteryMillivolts) - 3300) / (4150 - 3300) * 100
        return min(100, max(0, Int(pct)))
    }
}

enum EngineState: String, Sendable {
    case paused = "Controller output stopped"
    case off = "Bluetooth off"
    case unauthorized = "Bluetooth permission denied"
    case scanning = "Scanning for controllers…"
    case connecting = "Connecting…"
    case idle = "All controller slots full"
}

final class BridgeEngine: NSObject, ObservableObject, @unchecked Sendable {

    /// Physical BLE session capacity (8 Joy-Cons = 4 grips).
    static let maxSessions = 8
    /// Logical player outputs — what games can see.
    static let maxPlayers = 4

    // Main-thread state, for SwiftUI only.
    @MainActor @Published private(set) var engineState: EngineState = .off
    @MainActor @Published private(set) var controllers: [ControllerStatus] = []
    /// Throttled (~10 Hz) live input per player, for the input visualizer.
    @MainActor @Published private(set) var liveStates: [Int: ControllerState] = [:]
    private let visualizer = VisualizerMailbox<ControllerState>(maxSlots: BridgeEngine.maxPlayers)
    private var pointerActivity: [UUID: TimeInterval] = [:] // btQueue, accepted pointer output only

    @MainActor private var infoSnapshot: [String: Switch2.ControllerInfo] = [:]
    @MainActor private var participantSnapshot: [(id: String, name: String)] = []
    private var running = true
    private var suspended = false
    private var disconnecting = Set<UUID>()
    private var deadlines: [UUID: DispatchWorkItem] = [:]
    private var retryAfter: [UUID: TimeInterval] = [:]
    private var observers: [NSObjectProtocol] = []
    private var configurations: [String: ControllerConfiguration] = [:]
    private var configurationSource: NSDictionary = [:]
    private var inputContext = InputContext()
    private struct Callbacks: Sendable {
        var permission: (@Sendable (Bool) -> Void)?
        var press: (@Sendable (String, TimeInterval) -> Void)?
        var state: (@Sendable (String, ControllerState) -> Void)?
    }
    private let callbacks = Mutex(Callbacks())
    var onInputPermissionNeeded: (@Sendable (Bool) -> Void)? {
        get { callbacks.withLock { $0.permission } }
        set {
            callbacks.withLock { $0.permission = newValue }
            btQueue.async { [weak self] in self?.reloadConfiguration() }
        }
    }
    private var central: CBCentralManager!
    private let btQueue = DispatchQueue(label: "com.petersharma.ftcw.bluetooth")

    // btQueue-confined.
    private var sessions: [Int: ControllerSession] = [:]     // physical slot →
    private var connecting: [UUID: (session: ControllerSession, slot: Int)] = [:]
    private var connectedAt: [Int: Date] = [:]
    private var sinks: [any ControllerOutputSink] = []

    /// Persisted grip links: left serial → right serial.
    private var links: [String: String] =
        UserDefaults.standard.dictionary(forKey: "joyConLinks") as? [String: String] ?? [:]

    /// One logical player output.
    private struct Logical {
        let id: String              // single: serial; pair: "l+r"
        let slots: [Int]            // physical slots (1 or 2, left first)
        let model: Switch2.Model    // pair presents as Pro Controller
        let isPair: Bool
    }
    /// Current logical assignment: player index (0..maxPlayers-1) → logical.
    private var players: [Int: Logical] = [:]
    /// Remembered player numbers per logical id (stable across reshuffles).
    private var playerMemory: [String: Int] =
        (UserDefaults.standard.dictionary(forKey: "playerMemory") as? [String: Int] ?? [:])
            .filter { (0..<4).contains($0.value) }

    private var idleSweepTimer: DispatchSourceTimer?

    @MainActor override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: btQueue)
        btQueue.async { [weak self] in self?.reloadConfiguration() }
        // The settings store posts this when a custom name changes; push the
        // new names to sinks so games can relabel their joysticks live.
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.btQueue.async { [weak self] in self?.reloadConfiguration() }
        })
    }

    func updateInputContext(_ context: InputContext) {
        btQueue.async { [weak self] in
            guard let self else { return }
            self.inputContext = context
            self.keyboardMapper.updateContext(app: context.application, permission: context.canPostEvents)
            self.mouseController.updateContext(permission: context.canPostEvents, screens: context.screens)
        }
    }

    private func reloadConfiguration() {
        let raw = UserDefaults.standard.dictionary(forKey: "controllerSettings") as? [String: [String: Any]] ?? [:]
        if !configurationSource.isEqual(to: raw) {
            configurations = raw.mapValues { ControllerConfiguration($0) }
            configurationSource = raw as NSDictionary
            keyboardMapper.reset()
            mouseController.reset()
        }
        gestureRecognizer.reload()
        onInputPermissionNeeded?(configurations.values.contains {
            $0.mouseEnabled || !$0.globalKeys.isEmpty || $0.appKeys.values.contains { !$0.isEmpty }
        })
        let savedLinks = UserDefaults.standard.dictionary(forKey: "joyConLinks") as? [String: String] ?? [:]
        if savedLinks != links { links = savedLinks; recomputeLogical() }
        else { pushNames() }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        btQueue.async { [weak self] in
            guard let self else { completion?(); return }
            self.running = false
            self.resetConnections(cancel: true)
            self.publishState(.paused)
            completion?()
        }
    }
    func resume() {
        btQueue.async { [weak self] in
            guard let self else { return }
            self.running = true
            self.updateScanning()
        }
    }
    func setSuspended(_ value: Bool) {
        btQueue.async { [weak self] in
            guard let self else { return }
            self.suspended = value
            if value { self.resetConnections(cancel: true) }
            else { self.updateScanning() }
        }
    }

    private func owns(_ session: ControllerSession) -> Bool {
        sessions[session.slot] === session || connecting[session.peripheral.identifier]?.session === session
    }

    /// Retire before requesting cancellation. CoreBluetooth cancellation is
    /// asynchronous; do not reuse this peripheral until its terminal callback.
    private func retire(_ session: ControllerSession, cancel: Bool, recompute: Bool = true) {
        guard owns(session) else { return }
        let id = session.peripheral.identifier
        if connecting[id]?.session === session { connecting.removeValue(forKey: id) }
        if sessions[session.slot] === session { sessions.removeValue(forKey: session.slot) }
        deadlines.removeValue(forKey: id)?.cancel()
        connectedAt.removeValue(forKey: session.slot)
        mouseController.reset(serial: session.serialNumber)
        pointerActivity.removeValue(forKey: id)
        if findingSession === session { stopFinding() }
        session.teardown()
        if cancel {
            disconnecting.insert(id)
            central.cancelPeripheralConnection(session.peripheral)
        }
        updateIdleSweep()
        if recompute { recomputeLogical() }
    }

    private func resetConnections(cancel: Bool) {
        central.stopScan()
        let current = Array(sessions.values) + connecting.values.map { $0.session }
        for session in current { retire(session, cancel: cancel, recompute: false) }
        recomputeLogical()
        if !cancel { disconnecting.removeAll() }
        stopFinding()
        keyboardMapper.reset(); mouseController.reset(); gestureRecognizer.reset()
        lastButtonsByPlayer.removeAll(); captureLast.removeAll()
        if visualizer.clearAll() { scheduleVisualizerDrain() }
    }

    private func armDeadline(_ session: ControllerSession, seconds: Double) {
        let id = session.peripheral.identifier
        deadlines.removeValue(forKey: id)?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, self.connecting[id]?.session === session else { return }
            bridgeLog(.warning, "engine", "connection phase timed out; retiring attempt")
            self.retryAfter[id] = ProcessInfo.processInfo.systemUptime + 2
            self.retire(session, cancel: true)
            self.updateScanning()
        }
        deadlines[id] = work
        btQueue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Only active, ready sessions require an idle/stale watchdog. Connecting
    /// attempts already have their own deadlines; paused/empty engines do not poll.
    private func updateIdleSweep() {
        guard running, !suspended, !sessions.isEmpty else {
            idleSweepTimer?.cancel(); idleSweepTimer = nil
            return
        }
        guard idleSweepTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: btQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.sweepIdleSessions() }
        timer.resume(); idleSweepTimer = timer
    }

    /// btQueue. Disconnect sessions whose last human input is older than the
    /// configured idle timeout.
    private func sweepIdleSessions() {
        guard running, !suspended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let minutes = AppConfig.idleSleepMinutes
        let cutoff = now - (minutes.isFinite ? max(0, minutes) : 0) * 60
        for session in Array(sessions.values) {
            // Audio capture intentionally suppresses normal reports on some firmware.
            let stale = session.audioExperimentName == nil && now - session.lastReportAt > 5
            let activity = max(session.lastActivityAt, pointerActivity[session.peripheral.identifier] ?? 0)
            let idle = minutes.isFinite && minutes > 0 && activity < cutoff
            if stale || idle {
                bridgeLog(.warning, "engine", "\(session.displayName): \(stale ? "input stream stopped" : "idle timeout")")
                retire(session, cancel: true)
            }
        }
    }

    /// btQueue. The user-facing name for a logical player, honoring renames.
    private func displayName(for logical: Logical) -> String {
        if let custom = configurations[logical.id]?.name, !custom.isEmpty { return custom }
        if logical.isPair { return "Joy-Con 2 Pair" }
        return sessions[logical.slots[0]]?.displayName ?? logical.model.displayName
    }

    /// btQueue. Send current names for every assigned player to all sinks.
    private func pushNames() {
        for (player, logical) in players {
            let name = displayName(for: logical)
            for sink in sinks { sink.controllerName(slot: player, name: name) }
        }
        publishControllers()
    }

    func addSink(_ sink: any ControllerOutputSink) {
        btQueue.async { [weak self] in
            guard let self else { return }
            sink.onRumble = { [weak self] player, strong, weakMag in
                self?.setRumble(player: player, strong: strong, weak: weakMag)
            }
            self.sinks.append(sink)
            for (player, logical) in self.players {
                sink.controllerConnected(slot: player, model: logical.model)
                sink.controllerName(slot: player, name: self.displayName(for: logical))
                if let session = self.sessions[logical.slots[0]] { self.emitState(slot: session.slot, state: session.state) }
            }
        }
    }

    // MARK: - Rumble

    /// Per-controller rumble scale, read straight from UserDefaults (which is
    /// thread-safe) so the Bluetooth queue never touches UI-observed objects.
    func setRumble(player: Int, strong: Double, weak weakMag: Double) {
        btQueue.async { [weak self] in
            guard let self, let logical = self.players[player] else { return }
            let scale = self.configurations[logical.id]?.rumble ?? 1
            for slot in logical.slots {
                self.sessions[slot]?.setRumble(strong: strong * scale,
                                               weak: weakMag * scale)
            }
        }
    }

    func testRumble(player: Int) {
        btQueue.async { [weak self] in self?.pulse(player: player, strong: 1, duration: 0.4) }
    }

    private func pulse(player: Int, strong: Double, duration: Double) {
        guard let logical = players[player] else { return }
        let owners = logical.slots.compactMap { sessions[$0] }
        let scale = configurations[logical.id]?.rumble ?? 1
        for session in owners { session.pulseRumble(strong: strong * scale, duration: duration) }
    }

    func identify(serial: String) {
        btQueue.async { [weak self] in
            guard let self, let session = self.sessions.values.first(where: { $0.serialNumber == serial }) else { return }
            session.pulseRumble(strong: 1, duration: 0.3)
        }
    }

    // MARK: - Experiments (NFC + audio; results go to the log)

    /// NFC discovery probe per ndeadly's sniffed console traffic: start
    /// discovery (0x01/0x03), then poll status (0x01/0x05) for a tag UID.
    func nfcProbe(serial: String) {
        btQueue.async { [weak self] in
            guard let self,
                  let session = self.sessions.values.first(where: { $0.serialNumber == serial })
            else { return }
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

    private func nfcPollStatus(session: ControllerSession, attempt: Int) {
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

    private func nfcReadTag(session: ControllerSession, uid: Data) {
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

    private func nfcRunStage(session: ControllerSession, uid: Data,
                             stages: [NFCStage], index: Int) {
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
    private func nfcSendSequence(session: ControllerSession,
                                 _ sequence: [(subcommand: UInt8, payload: Data)],
                                 at index: Int, done: @escaping () -> Void) {
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
    private func nfcReadBuffer(session: ControllerSession,
                               assembled: Data, chunks: Int, retries: Int,
                               maxRetries: Int = 6, uid: Data,
                               onNoData: (@Sendable () -> Void)? = nil) {
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
    private func nfcFinish(session: ControllerSession, assembled: Data, uid: Data) {
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
        NotificationCenter.default.post(
            name: nfcTagReadNotification, object: nil,
            userInfo: ["uid": uidString, "text": text as Any,
                       "bytes": assembled.count])
    }

    /// End discovery (0x01/0x04 per the sniffed console traffic — sent with
    /// an empty payload once the console is done with the tag).
    private func nfcStopDiscovery(session: ControllerSession) {
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
                    if type.first == 0x54 {       // 'T' text record
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
    func audioCapture(serial: String, seconds: Double = 30) {
        btQueue.async { [weak self] in
            guard let self,
                  let session = self.sessions.values.first(where: { $0.serialNumber == serial })
            else { return }
            guard session.beginAudioExperiment("capture") else {
                bridgeLog(.warning, "audio", "another audio experiment is running — wait for it to finish")
                return
            }
            session.setAudioCapture(true) { ok in
                guard ok else {
                    session.endAudioExperiment()
                    bridgeLog(.warning, "audio",
                              "audio characteristic not found — controller firmware "
                              + "may be older than 2.0 (update it via a Switch 2 console)")
                    return
                }
                let stamp: String = {
                    let f = DateFormatter()
                    f.dateFormat = "yyyyMMdd-HHmmss"
                    return f.string(from: Date())
                }()
                // The serial suffix keeps simultaneous captures on two
                // controllers from colliding on one path.
                let suffix = String(serial.suffix(4)).replacingOccurrences(
                    of: "[^A-Za-z0-9]", with: "", options: .regularExpression)
                let docs = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask)[0]
                let fullURL = docs.appendingPathComponent("FTCW-audio-\(stamp)-\(suffix).bin")
                let regionURL = docs.appendingPathComponent("FTCW-audio-\(stamp)-\(suffix)-frames.bin")
                let magic = Data("FTCWAUD2".utf8)
                FileManager.default.createFile(atPath: fullURL.path, contents: magic)
                FileManager.default.createFile(atPath: regionURL.path, contents: magic)
                guard let fullFile = try? FileHandle(forWritingTo: fullURL),
                      let regionFile = try? FileHandle(forWritingTo: regionURL) else {
                    // Notifications are already on — turn them back off or
                    // the controller's input reports stay frozen forever.
                    session.setAudioCapture(false) { _ in }
                    session.endAudioExperiment()
                    bridgeLog(.error, "audio",
                              "cannot open capture files in ~/Documents — capture aborted")
                    return
                }
                _ = try? fullFile.seekToEnd(); _ = try? regionFile.seekToEnd()

                let start = CFAbsoluteTimeGetCurrent()
                func record(_ data: Data, to handle: FileHandle) {
                    var rec = Data()
                    withUnsafeBytes(of: (CFAbsoluteTimeGetCurrent() - start)) {
                        rec.append(contentsOf: $0)
                    }
                    withUnsafeBytes(of: UInt32(data.count).littleEndian) {
                        rec.append(contentsOf: $0)
                    }
                    rec.append(data)
                    try? handle.write(contentsOf: rec)
                }

                final class CaptureCounters: @unchecked Sendable {
                    // Accessed only on this engine's btQueue, including the deadline.
                    var packets = 0, audioFrames = 0, dataFrames = 0
                    var lastState: UInt8 = 0xFF
                    var lastMeter: TimeInterval
                    init(_ start: TimeInterval) { lastMeter = start }
                }
                let counters = CaptureCounters(start)
                session.onAudioPacket = { data in
                    counters.packets += 1
                    record(data, to: fullFile)
                    if data.count >= 65 {
                        let state = data[13]
                        if state & ~0x08 != counters.lastState & ~0x08 {
                            bridgeLog(.info, "audio",
                                      String(format: "jack state 0x%02x: %@", state,
                                             Self.jackStateName(state)))
                            counters.lastState = state
                        }
                        let len = Int(data[14])
                        if state & 0x08 != 0, len > 0, 15 + len <= data.count {
                            let frame = data.subdata(in: 15..<(15 + len))
                            counters.audioFrames += 1
                            // Silent idle frames are f8 ff fe + zeros; any
                            // other content counts as real data.
                            let body = frame.starts(with: [0xF8, 0xFF, 0xFE])
                                ? frame.dropFirst(3) : frame[...]
                            if body.contains(where: { $0 != 0 }) { counters.dataFrames += 1 }
                            record(frame, to: regionFile)
                        }
                    }
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - counters.lastMeter >= 5 {
                        counters.lastMeter = now
                        bridgeLog(.info, "audio",
                                  "…\(counters.packets) reports, \(counters.audioFrames) audio frames "
                                  + "(\(counters.dataFrames) with data)")
                    }
                }
                bridgeLog(.info, "audio",
                          "capture v2: \(Int(seconds)) s — buttons/sticks will freeze "
                          + "during capture (firmware quirk). To capture REAL audio, "
                          + "plug in a HEADSET WITH A MIC and speak into it")
                let config = Data([0x80, 0xBB, 0x00, 0x00, 0x02, 0xF0, 0x00])
                session.experimentalCommand(0x17, 0x02, payload: config) { resp in
                    bridgeLog(.info, "audio",
                              "audio config (48 kHz) response: \(resp.map(Self.hex) ?? "none")")
                }
                self.btQueue.asyncAfter(deadline: .now() + seconds) {
                    session.onAudioPacket = nil
                    session.setAudioCapture(false) { _ in }
                    try? fullFile.close(); try? regionFile.close()
                    session.endAudioExperiment()
                    let verdict = counters.dataFrames > 0
                        ? "\(counters.dataFrames) frames with real payload — codec material!"
                        : "all frames silent — no mic signal reached the controller "
                          + "(state was \(Self.jackStateName(counters.lastState)))"
                    bridgeLog(.info, "audio",
                              "capture done: \(counters.packets) reports, \(counters.audioFrames) audio "
                              + "frames; \(verdict)")
                    bridgeLog(.info, "audio", "files: \(fullURL.lastPathComponent), "
                              + "\(regionURL.lastPathComponent) in ~/Documents")
                }
            }
        }
    }

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
    func audioPlayTone(serial: String) {
        btQueue.async { [weak self] in
            guard let self,
                  let session = self.sessions.values.first(where: { $0.serialNumber == serial })
            else { return }
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
    func audioToneTest(serial: String) {
        btQueue.async { [weak self] in
            guard let self,
                  let session = self.sessions.values.first(where: { $0.serialNumber == serial })
            else { return }
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
                    frameInPhase = 0
                    phaseIndex += 1
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
    func hapticMelody(serial: String) {
        btQueue.async { [weak self] in
            guard let self,
                  let session = self.sessions.values.first(where: { $0.serialNumber == serial })
            else { return }
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
                guard let self, self.sessions.values.contains(where: { $0 === session }) else {
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
            timer.resume()
        }
    }

    // MARK: - Disconnect / forget

    /// Disconnect a controller (or both halves of a pair) now. It will
    /// reconnect on the next button press — the bond is on the controller.
    func disconnect(serial: String) {
        btQueue.async { [weak self] in
            guard let self else { return }
            for part in serial.split(separator: "+").map(String.init) {
                if let session = self.sessions.values.first(where: { $0.serialNumber == part }) {
                    bridgeLog(.info, "engine", "\(session.displayName): disconnect requested")
                    self.retire(session, cancel: true)
                }
            }
        }
    }

    /// Forget: unlink, wipe stored settings (name, mappings, everything),
    /// forget its player slot, and disconnect. The controller itself still
    /// remembers this Mac, so pressing a button will reconnect it fresh.
    func forget(serial: String) {
        unlink(serial: serial)
        btQueue.async { [weak self] in
            guard let self else { return }
            for part in serial.split(separator: "+").map(String.init) {
                self.playerMemory.removeValue(forKey: part)
            }
            self.playerMemory.removeValue(forKey: serial)
            DispatchQueue.main.async {
                for part in serial.split(separator: "+").map(String.init) {
                    ControllerSettings.shared.removeSettings(forSerial: part)
                }
                ControllerSettings.shared.removeSettings(forSerial: serial)
            }
            self.disconnect(serial: serial)
        }
    }

    private static func hex(_ data: Data) -> String {
        data.prefix(48).map { String(format: "%02x", $0) }.joined(separator: " ")
            + (data.count > 48 ? " …(\(data.count)B)" : "")
    }

    // MARK: - Grip links

    func link(leftSerial: String, rightSerial: String) {
        btQueue.async { [weak self] in
            guard let self else { return }
            guard leftSerial != rightSerial,
                  self.sessionBySerial(leftSerial)?.session.model == .joyCon2Left,
                  self.sessionBySerial(rightSerial)?.session.model == .joyCon2Right else { return }
            self.links = self.links.filter { $0.key != leftSerial && $0.value != rightSerial }
            self.links[leftSerial] = rightSerial
            UserDefaults.standard.set(self.links, forKey: "joyConLinks")
            bridgeLog(.info, "engine", "linked grip: \(leftSerial) + \(rightSerial)")
            self.recomputeLogical()
        }
    }

    /// Accepts a unit serial or a pair id ("l+r").
    func unlink(serial: String) {
        btQueue.async { [weak self] in
            guard let self else { return }
            let parts = serial.split(separator: "+").map(String.init)
            let candidates = parts.isEmpty ? [serial] : parts
            for candidate in candidates {
                self.links.removeValue(forKey: candidate)
                if let left = self.links.first(where: { $0.value == candidate })?.key {
                    self.links.removeValue(forKey: left)
                }
            }
            UserDefaults.standard.set(self.links, forKey: "joyConLinks")
            bridgeLog(.info, "engine", "unlinked grip (\(serial))")
            self.recomputeLogical()
        }
    }

    // MARK: - Logical assignment (btQueue)

    private func sessionBySerial(_ serial: String) -> (slot: Int, session: ControllerSession)? {
        for (slot, session) in sessions where session.serialNumber == serial {
            return (slot, session)
        }
        return nil
    }

    /// Rebuild the player table from sessions + links; emit sink hotplug
    /// events for every change; push LEDs and UI snapshots.
    private func recomputeLogical() {
        // 1. Desired logical set.
        var desired: [Logical] = []
        var pairedSlots = Set<Int>()
        for (lSerial, rSerial) in links {
            guard let l = sessionBySerial(lSerial), let r = sessionBySerial(rSerial),
                  l.session.model == .joyCon2Left, r.session.model == .joyCon2Right,
                  !pairedSlots.contains(l.slot), !pairedSlots.contains(r.slot)
            else { continue }
            desired.append(Logical(id: "\(lSerial)+\(rSerial)",
                                   slots: [l.slot, r.slot],
                                   model: .proController2, isPair: true))
            pairedSlots.insert(l.slot)
            pairedSlots.insert(r.slot)
        }
        for (slot, session) in sessions where !pairedSlots.contains(slot) {
            desired.append(Logical(id: session.serialNumber, slots: [slot],
                                   model: session.model, isPair: false))
        }
        // Stable order: remembered players first, then connection order.
        desired.sort { a, b in
            let pa = playerMemory[a.id] ?? Int.max
            let pb = playerMemory[b.id] ?? Int.max
            if pa != pb { return pa < pb }
            return (a.slots.min() ?? 0) < (b.slots.min() ?? 0)
        }

        // 2. Assign players: keep remembered numbers when free, else lowest.
        var newPlayers: [Int: Logical] = [:]
        var unassigned: [Logical] = []
        for logical in desired {
            if let remembered = playerMemory[logical.id],
               (0..<Self.maxPlayers).contains(remembered), newPlayers[remembered] == nil {
                newPlayers[remembered] = logical
            } else {
                unassigned.append(logical)
            }
        }
        for logical in unassigned {
            if let free = (0..<Self.maxPlayers).first(where: { newPlayers[$0] == nil }) {
                newPlayers[free] = logical
                playerMemory[logical.id] = free
            } else {
                bridgeLog(.warning, "engine",
                          "no free player slot for \(logical.id) — connected but not visible to games (max \(Self.maxPlayers) players)")
            }
        }

        // 3. Sink hotplug diff.
        for player in 0..<Self.maxPlayers {
            let old = players[player]
            let new = newPlayers[player]
            if old?.id != new?.id {
                if old != nil {
                    keyboardMapper.reset(player: player)
                    gestureRecognizer.reset(player: player)
                    lastButtonsByPlayer.removeValue(forKey: player)
                    captureLast.removeValue(forKey: player)
                    if visualizer.clear(slot: player) { scheduleVisualizerDrain() }
                    for sink in sinks { sink.controllerDisconnected(slot: player) }
                }
                if let new {
                    for sink in sinks { sink.controllerConnected(slot: player, model: new.model) }
                }
            }
        }
        players = newPlayers
        if playerMemory.count <= 256 {
            let previous = UserDefaults.standard.dictionary(forKey: "playerMemory") as? [String: Int] ?? [:]
            if previous != playerMemory { UserDefaults.standard.set(playerMemory, forKey: "playerMemory") }
        }
        pushNames()

        // 4. LEDs follow logical player numbers.
        for (player, logical) in players {
            for slot in logical.slots {
                sessions[slot]?.setPlayerNumber(player + 1)
            }
        }
        publishControllers()
    }

    private let mouseController = MouseController()
    private let keyboardMapper = KeyboardMapper()
    let gestureRecognizer = GestureRecognizer()

    // Reaction game: full-rate rising-edge button detection per logical
    // participant (keyed by the logical id). Set by the game coordinator.
    var onParticipantPress: (@Sendable (_ id: String, _ time: TimeInterval) -> Void)? {
        get { callbacks.withLock { $0.press } }
        set { callbacks.withLock { $0.press = newValue } }
    }
    private var lastButtonsByPlayer: [Int: Switch2.Buttons] = [:]
    private var captureLast: [Int: Switch2.Buttons] = [:]

    private static func takeScreenshot() {
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        // Interactive-free full screen capture to a timestamped file.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let name = "Controller Screenshot \(Int(Date().timeIntervalSince1970)).png"
        task.arguments = ["-x", dir.appendingPathComponent(name).path]
        try? task.run()
        bridgeLog(.info, "capture", "screenshot saved to \(name)")
    }

    /// Full-rate per-participant sensor stream for the challenge games
    /// (keyed by logical id). Set by the challenge coordinator.
    var onParticipantState: (@Sendable (_ id: String, _ state: ControllerState) -> Void)? {
        get { callbacks.withLock { $0.state } }
        set { callbacks.withLock { $0.state = newValue } }
    }

    /// Rumble every connected participant simultaneously (party buzz).
    /// Returns the buzz timestamp so reaction times can be measured against it.
    @discardableResult
    func buzzAll(strong: Double = 1.0, durationMs: Int = 250) -> TimeInterval {
        let now = CFAbsoluteTimeGetCurrent()
        btQueue.async { [weak self] in
            guard let self else { return }
            for player in self.players.keys { self.pulse(player: player, strong: strong, duration: Double(max(0, durationMs)) / 1000) }
        }
        return now
    }

    func buzz(id: String, strong: Double = 1.0, durationMs: Int = 200) {
        btQueue.async { [weak self] in
            guard let self, let player = self.players.first(where: { $0.value.id == id })?.key else { return }
            self.pulse(player: player, strong: strong, duration: Double(max(0, durationMs)) / 1000)
        }
    }

    /// Fix the player order explicitly: ids in order become players 1..N.
    /// Persisted via playerMemory so the assignment sticks.
    func assignPlayerOrder(_ idsInOrder: [String]) {
        btQueue.async { [weak self] in
            guard let self else { return }
            for (rank, id) in idsInOrder.enumerated() where rank < Self.maxPlayers {
                self.playerMemory[id] = rank
            }
            self.recomputeLogical()
        }
    }

    // MARK: - Find My Controller

    /// Live RSSI-based proximity while a find is active (published to UI).
    @MainActor @Published private(set) var findingSerial: String?
    @MainActor @Published private(set) var findRSSI: Int = -100
    private var findTimer: DispatchSourceTimer?
    private weak var findingSession: ControllerSession?

    /// Flash LEDs, pulse rumble, and poll RSSI for ~15 s so a lost
    /// controller can be located. Call again with the same serial to stop.
    func findController(serial: String) {
        btQueue.async { [weak self] in
            guard let self else { return }
            if self.findTimer != nil {   // already finding → stop
                self.stopFinding()
                return
            }
            guard let session = self.sessions.values.first(where: { $0.serialNumber == serial })
            else { return }
            self.findingSession = session
            DispatchQueue.main.async { self.findingSerial = serial }
            session.onRSSI = { [weak self, weak session] rssi in
                guard let self, let session, self.findingSession === session,
                      self.sessions[session.slot] === session else { return }
                DispatchQueue.main.async { self.findRSSI = rssi }
            }
            var step = 0
            let timer = DispatchSource.makeTimerSource(queue: self.btQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250))
            timer.setEventHandler { [weak self] in
                guard let self, self.findingSession === session,
                      self.sessions[session.slot] === session else { return }
                // Chase the four LEDs and pulse rumble on each beat.
                let pattern: UInt8 = 1 << UInt8(step % 4)
                session.setRawLEDs(pattern)
                session.setRumble(strong: step % 2 == 0 ? 0.9 : 0.0, weak: 0)
                session.requestRSSI()
                step += 1
                if step >= 60 { self.stopFinding() }   // ~15 s
            }
            timer.resume()
            self.findTimer = timer
        }
    }

    private func stopFinding() {
        findTimer?.cancel(); findTimer = nil
        if let session = findingSession {
            session.onRSSI = nil
            session.setRawLEDs(nil)    // restore player LEDs
        }
        findingSession = nil
        DispatchQueue.main.async { [weak self] in self?.findingSerial = nil; self?.findRSSI = -100 }
    }

    /// Re-apply LEDs for a serial after its custom pattern changed.
    func refreshLEDs(serial: String) {
        btQueue.async { [weak self] in
            self?.sessions.values.first { $0.serialNumber == serial }?.refreshLEDs()
        }
    }

    /// Controller info (colors etc.) for the info panel.
    @MainActor func info(serial: String) -> Switch2.ControllerInfo? { infoSnapshot[serial] }
    @MainActor func participants() -> [(id: String, name: String)] { participantSnapshot }

    /// Route one physical unit's report to its logical player.
    private func emitState(slot: Int, state: ControllerState) {
        // Mouse mode operates on PHYSICAL units (a linked pair's right
        // Joy-Con can be lifted off the grip and used as the mouse).
        if let session = sessions[slot] {
            handlePointerInput(session, state: state)
        }
        guard let (player, logical) = players.first(where: { $0.value.slots.contains(slot) })
        else { return }
        var out = state
        if logical.isPair,
           let l = sessions[logical.slots[0]], let r = sessions[logical.slots[1]] {
            out = Self.mergeStates(left: l.state, right: r.state)
        }
        let configuration = configurations[logical.id] ?? ControllerConfiguration()
        out = configuration.apply(out, analogTriggers: logical.model.hasAnalogTriggers)

        // Keyboard mapping: post keystrokes and suppress mapped buttons from
        // the gamepad output so they don't double-act.
        let suppressed = keyboardMapper.process(player: player, configuration: configuration, buttons: out.buttons)
        ControllerConfiguration.suppress(suppressed, in: &out, analogTriggers: logical.model.hasAnalogTriggers)

        for sink in sinks { sink.controllerState(slot: player, state: out) }

        // Reaction game: fire on the rising edge of ANY button, at full
        // report rate with a precise timestamp.
        if let onPress = onParticipantPress {
            let prev = lastButtonsByPlayer[player] ?? []
            if prev.isEmpty && !out.buttons.isEmpty {
                let id = logical.id
                let t = CFAbsoluteTimeGetCurrent()
                onPress(id, t)
            }
            lastButtonsByPlayer[player] = out.buttons
        }
        // Challenge games: full-rate sensor stream keyed by participant id.
        if let onSensor = onParticipantState {
            onSensor(logical.id, out)
        }

        // Air-gesture macros: buffer gyro while the trigger button is held.
        gestureRecognizer.process(player: player, buttons: out.buttons, gyro: out.gyro)

        // Capture button → macOS screenshot (opt-in per controller).
        let prevButtons = captureLast[player] ?? []
        if !prevButtons.contains(.capture), out.buttons.contains(.capture),
           configuration.screenshot {
            DispatchQueue.global(qos: .utility).async { Self.takeScreenshot() }
        }
        captureLast[player] = out.buttons

        // Latest-only coalescing is UI-only. All game-output edges above
        // keep their existing ordered delivery, even with no visible window.
        if visualizer.submit(slot: player, state: out) { scheduleVisualizerDrain() }
    }

    private func handlePointerInput(_ session: ControllerSession, state: ControllerState) {
        guard sessions[session.slot] === session, !session.isRetired else { return }
        if mouseController.handle(serial: session.serialNumber, model: session.model, state: state,
                                  configuration: configurations[session.serialNumber] ?? ControllerConfiguration()) {
            pointerActivity[session.peripheral.identifier] = ProcessInfo.processInfo.systemUptime
        }
    }

    @MainActor func setVisualizerVisible(_ visible: Bool, subscriber: UUID) {
        visualizer.setSubscriber(subscriber, visible: visible)
        if !visualizer.hasSubscribers { liveStates.removeAll() }
    }

    private func scheduleVisualizerDrain() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.liveStates = self.visualizer.take()
        }
    }

    /// Combine two Joy-Con states into one gamepad. The shared button
    /// bitmask makes this a union. Each unit's stick arrives in its OWN
    /// hardware field: left unit → first stick field, right unit → second.
    static func mergeStates(left l: ControllerState,
                            right r: ControllerState) -> ControllerState {
        var s = ControllerState()
        s.buttons = Switch2.Buttons(rawValue: l.buttons.rawValue | r.buttons.rawValue)
        s.leftStick = l.leftStick
        s.rightStick = r.rightStick
        s.leftTrigger = l.leftTrigger
        s.rightTrigger = r.rightTrigger
        s.batteryMillivolts = {
            if l.batteryMillivolts == 0 { return r.batteryMillivolts }
            if r.batteryMillivolts == 0 { return l.batteryMillivolts }
            return min(l.batteryMillivolts, r.batteryMillivolts)
        }()
        s.gyro = r.gyro
        s.accel = r.accel
        return s
    }

    // MARK: - Scan control (btQueue)

    private func updateScanning() {
        guard running, !suspended else { central.stopScan(); publishState(.paused); return }
        guard central.state == .poweredOn else { return }
        let occupied = sessions.count + connecting.count
        if occupied < Self.maxSessions {
            if !central.isScanning {
                central.scanForPeripherals(withServices: nil, options: [
                    CBCentralManagerScanOptionAllowDuplicatesKey: false
                ])
                publishState(.scanning)
            }
        } else if central.isScanning {
            central.stopScan()
            publishState(.idle)
        }
    }

    private func freeSlot() -> Int? {
        for slot in 0..<Self.maxSessions
        where sessions[slot] == nil && !connecting.values.contains(where: { $0.slot == slot }) {
            return slot
        }
        return nil
    }

    // MARK: - Publishing to the UI

    private func publishState(_ state: EngineState) {
        DispatchQueue.main.async { [weak self] in
            self?.engineState = state
        }
    }

    private func publishControllers() {
        var snapshot: [ControllerStatus] = []
        var seenSlots = Set<Int>()

        for (player, logical) in players {
            guard let first = sessions[logical.slots[0]] else { continue }
            logical.slots.forEach { seenSlots.insert($0) }
            if logical.isPair, let r = sessions[logical.slots[1]] {
                let merged = Self.mergeStates(left: first.state, right: r.state)
                snapshot.append(ControllerStatus(
                    id: player, player: player,
                    name: "Joy-Con 2 Pair",
                    serial: logical.id,
                    batteryMillivolts: merged.batteryMillivolts,
                    connectedAt: connectedAt[logical.slots[0]] ?? Date(),
                    model: .proController2, isJoyConPair: true))
            } else {
                snapshot.append(ControllerStatus(
                    id: player, player: player,
                    name: first.displayName,
                    serial: first.serialNumber,
                    batteryMillivolts: first.batteryMillivolts,
                    connectedAt: connectedAt[logical.slots[0]] ?? Date(),
                    model: first.model))
            }
        }
        // Sessions with no player slot (beyond maxPlayers): still listed.
        for (slot, session) in sessions where !seenSlots.contains(slot) {
            snapshot.append(ControllerStatus(
                id: 100 + slot, player: -1,
                name: session.displayName,
                serial: session.serialNumber,
                batteryMillivolts: session.batteryMillivolts,
                connectedAt: connectedAt[slot] ?? Date(),
                model: session.model))
        }
        snapshot.sort { $0.id < $1.id }
        let published = snapshot
        let infos = Dictionary(sessions.values.compactMap { session in session.info.map { (session.serialNumber, $0) } },
                               uniquingKeysWith: { first, _ in first })
        let participants = players.sorted { $0.key < $1.key }.map { (id: $0.value.id, name: displayName(for: $0.value)) }
        DispatchQueue.main.async { [weak self] in
            self?.controllers = published
            self?.infoSnapshot = infos
            self?.participantSnapshot = participants
        }
    }
}

// MARK: - CBCentralManagerDelegate (runs on btQueue)

extension BridgeEngine: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bridgeLog(.info, "engine", "Bluetooth ready")
            updateScanning()
        case .unauthorized:
            resetConnections(cancel: false)
            bridgeLog(.error, "engine",
                      "Bluetooth permission denied — grant it in System Settings > Privacy & Security > Bluetooth")
            publishState(.unauthorized)
        case .poweredOff:
            resetConnections(cancel: false)
            bridgeLog(.warning, "engine", "Bluetooth is off")
            publishState(.off)
        default:
            resetConnections(cancel: false)
            publishState(.off)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard running, !suspended, central.state == .poweredOn,
              !disconnecting.contains(peripheral.identifier),
              ProcessInfo.processInfo.systemUptime >= (retryAfter[peripheral.identifier] ?? 0),
              let manu = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manu.count > 2,
              Switch2.u16(manu, 0) == Switch2.nintendoCompanyID,
              let adv = Switch2.parseAdvertisement(manufacturerData: manu.dropFirst(2)),
              connecting[peripheral.identifier] == nil,
              !sessions.values.contains(where: { $0.peripheral.identifier == peripheral.identifier }),
              let slot = freeSlot()
        else { return }

        bridgeLog(.info, "engine",
                  "found \(adv.model.displayName) rssi=\(RSSI) \(adv.isPairing ? "(pairing mode)" : "(wake)")")
        let session = ControllerSession(peripheral: peripheral, slot: slot,
                                        wasPairingMode: adv.isPairing,
                                        queue: btQueue, delegate: self)
        connecting[peripheral.identifier] = (session, slot)
        central.stopScan()
        publishState(.connecting)
        central.connect(peripheral, options: nil)

        armDeadline(session, seconds: 10)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !disconnecting.contains(peripheral.identifier), running, !suspended,
              let pending = connecting[peripheral.identifier], pending.session.peripheral === peripheral else {
            central.cancelPeripheralConnection(peripheral); return
        }
        bridgeLog(.info, "engine", "connected, starting handshake")
        armDeadline(pending.session, seconds: 45)
        pending.session.begin()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        disconnecting.remove(peripheral.identifier)
        if let pending = connecting[peripheral.identifier], pending.session.peripheral === peripheral {
            retire(pending.session, cancel: false)
            if retryAfter.count > 64 { retryAfter.removeAll() }
            retryAfter[peripheral.identifier] = ProcessInfo.processInfo.systemUptime + 2
            bridgeLog(.warning, "engine", "connect failed (\(error?.localizedDescription ?? "unknown"))")
        }
        updateScanning()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        disconnecting.remove(peripheral.identifier)
        if let pending = connecting[peripheral.identifier], pending.session.peripheral === peripheral {
            retire(pending.session, cancel: false)
        }
        if let session = sessions.values.first(where: { $0.peripheral === peripheral }) {
            retire(session, cancel: false)
        }
        updateScanning()
    }
}

// MARK: - ControllerSessionDelegate (runs on btQueue)

extension BridgeEngine: ControllerSessionDelegate {

    func sessionReady(_ session: ControllerSession) {
        let id = session.peripheral.identifier
        guard running, !suspended, !session.isRetired, !disconnecting.contains(id),
              connecting[id]?.session === session, sessions[session.slot] == nil else {
            if !owns(session) { session.teardown() }
            return
        }
        deadlines.removeValue(forKey: id)?.cancel()
        connecting.removeValue(forKey: id)
        sessions[session.slot] = session
        connectedAt[session.slot] = Date()
        updateIdleSweep()
        session.onState = { [weak self, weak session] slot, state in
            guard let self, let session, self.sessions[slot] === session else { return }
            self.emitState(slot: slot, state: state)
        }
        recomputeLogical()
        updateScanning()
    }

    func sessionFailed(_ session: ControllerSession, reason: String) {
        guard owns(session) else { return }
        retire(session, cancel: true)
        updateScanning()
    }

    func sessionDidUpdateState(_ session: ControllerSession) {
        guard sessions[session.slot] === session else { return }
        publishControllers()
    }
}

// MARK: - Output sink protocol

/// Receives decoded controller traffic on the Bluetooth queue. The `slot`
/// parameter is the LOGICAL player index (0..maxPlayers-1). Implementations
/// must be fast and non-blocking (fire-and-forget I/O only).
protocol ControllerOutputSink: AnyObject, Sendable {
    func controllerConnected(slot: Int, model: Switch2.Model)
    func controllerDisconnected(slot: Int)
    func controllerState(slot: Int, state: ControllerState)
    /// User-facing name for a player (custom names included); may repeat.
    func controllerName(slot: Int, name: String)
    /// Set by the engine: call to deliver rumble intent for a player.
    var onRumble: ((Int, Double, Double) -> Void)? { get set }
}
