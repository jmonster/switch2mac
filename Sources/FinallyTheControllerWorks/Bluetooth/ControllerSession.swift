// ControllerSession.swift
// One connected Switch 2 controller: GATT handshake, command serialization,
// input decoding, keep-alive, and rumble.
//
// Invariants carried over from the proven Python bridge:
//  * No SMP pairing is ever initiated (the controller drops such links);
//    CoreBluetooth only pairs on encrypted characteristics, which these are
//    not, so plain connects are safe.
//  * At most one in-flight command; replies are correlated on the
//    command-response characteristic.
//  * macOS silently terminates the link ~10-17 s after the last host write:
//    a 1 Hz keep-alive write (player-LED refresh) holds it open. Rumble
//    writes count as keep-alives too.
//
// All CoreBluetooth callbacks arrive on `queue`; UI-visible state is
// published through the delegate on the main actor.

import Foundation
import CoreBluetooth

/// Decoded, calibrated controller state pushed to output sinks per report.
struct ControllerState: Sendable {
    var buttons: Switch2.Buttons = []
    var leftStick: (x: Double, y: Double) = (0, 0)
    var rightStick: (x: Double, y: Double) = (0, 0)
    var leftTrigger: UInt8 = 0    // 0...255
    var rightTrigger: UInt8 = 0
    var batteryMillivolts: UInt16 = 0
    var gyro: (Int16, Int16, Int16) = (0, 0, 0)
    var accel: (Int16, Int16, Int16) = (0, 0, 0)
}

/// Called on the Bluetooth queue.
protocol ControllerSessionDelegate: AnyObject {
    func sessionReady(_ session: ControllerSession)
    func sessionFailed(_ session: ControllerSession, reason: String)
    func sessionDidUpdateState(_ session: ControllerSession)
}

final class ControllerSession: NSObject, @unchecked Sendable {

    // MARK: Configuration

    let peripheral: CBPeripheral
    let slot: Int                       // 0-based; player number is slot+1
    let wasPairingMode: Bool            // Sync-held advert → write bond
    private let queue: DispatchQueue    // the central's queue
    private weak var delegate: ControllerSessionDelegate?

    // MARK: Session state (all mutated on `queue`)

    private(set) var model: Switch2.Model = .proController2
    private(set) var info: Switch2.ControllerInfo?
    private var leftCal: Switch2.StickCalibration?
    private var rightCal: Switch2.StickCalibration?

    private var chars: [UUID: CBCharacteristic] = [:]
    private var handshakeStarted = false
    private var pendingCommand: (id: UInt8, completion: (Data?) -> Void)?
    private var commandTimeout: DispatchWorkItem?
    private var handshakeSteps: [(String, (@escaping (Bool) -> Void) -> Void)] = []

    private var keepAliveTimer: DispatchSourceTimer?
    private var lastWriteAt: TimeInterval = 0
    private var vibrationPacketID: UInt8 = 0
    private var rumbleTarget: (strong: Double, weak: Double) = (0, 0)
    private var rumbleSetAt: TimeInterval = 0
    private var rumbleActive = false

    /// Latest decoded state; reads from other threads are tolerated (single
    /// word-sized fields, refreshed at 33 Hz — stale data is harmless).
    private(set) var state = ControllerState()
    private(set) var reportCount: UInt64 = 0
    private var lastReportAt: TimeInterval = 0
    private var gapCount = 0

    /// Sink receiving every decoded report (UDP hub / virtual HID).
    var onState: (@Sendable (Int, ControllerState) -> Void)?

    init(peripheral: CBPeripheral, slot: Int, wasPairingMode: Bool,
         queue: DispatchQueue, delegate: ControllerSessionDelegate) {
        self.peripheral = peripheral
        self.slot = slot
        self.wasPairingMode = wasPairingMode
        self.queue = queue
        self.delegate = delegate
        super.init()
        peripheral.delegate = self
    }

    var displayName: String { model.displayName }
    var serialNumber: String { info?.serialNumber ?? "?" }
    var batteryMillivolts: UInt16 { state.batteryMillivolts }

    // MARK: - Handshake

    /// Called by the engine once CoreBluetooth reports the connect.
    func begin() {
        log(.info, "slot \(slot + 1): discovering services")
        peripheral.discoverServices(nil)
    }

