// BridgeEngine.swift
// The conductor: owns the CBCentralManager, scans for Switch 2 controller
// advertisements, assigns slots (player 1-4), spawns a ControllerSession per
// connect, and republishes UI-facing status onto the main actor.
//
// Threading model: ALL engine state (sessions, connecting, sinks) is
// confined to `btQueue` — the queue the central manager and every delegate
// callback run on. The only main-thread state is the two @Published
// properties, updated via explicit hops. No locks needed.
//
// Slot invariants (from the Python bridge):
//  * a slot has at most one session;
//  * a peripheral occupies at most one slot;
//  * scanning runs only while a slot is free.

import Foundation
import CoreBluetooth

/// UI-facing snapshot of one connected controller (or a merged Joy-Con pair).
struct ControllerStatus: Identifiable, Sendable {
    let id: Int                 // slot
    let name: String
    let serial: String
    let batteryMillivolts: UInt16
    let reportCount: UInt64
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

    static let maxSlots = 4

    // Main-thread state, for SwiftUI only.
    @Published private(set) var engineState: EngineState = .off
    @Published private(set) var controllers: [ControllerStatus] = []
    /// True when one left and one right Joy-Con are connected (merge possible).
    @Published private(set) var joyConPairAvailable = false
    @Published private(set) var joyConsCombined = false

    private static let combineKey = "combineJoyCons"

    private var central: CBCentralManager!
    private let btQueue = DispatchQueue(label: "com.petersharma.ftcw.bluetooth")

