// BridgeEngine.swift
// The conductor: owns the CBCentralManager, scans for Switch 2 controller
// advertisements, and maps PHYSICAL Bluetooth sessions onto LOGICAL players.
//
// Two-level model:
//  * Physical: up to 8 concurrent BLE sessions (8 Joy-Cons = 4 grips).
//  * Logical: up to 4 player outputs (what sinks/games see). A logical
//    player is either one controller or a linked Joy-Con L+R pair.
//  Links are persisted per serial pair, so grips re-form on reconnect.
//  Player LEDs show the LOGICAL player number; both halves of a grip match.
//
// Threading model: ALL engine state is confined to `btQueue` — the queue the
// central manager and every delegate callback run on. The only main-thread
// state is the @Published properties, updated via explicit hops.

import Foundation
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
    case off = "Bluetooth off"
    case unauthorized = "Bluetooth permission denied"
    case scanning = "Switch 2 Controller Connection Manager"
    case connecting = "Connecting…"
    case idle = "All controller slots full"
}

final class BridgeEngine: NSObject, ObservableObject, @unchecked Sendable {

    /// Physical BLE session capacity (8 Joy-Cons = 4 grips).
    static let maxSessions = 8
    /// Logical player outputs — what games can see.
    static let maxPlayers = 4

    // Main-thread state, for SwiftUI only.
    @Published private(set) var engineState: EngineState = .off
    @Published private(set) var controllers: [ControllerStatus] = []
    /// Throttled (~10 Hz) live input per player, for the input visualizer.
    @Published private(set) var liveStates: [Int: ControllerState] = [:]
    private var lastVizPush: [Int: TimeInterval] = [:]   // btQueue

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
    private var playerMemory: [String: Int] = [:]