    func teardown() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        commandTimeout?.cancel()
        pendingCommand = nil
    }

    private func fail(_ reason: String) {
        log(.error, "slot \(slot + 1): \(reason)")
        teardown()
        delegate?.sessionFailed(self, reason: reason)
    }

    private func runHandshake() {
        // Order matters and mirrors the console: command-response subscribe
        // must precede any command; identity before vibration char choice.
        handshakeSteps = [
            ("read info", { [weak self] done in self?.stepReadInfo(done) }),
            ("read calibration", { [weak self] done in self?.stepReadCalibration(done) }),
            ("player LEDs", { [weak self] done in self?.stepPlayerLEDs(done) }),
            ("enable features", { [weak self] done in self?.stepFeatures(done) }),
            ("bond", { [weak self] done in self?.stepBond(done) }),
            ("input notifications", { [weak self] done in self?.stepInputNotify(done) }),
        ]
        advanceHandshake()
    }

    private func advanceHandshake() {
        guard !handshakeSteps.isEmpty else {
            startKeepAlive()
            log(.info, "slot \(slot + 1): handshake complete — \(displayName) serial \(serialNumber)")
            delegate?.sessionReady(self)
            return
        }
        let (name, step) = handshakeSteps.removeFirst()
        step { [weak self] ok in
            guard let self else { return }
            if ok {
                self.advanceHandshake()
            } else {
                self.fail("handshake step '\(name)' failed")
            }
        }
    }

    // MARK: Handshake steps

    private func stepReadInfo(_ done: @escaping (Bool) -> Void) {
        readMemory(length: 0x40, address: Switch2.Address.controllerInfo) { [weak self] data in
            guard let self, let data, let info = Switch2.ControllerInfo(memoryBlock: data) else {
                done(false); return
            }
            self.info = info
            if let model = info.model { self.model = model }
            done(true)
        }
    }

    private func stepReadCalibration(_ done: @escaping (Bool) -> Void) {
        readStickCalibration(user: Switch2.Address.userStick1,
                             factory: Switch2.Address.factoryStick1) { [weak self] cal in
            guard let self else { return }
            self.leftCal = cal
            self.readStickCalibration(user: Switch2.Address.userStick2,
                                      factory: Switch2.Address.factoryStick2) { [weak self] cal in
                guard let self else { return }
                self.rightCal = cal
                done(true)   // calibration is best-effort; defaults are usable
            }
        }
    }

    private func readStickCalibration(user: UInt32, factory: UInt32,
                                      _ done: @escaping (Switch2.StickCalibration?) -> Void) {
        readMemory(length: 0x0B, address: user) { [weak self] data in
            guard let self else { return }
            if let data, !Switch2.StickCalibration.isBlank(data) {
                done(Switch2.StickCalibration(data: data))
                return
            }
            self.readMemory(length: 0x0B, address: factory) { data in
                done(data.map { Switch2.StickCalibration(data: $0) })
            }
        }
    }

    private func stepPlayerLEDs(_ done: @escaping (Bool) -> Void) {
        setPlayerLEDs { done($0) }
    }

    private func stepFeatures(_ done: @escaping (Bool) -> Void) {
        let flags = Data([Switch2.Feature.baseline | Switch2.Feature.motion, 0, 0, 0])
        writeCommand(Switch2.Command.feature, Switch2.Subcommand.featureInit, flags) { [weak self] resp in
            guard let self, resp != nil else { done(false); return }
            self.writeCommand(Switch2.Command.feature, Switch2.Subcommand.featureEnable, flags) { resp in
                done(resp != nil)
            }
        }
    }

    private func stepBond(_ done: @escaping (Bool) -> Void) {
        guard wasPairingMode, let mac = HostBluetooth.macAddressBytesLE else {
            done(true)  // nothing to do (button-wake) or MAC unknown
            return
        }
        var payload = Data([0x00, 0x02])
        payload.append(mac); payload.append(mac)
        writeCommand(Switch2.Command.pair, Switch2.Subcommand.pairSetMAC, payload) { [weak self] resp in
            guard let self, resp != nil else { done(false); return }
            self.writeCommand(Switch2.Command.pair, Switch2.Subcommand.pairLTK1, Switch2.pairLTK1) { [weak self] resp in
                guard let self, resp != nil else { done(false); return }
                self.writeCommand(Switch2.Command.pair, Switch2.Subcommand.pairLTK2, Switch2.pairLTK2) { [weak self] resp in
                    guard let self, resp != nil else { done(false); return }
                    self.writeCommand(Switch2.Command.pair, Switch2.Subcommand.pairFinish, Data([0x00])) { resp in
                        bridgeLog(.info, "session", "bonded controller to this Mac")
                        done(resp != nil)
                    }
                }
            }
        }
    }

    private func stepInputNotify(_ done: @escaping (Bool) -> Void) {
        guard let input = chars[Switch2.GATT.inputReport] else { done(false); return }
        notifyCompletion = done
        peripheral.setNotifyValue(true, for: input)
    }

    private var notifyCompletion: ((Bool) -> Void)?

    // MARK: - Commands

    private func writeCommand(_ command: UInt8, _ subcommand: UInt8, _ data: Data,
                              completion: @escaping (Data?) -> Void) {
        guard let writeChar = chars[Switch2.GATT.commandWrite] else {
            completion(nil); return
        }
        guard pendingCommand == nil else {
            // Serialized by construction; overlap is a programming error.
            log(.warning, "command overlap dropped (cmd \(command))")
            completion(nil)
            return
        }
        let frame = Switch2.buildCommand(command, subcommand, data: data)
        pendingCommand = (command, completion)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingCommand else { return }
            self.pendingCommand = nil
            self.log(.warning, "command \(String(format: "%#04x", pending.id)) timed out")
            pending.completion(nil)
        }
        commandTimeout = timeout
        queue.asyncAfter(deadline: .now() + 2.0, execute: timeout)
        peripheral.writeValue(frame, for: writeChar, type: .withoutResponse)
        lastWriteAt = CFAbsoluteTimeGetCurrent()
    }

    private func handleCommandResponse(_ data: Data) {
        guard let pending = pendingCommand else { return }
        commandTimeout?.cancel()
        pendingCommand = nil
        guard data.count >= 8, data[data.startIndex] == pending.id,
              data[data.startIndex + 1] == 0x01 else {
            pending.completion(nil)
            return
        }
        pending.completion(data.subdata(in: data.startIndex + 8 ..< data.endIndex))
    }

    private func readMemory(length: UInt8, address: UInt32,
                            completion: @escaping (Data?) -> Void) {
        let payload = Switch2.memoryReadPayload(length: length, address: address)
        writeCommand(Switch2.Command.memory, Switch2.Subcommand.memoryRead, payload) { resp in
            guard let resp, resp.count >= 8 + Int(length),
                  resp[resp.startIndex] == length else {
                completion(nil); return
            }
            completion(resp.subdata(in: resp.startIndex + 8 ..< resp.endIndex))
        }
    }

    private func setPlayerLEDs(_ completion: @escaping (Bool) -> Void = { _ in }) {
        let pattern = Switch2.ledPatterns[min(max(slot, 0), 7)]
        writeCommand(Switch2.Command.leds, Switch2.Subcommand.ledsSetPlayer,
                     Data([pattern, 0, 0, 0])) { resp in
            completion(resp != nil)
        }
    }

    // MARK: - Keep-alive + rumble (shared 50 ms cadence)

    func setRumble(strong: Double, weak: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.rumbleTarget = (strong, weak)
            self.rumbleSetAt = CFAbsoluteTimeGetCurrent()
        }
    }

    private func startKeepAlive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.maintainTick() }
        timer.resume()
        keepAliveTimer = timer
    }

    private func maintainTick() {
        let now = CFAbsoluteTimeGetCurrent()
        var (strong, weakMag) = rumbleTarget
        // Failsafe: rumble intents expire after 0.5 s so a crashed consumer
        // can never leave the motor running.
        if now - rumbleSetAt > 0.5 { strong = 0; weakMag = 0 }

        if strong > 0.001 || weakMag > 0.001 || rumbleActive {
            let active = strong > 0.001 || weakMag > 0.001
            writeMotor(Switch2.Vibration.waveform(strong: strong, weak: weakMag))
            rumbleActive = active
            return
        }
        // Idle: the 1 Hz keep-alive that stops macOS terminating the link.
        if now - lastWriteAt >= 1.0, pendingCommand == nil {
            setPlayerLEDs()
        }
    }

    private func writeMotor(_ vib: Switch2.Vibration) {
        guard let motor = chars[Switch2.GATT.vibration(for: model)] else { return }
        let packet = Switch2.motorPacket(vib, packetID: vibrationPacketID, model: model)
        vibrationPacketID &+= 1
        peripheral.writeValue(packet, for: motor, type: .withoutResponse)
        lastWriteAt = CFAbsoluteTimeGetCurrent()
    }

    // MARK: - Input reports

    private func handleInputReport(_ data: Data) {
        guard let report = Switch2.InputReport(data: data) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if lastReportAt > 0, now - lastReportAt > 0.100 {
            gapCount += 1
            log(.warning, "slot \(slot + 1): BLE input gap #\(gapCount): \(Int((now - lastReportAt) * 1000)) ms")
        }
        lastReportAt = now
        reportCount &+= 1

        var s = ControllerState()
        s.buttons = report.buttons
        s.leftStick = leftCal?.apply(report.leftStickRaw) ?? (0, 0)
        s.rightStick = rightCal?.apply(report.rightStickRaw) ?? (0, 0)
        if model.hasAnalogTriggers {
            s.leftTrigger = report.leftTriggerRaw
            s.rightTrigger = report.rightTriggerRaw
        } else {
            s.leftTrigger = report.buttons.contains(.zl) ? 255 : 0
            s.rightTrigger = report.buttons.contains(.zr) ? 255 : 0
        }
        s.batteryMillivolts = report.batteryMillivolts
        s.gyro = report.gyro
        s.accel = report.accel
        state = s
        onState?(slot, s)

        // Battery / rate refresh for the UI at ~1 Hz.
        if reportCount % 33 == 0 {
            delegate?.sessionDidUpdateState(self)
        }
    }

    private func log(_ level: LogLevel, _ message: String) {
        bridgeLog(level, "session", message)
    }
}