    // btQueue-confined.
    private var sessions: [Int: ControllerSession] = [:]
    private var connecting: [UUID: (session: ControllerSession, slot: Int)] = [:]
    private var connectedAt: [Int: Date] = [:]
    private var sinks: [any ControllerOutputSink] = []
    /// Active Joy-Con merge: the pair presents to sinks as ONE controller on
    /// the left unit's slot; the right unit's slot is suppressed.
    private var mergedPair: (l: Int, r: Int)?
    private var combineEnabled = UserDefaults.standard.bool(forKey: BridgeEngine.combineKey)

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: btQueue)
    }

    func addSink(_ sink: any ControllerOutputSink) {
        btQueue.async { [weak self] in
            guard let self else { return }
            sink.onRumble = { [weak self] slot, strong, weakMag in
                self?.setRumble(slot: slot, strong: strong, weak: weakMag)
            }
            self.sinks.append(sink)
        }
    }

    /// Per-controller rumble scale, read straight from UserDefaults (which is
    /// thread-safe) so the Bluetooth queue never touches UI-observed objects.
    private static func rumbleIntensity(forSerial serial: String) -> Double {
        let store = UserDefaults.standard.dictionary(forKey: "controllerSettings")
        return (store?[serial] as? [String: Any])?["rumble"] as? Double ?? 1.0
    }

    func setRumble(slot: Int, strong: Double, weak weakMag: Double) {
        btQueue.async { [weak self] in
            guard let self else { return }
            // A merged pair rumbles both units, scaled by the pair's setting.
            if let pair = self.mergedPair, slot == pair.l,
               let l = self.sessions[pair.l], let r = self.sessions[pair.r] {
                let scale = Self.rumbleIntensity(
                    forSerial: Self.pairSerial(l.serialNumber, r.serialNumber))
                l.setRumble(strong: strong * scale, weak: weakMag * scale)
                r.setRumble(strong: strong * scale, weak: weakMag * scale)
                return
            }
            guard let session = self.sessions[slot] else { return }
            let scale = Self.rumbleIntensity(forSerial: session.serialNumber)
            session.setRumble(strong: strong * scale, weak: weakMag * scale)
        }
    }

    // MARK: - Joy-Con pairing (grip mode)

    static func pairSerial(_ l: String, _ r: String) -> String { "\(l)+\(r)" }

    func setCombineJoyCons(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.combineKey)
        btQueue.async { [weak self] in
            guard let self else { return }
            self.combineEnabled = enabled
            self.recomputeMerge()
        }
    }

    /// btQueue. Establish or dissolve the merged pair to match reality:
    /// merge exactly when enabled and one left + one right unit are present.
    private func recomputeMerge() {
        let lSlot = sessions.first { $0.value.model == .joyCon2Left }?.key
        let rSlot = sessions.first { $0.value.model == .joyCon2Right }?.key
        let shouldMerge = combineEnabled && lSlot != nil && rSlot != nil

        if let pair = mergedPair,
           !shouldMerge || pair.l != lSlot || pair.r != rSlot {
            // Dissolve: the pair's synthetic controller vanishes; surviving
            // units re-present individually.
            mergedPair = nil
            for sink in sinks { sink.controllerDisconnected(slot: pair.l) }
            if let s = sessions[pair.l] {
                for sink in sinks { sink.controllerConnected(slot: pair.l, model: s.model) }
            }
            if let s = sessions[pair.r] {
                for sink in sinks { sink.controllerConnected(slot: pair.r, model: s.model) }
            }
            bridgeLog(.info, "engine", "Joy-Con pair dissolved")
        }

        if shouldMerge, mergedPair == nil, let l = lSlot, let r = rSlot {
            // Merge: suppress the individual units, present one synthetic
            // pad (Pro Controller identity) on the left unit's slot.
            for sink in sinks {
                sink.controllerDisconnected(slot: l)
                sink.controllerDisconnected(slot: r)
                sink.controllerConnected(slot: l, model: .proController2)
            }
            mergedPair = (l, r)
            bridgeLog(.info, "engine",
                      "Joy-Con pair combined → one gamepad on player \(l + 1)")
        }

        let available = lSlot != nil && rSlot != nil
        let combined = mergedPair != nil
        DispatchQueue.main.async { [weak self] in
            self?.joyConPairAvailable = available
            self?.joyConsCombined = combined
        }
        publishControllers()
    }

    /// btQueue. Route one unit's report: merged pairs emit a combined state
    /// on the left slot; everything else passes straight through.
    private func emitState(slot: Int, state: ControllerState) {
        if let pair = mergedPair, slot == pair.l || slot == pair.r {
            guard let l = sessions[pair.l], let r = sessions[pair.r] else { return }
            let merged = Self.mergeStates(left: l.state, right: r.state)
            for sink in sinks { sink.controllerState(slot: pair.l, state: merged) }
            return
        }
        for sink in sinks { sink.controllerState(slot: slot, state: state) }
    }

    /// Combine two Joy-Con states into one gamepad. The shared button
    /// bitmask makes this a union; each unit reports its own stick in the
    /// report's first stick field, so the right unit's "left" stick is the
    /// pad's right stick.
    static func mergeStates(left l: ControllerState,
                            right r: ControllerState) -> ControllerState {
        var s = ControllerState()
        s.buttons = Switch2.Buttons(rawValue: l.buttons.rawValue | r.buttons.rawValue)
        s.leftStick = l.leftStick
        s.rightStick = r.leftStick
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

    /// Short full-strength pulse (through the user's intensity setting) so
    /// the dashboard can demo the current rumble strength.
    func testRumble(slot: Int) {
        setRumble(slot: slot, strong: 1.0, weak: 0.0)
        btQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.setRumble(slot: slot, strong: 0, weak: 0)
        }
    }

    // MARK: - Scan control (btQueue)

    private func updateScanning() {
        guard central.state == .poweredOn else { return }
        let occupied = sessions.count + connecting.count
        if occupied < Self.maxSlots {
            if !central.isScanning {
                central.scanForPeripherals(withServices: nil, options: [
                    CBCentralManagerScanOptionAllowDuplicatesKey: false
                ])
                bridgeLog(.info, "engine",
                          "scanning (\(Self.maxSlots - occupied) slot(s) free — press a button, or hold Sync to pair a new controller)")
                publishState(.scanning)
            }
        } else if central.isScanning {
            central.stopScan()
            publishState(.idle)
        }
    }

    private func freeSlot() -> Int? {
        for slot in 0..<Self.maxSlots
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
        for (slot, session) in sessions {
            if let pair = mergedPair {
                if slot == pair.r { continue }   // folded into the pair entry
                if slot == pair.l, let r = sessions[pair.r] {
                    let merged = Self.mergeStates(left: session.state, right: r.state)
                    snapshot.append(ControllerStatus(
                        id: slot,
                        name: "Joy-Con 2 Pair",
                        serial: Self.pairSerial(session.serialNumber, r.serialNumber),
                        batteryMillivolts: merged.batteryMillivolts,
                        reportCount: session.reportCount + r.reportCount,
                        connectedAt: connectedAt[slot] ?? Date(),
                        model: .proController2,
                        isJoyConPair: true))
                    continue
                }
            }
            snapshot.append(ControllerStatus(
                id: slot,
                name: session.displayName,
                serial: session.serialNumber,
                batteryMillivolts: session.batteryMillivolts,
                reportCount: session.reportCount,
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
                  "found \(adv.model.displayName) rssi=\(RSSI) \(adv.isPairing ? "(pairing mode)" : "(wake)") → slot \(slot + 1)")
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
            bridgeLog(.warning, "engine", "connect timeout for slot \(slot + 1); rescanning")
            self.central.cancelPeripheralConnection(peripheral)
            self.connecting.removeValue(forKey: peripheral.identifier)
            self.updateScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let pending = connecting[peripheral.identifier] else { return }
        bridgeLog(.info, "engine", "slot \(pending.slot + 1): connected, starting handshake")
        pending.session.begin()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        if let pending = connecting.removeValue(forKey: peripheral.identifier) {
            bridgeLog(.warning, "engine",
                      "slot \(pending.slot + 1): connect failed (\(error?.localizedDescription ?? "unknown"))")
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
            let wasMerged = mergedPair.map { slot == $0.l || slot == $0.r } ?? false
            if !wasMerged {
                for sink in sinks { sink.controllerDisconnected(slot: slot) }
            }
            bridgeLog(.info, "engine", "slot \(slot + 1): disconnected")
            recomputeMerge()   // dissolves the pair if this unit was half of it
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
        for sink in sinks {
            sink.controllerConnected(slot: session.slot, model: session.model)
        }
        recomputeMerge()   // may immediately fold this unit into a pair
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

/// Receives decoded controller traffic on the Bluetooth queue. Implementations
/// must be fast and non-blocking (fire-and-forget I/O only).
protocol ControllerOutputSink: AnyObject {
    func controllerConnected(slot: Int, model: Switch2.Model)
    func controllerDisconnected(slot: Int)
    func controllerState(slot: Int, state: ControllerState)
    /// Set by the engine: call to deliver rumble intent for a slot.
    var onRumble: ((Int, Double, Double) -> Void)? { get set }
}