    private var idleSweepTimer: DispatchSourceTimer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: btQueue)
        // Idle sweep: put controllers to sleep after the configured minutes
        // without human input (0 = never). A button press wakes them back.
        let timer = DispatchSource.makeTimerSource(queue: btQueue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.sweepIdleSessions() }
        timer.resume()
        idleSweepTimer = timer
        // The settings store posts this when a custom name changes; push the
        // new names to sinks so games can relabel their joysticks live.
        NotificationCenter.default.addObserver(
            forName: ControllerSettings.namesChangedNotification,
            object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.btQueue.async { self.pushNames() }
        }
    }

    /// btQueue. Disconnect sessions whose last human input is older than the
    /// configured idle timeout.
    private func sweepIdleSessions() {
        let minutes = AppConfig.idleSleepMinutes
        guard minutes > 0 else { return }
        let cutoff = CFAbsoluteTimeGetCurrent() - minutes * 60
        for session in sessions.values where session.lastActivityAt < cutoff {
            let name = session.displayName
            bridgeLog(.info, "engine",
                      "\(name) idle for \(Int(minutes)) min — sleeping to save battery")
            NotificationCenter.default.post(
                name: controllerSleptNotification,
                object: nil, userInfo: ["name": name])
            central.cancelPeripheralConnection(session.peripheral)
        }
    }

    /// btQueue. The user-facing name for a logical player, honoring renames.
    private func displayName(for logical: Logical) -> String {
        let store = UserDefaults.standard.dictionary(forKey: "controllerSettings")
        if let custom = (store?[logical.id] as? [String: Any])?["name"] as? String,
           !custom.isEmpty {
            return custom
        }
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
        }
    }

    // MARK: - Rumble

    /// Per-controller rumble scale, read straight from UserDefaults (which is
    /// thread-safe) so the Bluetooth queue never touches UI-observed objects.
    private static func rumbleIntensity(forSerial serial: String) -> Double {
        let store = UserDefaults.standard.dictionary(forKey: "controllerSettings")
        return (store?[serial] as? [String: Any])?["rumble"] as? Double ?? 1.0
    }

    func setRumble(player: Int, strong: Double, weak weakMag: Double) {
        btQueue.async { [weak self] in
            guard let self, let logical = self.players[player] else { return }
            let scale = Self.rumbleIntensity(forSerial: logical.id)
            for slot in logical.slots {
                self.sessions[slot]?.setRumble(strong: strong * scale,
                                               weak: weakMag * scale)
            }
        }
    }

    func testRumble(player: Int) {
        setRumble(player: player, strong: 1.0, weak: 0.0)
        btQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.setRumble(player: player, strong: 0, weak: 0)
        }
    }

    /// Buzz one PHYSICAL unit (by serial) so the user can tell identical
    /// Joy-Cons apart when choosing what to link. Bypasses player mapping
    /// and intensity settings — identification must always be feelable.
    func identify(serial: String) {
        btQueue.async { [weak self] in
            guard let self,
                  let session = self.sessions.values.first(where: { $0.serialNumber == serial })
            else { return }
            session.setRumble(strong: 1.0, weak: 0)
            self.btQueue.asyncAfter(deadline: .now() + 0.3) {
                session.setRumble(strong: 0, weak: 0)
            }
        }
    }

    // MARK: - Grip links

    func link(leftSerial: String, rightSerial: String) {
        btQueue.async { [weak self] in
            guard let self else { return }
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
                  l.session.model == .joyCon2Left, r.session.model == .joyCon2Right
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
               remembered < Self.maxPlayers, newPlayers[remembered] == nil {
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
                    for sink in sinks { sink.controllerDisconnected(slot: player) }
                }
                if let new {
                    for sink in sinks { sink.controllerConnected(slot: player, model: new.model) }
                }
            }
        }
        players = newPlayers
        pushNames()

        // 4. LEDs follow logical player numbers.
        for (player, logical) in players {
            for slot in logical.slots {
                sessions[slot]?.setPlayerNumber(player + 1)
            }
        }
        publishControllers()
    }

    /// Route one physical unit's report to its logical player.
    private func emitState(slot: Int, state: ControllerState) {
        guard let (player, logical) = players.first(where: { $0.value.slots.contains(slot) })
        else { return }
        var out = state
        if logical.isPair,
           let l = sessions[logical.slots[0]], let r = sessions[logical.slots[1]] {
            out = Self.mergeStates(left: l.state, right: r.state)
        }
        out = Self.applyAxisOptions(out, serial: logical.id)
        for sink in sinks { sink.controllerState(slot: player, state: out) }

        // Feed the dashboard visualizer at ~10 Hz.
        let now = CFAbsoluteTimeGetCurrent()
        if now - (lastVizPush[player] ?? 0) >= 0.1 {
            lastVizPush[player] = now
            let snapshot = out
            DispatchQueue.main.async { [weak self] in
                self?.liveStates[player] = snapshot
            }
        }
    }

    /// Per-controller axis shaping (UserDefaults is thread-safe):
    /// radial deadzone with rescaling (preserves direction, keeps full
    /// range reachable) and optional Y inversions.
    private static func applyAxisOptions(_ state: ControllerState,
                                         serial: String) -> ControllerState {
        let store = UserDefaults.standard.dictionary(forKey: "controllerSettings")
        guard let entry = store?[serial] as? [String: Any] else { return state }
        var s = state
        let dz = entry["deadzone"] as? Double ?? 0.0
        if dz > 0 {
            s.leftStick = Self.radialDeadzone(s.leftStick, dz)
            s.rightStick = Self.radialDeadzone(s.rightStick, dz)
        }
        if entry["invertLX"] as? Bool ?? false { s.leftStick.x = -s.leftStick.x }
        if entry["invertLY"] as? Bool ?? false { s.leftStick.y = -s.leftStick.y }
        if entry["invertRX"] as? Bool ?? false { s.rightStick.x = -s.rightStick.x }
        if entry["invertRY"] as? Bool ?? false { s.rightStick.y = -s.rightStick.y }
        if entry["xboxLayout"] as? Bool ?? false {
            // Positional swap for games with western prompts: A<->B, X<->Y.
            var b = s.buttons
            let a = b.contains(.a), bBtn = b.contains(.b)
            let x = b.contains(.x), y = b.contains(.y)
            b.subtract([.a, .b, .x, .y])
            if a { b.insert(.b) }
            if bBtn { b.insert(.a) }
            if x { b.insert(.y) }
            if y { b.insert(.x) }
            s.buttons = b
        }
        return s
    }

    private static func radialDeadzone(_ stick: (x: Double, y: Double),
                                       _ deadzone: Double) -> (x: Double, y: Double) {
        let magnitude = (stick.x * stick.x + stick.y * stick.y).squareRoot()
        guard magnitude > deadzone else { return (0, 0) }
        let rescaled = min(1, (magnitude - deadzone) / (1 - deadzone))
        return (stick.x / magnitude * rescaled, stick.y / magnitude * rescaled)
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
        DispatchQueue.main.async { [weak self] in
            self?.controllers = snapshot
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
            bridgeLog(.error, "engine",
                      "Bluetooth permission denied — grant it in System Settings > Privacy & Security > Bluetooth")
            publishState(.unauthorized)
        case .poweredOff:
            bridgeLog(.warning, "engine", "Bluetooth is off")
            publishState(.off)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard let manu = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
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

        // Connect attempts can hang; give up after 10 s and rescan.
        btQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, let pending = self.connecting[peripheral.identifier],
                  pending.session === session else { return }
            bridgeLog(.warning, "engine", "connect timeout; rescanning")
            self.central.cancelPeripheralConnection(peripheral)
            self.connecting.removeValue(forKey: peripheral.identifier)
            self.updateScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let pending = connecting[peripheral.identifier] else { return }
        bridgeLog(.info, "engine", "connected, starting handshake")
        pending.session.begin()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        if connecting.removeValue(forKey: peripheral.identifier) != nil {
            bridgeLog(.warning, "engine",
                      "connect failed (\(error?.localizedDescription ?? "unknown"))")
        }
        updateScanning()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        connecting.removeValue(forKey: peripheral.identifier)
        if let (slot, session) = sessions.first(where: {
            $0.value.peripheral.identifier == peripheral.identifier
        }) {
            session.teardown()
            sessions.removeValue(forKey: slot)
            connectedAt.removeValue(forKey: slot)
            bridgeLog(.info, "engine", "\(session.displayName) disconnected")
            recomputeLogical()
        }
        updateScanning()
    }
}

