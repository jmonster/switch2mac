// BridgeEngine.swift
// Application policy adapter for Switch2Kit physical-controller snapshots.
// Four logical outputs and up to eight physical dashboard records preserve the
// existing Joy-Con grouping, player order, settings, and output integrations.
// No CoreBluetooth, handshake, report decoder, or calibration lives here.
// All mutable policy/output state belongs to btQueue (the application's serial
// output queue); only @Published presentation properties are main-actor isolated.

import Foundation
import Synchronization
import Combine
import Switch2Kit
import Switch2KitExperimental

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
    case ready = "Remembered controllers connected — discovery paused"
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
    private let controllerManager: Switch2ControllerManager
    private var experimentalSupport: Switch2ExperimentalControllerSupport!
    private var controllerObservation: Switch2ControllerObservation?
    private var lastDiscoveryPreference: (quiet: Bool, ids: [Switch2ControllerID])?
    private var lastControllerPublication: TimeInterval = 0

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
    private let btQueue = DispatchQueue(label: "io.github.jmonster.switch2mac.outputs")

    // btQueue-confined.
    private var sessions: [Int: ApplicationController] = [:]     // physical slot →
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
        let configuration = Switch2ControllerConfiguration(
            discoveryMode: UserDefaults.standard.bool(forKey: DiscoveryPolicy.enabledKey) ? .quietWhenReady : .automatic,
            rememberedControllers: DiscoveryPolicy.savedControllers(), maximumControllers: Self.maxSessions,
            includeSerialNumbers: true) // Explicit legacy mapping compatibility; never log serials.
        controllerManager = Switch2ControllerManager(configuration: configuration) { record in
            let level: LogLevel
            switch record.level {
            case .debug: level = .debug
            case .info: level = .info
            case .warning: level = .warning
            case .error: level = .error
            }
            bridgeLog(level, "Switch2Kit/" + record.category.rawValue, record.message)
        }
        super.init()
        experimentalSupport = Switch2ExperimentalControllerSupport(manager: controllerManager, on: btQueue) { [weak self] event in
            self?.receiveExperimental(event)
        }
        experimentalSupport.setSensorProfile(.init(rawValue: ApplicationSensorPolicy.selectedProfile.rawValue) ?? .compatibility)
        controllerObservation = try? controllerManager.observe(on: btQueue, bufferingNewest: 256) { [weak self] event in
            self?.receiveController(event)
        }
        btQueue.async { [weak self] in self?.reloadConfiguration() }
        controllerManager.start()
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.btQueue.async { [weak self] in self?.reloadConfiguration() }
        })
    }
    deinit {
        controllerObservation?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        controllerManager.stop(completion: {})
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
        updateScanning()
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        btQueue.async { [weak self] in
            guard let self else { completion?(); return }
            self.running = false
            self.resetConnections(cancel: false)
            self.publishState(.paused)
            self.controllerManager.stop { completion?() }
        }
    }
    func resume() {
        btQueue.async { [weak self] in
            guard let self else { return }
            self.running = true
            if !self.suspended { self.controllerManager.start() }
            self.updateScanning()
        }
    }
    func setSuspended(_ value: Bool) {
        btQueue.async { [weak self] in
            guard let self else { return }
            self.suspended = value
            if value { self.resetConnections(cancel: false); self.controllerManager.stop(completion: {}) }
            else if self.running { self.controllerManager.start(); self.updateScanning() }
        }
    }

    /// Retire before requesting cancellation. CoreBluetooth cancellation is
    /// asynchronous; do not reuse this peripheral until its terminal callback.

    /// Record failure before retirement invokes updateScanning. No radio work
    /// occurs here. Saturation keeps existing cooldowns instead of erasing them.

    /// Arm only the earliest future deadline. Expired entries waiting on a
    /// terminal cancellation callback cannot create a zero-delay timer loop.

    /// Shared admission for fresh discovery and a deferred advertisement. A
    /// terminal callback must release cancellation ownership before slot reuse.

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
        guard minutes.isFinite, minutes > 0 else { return }
        let cutoff = now - minutes * 60
        for session in Array(sessions.values) {
            let activity = max(session.lastActivityAt, pointerActivity[session.id.rawValue] ?? 0)
            if activity < cutoff {
                bridgeLog(.warning, "engine", "controller idle timeout")
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

    /// The card identifies hardware, not a reusable game-player number.
    /// Unassigned controllers can still be tested; a pair targets both current
    /// physical sessions. Delayed pulse stops remain owned by those sessions.
    func testRumble(serial: String) {
        btQueue.async { [weak self] in
            guard let self else { return }
            let owners: [ApplicationController]
            if let logical = self.players.values.first(where: { $0.id == serial }) {
                owners = logical.slots.compactMap { self.sessions[$0] }
            } else {
                owners = self.sessions.values.filter { $0.serialNumber == serial }
            }
            guard !owners.isEmpty else {
                bridgeLog(.warning, "engine", "rumble test not sent: controller is no longer connected")
                return
            }
            // Read the latest saved slider value for this explicit UI action;
            // don't race the asynchronous configuration-change notification.
            let entry = (UserDefaults.standard.dictionary(forKey: "controllerSettings")
                as? [String: [String: Any]])?[serial] ?? [:]
            let scale = ControllerConfiguration(entry).rumble
            for session in owners { session.testRumble(intensity: scale) }
        }
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
    func nfcProbe(serial: String) { experimental(.nfcProbe, serial: serial) }
    func audioPlayTone(serial: String) { experimental(.audioTone, serial: serial) }
    func audioToneTest(serial: String) { experimental(.audioFormatProbe, serial: serial) }
    func hapticMelody(serial: String) { experimental(.hapticMelody, serial: serial) }
    private func experimental(_ action: Switch2ExperimentalAction, serial: String) {
        btQueue.async { [weak self] in
            guard let self, let session = self.sessions.values.first(where: { $0.serialNumber == serial }) else { return }
            try? self.experimentalSupport.perform(action, on: session.id)
        }
    }
    func audioCapture(serial: String, seconds: Double = 30) {
        // The dashboard, not Switch2Kit, explicitly chooses its legacy Documents destination.
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        btQueue.async { [weak self] in
            guard let self, let session = self.sessions.values.first(where: { $0.serialNumber == serial }) else { return }
            try? self.experimentalSupport.captureAudio(on: session.id, directory: directory, seconds: seconds)
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
            for part in serial.split(separator: "+").map(String.init) {
                if let session = self.sessions.values.first(where: { $0.serialNumber == part }) {
                    self.controllerManager.forget(session.id)
                    self.retire(session, cancel: false)
                }
            }
        }
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
            bridgeLog(.info, "engine", "linked Joy-Con grip")
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
            bridgeLog(.info, "engine", "unlinked Joy-Con grip")
            self.recomputeLogical()
        }
    }

    // MARK: - Logical assignment (btQueue)

    private func sessionBySerial(_ serial: String) -> (slot: Int, session: ApplicationController)? {
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
    private weak var findingSession: ApplicationController?

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

    private func handlePointerInput(_ session: ApplicationController, state: ControllerState) {
        guard sessions[session.slot] === session, !session.isRetired else { return }
        if mouseController.handle(serial: session.serialNumber, model: session.model, state: state,
                                  configuration: configurations[session.serialNumber] ?? ControllerConfiguration()) {
            pointerActivity[session.id.rawValue] = ProcessInfo.processInfo.systemUptime
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

    private func receiveController(_ event: Switch2ControllerEvent) {
        dispatchPrecondition(condition: .onQueue(btQueue))
        switch event {
        case .snapshot(let snapshot), .status(let snapshot):
            reconcile(snapshot)
        case .connected(let controller):
            guard running, !suspended else { return }
            accept(controller)
        case .input(let controller):
            guard running, !suspended else { return }
            accept(controller)
        case .disconnected(let id, _):
            if let record = sessions.values.first(where: { $0.id == id }) { retire(record, cancel: false) }
        case .connectionChanged:
            if running, !suspended { publishState(.connecting) }
        case .signalStrengthChanged(let id, let decibels):
            sessions.values.first(where: { $0.id == id })?.onRSSI?(decibels)
        case .failure(_, let error):
            bridgeLog(.warning, "Switch2Kit", "controller operation failed: \(error)")
        }
    }

    private func reconcile(_ snapshot: Switch2ManagerSnapshot) {
        guard running, !suspended else {
            if !sessions.isEmpty { resetConnections(cancel: false) }
            publishState(.paused); return
        }
        let current = Set(snapshot.controllers.map(\.id))
        for record in Array(sessions.values) where !current.contains(record.id) { retire(record, cancel: false) }
        for controller in snapshot.controllers { accept(controller) }
        if snapshot.isRunning, UserDefaults.standard.bool(forKey: DiscoveryPolicy.enabledKey) {
            let remembered = snapshot.rememberedControllers.prefix(Self.maxSessions).map { $0.rawValue.uuidString }
            if UserDefaults.standard.stringArray(forKey: DiscoveryPolicy.rememberedKey) != remembered {
                UserDefaults.standard.set(remembered, forKey: DiscoveryPolicy.rememberedKey)
            }
        }
        switch snapshot.bluetooth {
        case .unauthorized: publishState(.unauthorized)
        case .poweredOn:
            switch snapshot.discovery {
            case .scanning: publishState(.scanning)
            case .connecting: publishState(.connecting)
            case .capacityReached: publishState(.idle)
            case .paused: publishState(.ready)
            case .stopped: publishState(snapshot.isRunning ? .ready : .paused)
            }
        default: publishState(.off)
        }
    }

    private func accept(_ controller: Switch2Controller) {
        if let old = sessions.values.first(where: { $0.id == controller.id }),
           old.snapshot.sessionGeneration != controller.sessionGeneration { retire(old, cancel: false) }
        let record: ApplicationController
        if let existing = sessions.values.first(where: { $0.id == controller.id }) {
            existing.update(controller); record = existing
        } else {
            guard let slot = (0..<Self.maxSessions).first(where: { sessions[$0] == nil }) else { return }
            record = ApplicationController(snapshot: controller, slot: slot, manager: controllerManager,
                                           experimental: experimentalSupport)
            sessions[slot] = record; connectedAt[slot] = controller.connectedAt
            updateIdleSweep(); recomputeLogical()
        }
        emitState(slot: record.slot, state: record.state)
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastControllerPublication >= 1 { lastControllerPublication = now; publishControllers() }
    }

    // Application-output retirement only. All transport/session retirement belongs to Switch2Kit.
    private func retire(_ session: ApplicationController, cancel: Bool, recompute: Bool = true) {
        guard sessions[session.slot] === session else { return }
        sessions.removeValue(forKey: session.slot)
        connectedAt.removeValue(forKey: session.slot)
        session.teardown()
        mouseController.reset(serial: session.serialNumber)
        pointerActivity.removeValue(forKey: session.id.rawValue)
        if findingSession === session { stopFinding() }
        if cancel { controllerManager.disconnect(session.id) }
        updateIdleSweep()
        if recompute { recomputeLogical() }
    }

    private func resetConnections(cancel: Bool) {
        for session in Array(sessions.values) { retire(session, cancel: cancel, recompute: false) }
        recomputeLogical(); stopFinding()
        keyboardMapper.reset(); mouseController.reset(); gestureRecognizer.reset()
        lastButtonsByPlayer.removeAll(); captureLast.removeAll()
        if visualizer.clearAll() { scheduleVisualizerDrain() }
    }

    // Preference bridge only: the actual scan state machine is in Switch2Kit.
    private func updateScanning() {
        let quiet = UserDefaults.standard.bool(forKey: DiscoveryPolicy.enabledKey)
        let ids = DiscoveryPolicy.savedControllers()
        if lastDiscoveryPreference?.quiet != quiet || lastDiscoveryPreference?.ids != ids {
            lastDiscoveryPreference = (quiet, ids)
            controllerManager.configureDiscovery(quiet ? .quietWhenReady : .automatic, remembered: ids)
        }
    }
    func requestDiscoveryWindow() { try? controllerManager.discover(for: 60) }
    func useConnectedForDiscovery() { controllerManager.useOnlyConnectedControllersForDiscovery() }

    private func receiveExperimental(_ event: Switch2ExperimentalEvent) {
        switch event {
        case .nfcTagRead(_, let tag):
            // UI owns this notification contract; tag contents are not sent to the log pipeline.
            NotificationCenter.default.post(name: nfcTagReadNotification, object: nil,
                userInfo: ["uid": tag.uid, "text": tag.text as Any, "bytes": tag.byteCount])
        case .audioCaptureFinished(_, let capture):
            bridgeLog(.info, "audio", "capture finished: \(capture.packetCount) packets, \(capture.droppedPacketCount) dropped; files saved in the selected Documents directory")
        case .failure(_, let error):
            bridgeLog(.warning, "experimental", "research operation failed: \(error)")
        }
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

// MARK: - Output sink protocol

/// Receives adapted controller traffic on the application output queue, never the Bluetooth callback queue. The `slot`
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