// MARK: - CBPeripheralDelegate

extension ControllerSession: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail("service discovery: \(error.localizedDescription)"); return }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error { fail("characteristic discovery: \(error.localizedDescription)"); return }
        for ch in service.characteristics ?? [] {
            if let uuid = UUID(uuidString: ch.uuid.uuidString) {
                chars[uuid] = ch
            }
        }
        // All three essentials present → subscribe to command responses and
        // start the handshake (services report in arbitrary order).
        if chars[Switch2.GATT.commandWrite] != nil,
           chars[Switch2.GATT.commandResponse] != nil,
           chars[Switch2.GATT.inputReport] != nil,
           !handshakeStarted {
            handshakeStarted = true
            peripheral.setNotifyValue(true, for: chars[Switch2.GATT.commandResponse]!)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            fail("notify state: \(error.localizedDescription)")
            return
        }
        let uuid = UUID(uuidString: characteristic.uuid.uuidString)
        if uuid == Switch2.GATT.commandResponse {
            runHandshake()
        } else if uuid == Switch2.GATT.inputReport {
            notifyCompletion?(true)
            notifyCompletion = nil
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let uuid = UUID(uuidString: characteristic.uuid.uuidString)
        if uuid == Switch2.GATT.inputReport {
            handleInputReport(data)
        } else if uuid == Switch2.GATT.commandResponse {
            handleCommandResponse(data)
        }
    }
}

// MARK: - Host Bluetooth adapter address

import IOBluetooth

enum HostBluetooth {
    /// The Mac's Bluetooth adapter MAC, little-endian bytes, for the
    /// protocol-level bond command. nil when unavailable.
    static var macAddressBytesLE: Data? {
        guard let addr = IOBluetoothHostController.default()?.addressAsString() else {
            return nil
        }
        let parts = addr.split(whereSeparator: { $0 == ":" || $0 == "-" })
            .compactMap { UInt8($0, radix: 16) }
        guard parts.count == 6 else { return nil }
        return Data(parts.reversed())
    }
}