// MARK: - ControllerSessionDelegate (runs on btQueue)

extension BridgeEngine: ControllerSessionDelegate {

    func sessionReady(_ session: ControllerSession) {
        connecting.removeValue(forKey: session.peripheral.identifier)
        sessions[session.slot] = session
        connectedAt[session.slot] = Date()
        session.onState = { [weak self] slot, state in
            self?.emitState(slot: slot, state: state)
        }
        recomputeLogical()
        updateScanning()
    }

    func sessionFailed(_ session: ControllerSession, reason: String) {
        connecting.removeValue(forKey: session.peripheral.identifier)
        central.cancelPeripheralConnection(session.peripheral)
        updateScanning()
    }

    func sessionDidUpdateState(_ session: ControllerSession) {
        publishControllers()
    }
}

// MARK: - Output sink protocol

/// Receives decoded controller traffic on the Bluetooth queue. The `slot`
/// parameter is the LOGICAL player index (0..maxPlayers-1). Implementations
/// must be fast and non-blocking (fire-and-forget I/O only).
protocol ControllerOutputSink: AnyObject {
    func controllerConnected(slot: Int, model: Switch2.Model)
    func controllerDisconnected(slot: Int)
    func controllerState(slot: Int, state: ControllerState)
    /// User-facing name for a player (custom names included); may repeat.
    func controllerName(slot: Int, name: String)
    /// Set by the engine: call to deliver rumble intent for a player.
    var onRumble: ((Int, Double, Double) -> Void)? { get set }
}
