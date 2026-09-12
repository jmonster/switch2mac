#if canImport(CoreBluetooth)
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
// All CoreBluetooth callbacks and every mutable field are confined to `queue`.
// Package-only subclass hooks share that executor. Only Sendable value snapshots
// leave through ControllerEventHub; no host callbacks execute on this queue.

import Foundation
import CoreBluetooth

/// Decoded, calibrated controller state pushed to output sinks per report.


/// Called on the Bluetooth queue.
package protocol ControllerSessionDelegate: AnyObject {
    func sessionReady(_ session: ControllerSession)
    func sessionFailed(_ session: ControllerSession, reason: String)
    func sessionDidUpdateState(_ session: ControllerSession)
}

// Only a separately linked package companion may implement these queue-confined hooks.
package protocol ControllerSessionCompanion: AnyObject, Sendable {
    var isExperimentActive: Bool { get }
    func didRetire()
    func writeCapacityAvailable()
    func receivedAuxiliaryValue(uuid: UUID?, data: Data)
}

package final class ControllerSession: NSObject, @unchecked Sendable {

    package let lifetime = SessionLifetime()
    package let diagnostics: Switch2Diagnostics
    package let sensorProfile: Switch2.Feature.SensorProfile
    package var customLEDPattern: UInt8?
    package var companion: (any ControllerSessionCompanion)?
    package var isExperimentActive: Bool { companion?.isExperimentActive ?? false }
    package var isReady: Bool { readyReported && !ended }
    package var isCommandIdle: Bool { pendingCommand == nil && queuedCommands.isEmpty }
    package func didRetire() { companion?.didRetire(); companion = nil }
    package func receivedAuxiliaryValue(uuid: UUID?, data: Data) { companion?.receivedAuxiliaryValue(uuid: uuid, data: data) }
    package func writeCapacityAvailable() { companion?.writeCapacityAvailable() }

    // MARK: Configuration

    package let peripheral: CBPeripheral
    package let slot: Int                       // 0-based; player number is slot+1
    package let wasPairingMode: Bool            // Sync-held advert → write bond
    package let queue: DispatchQueue    // the central's queue
    private weak var delegate: ControllerSessionDelegate?

    // MARK: Session state (all mutated on `queue`)

    package private(set) var model: Switch2.Model = .proController2
    package private(set) var info: Switch2.ControllerInfo?
    private var leftCal: Switch2.StickCalibration?
    private var rightCal: Switch2.StickCalibration?

    package var chars: [UUID: CBCharacteristic] = [:]
    private var handshakeStarted = false
    package private(set) var ended = false
    private var handshakeComplete = false
    private var readyReported = false
    /// Command replies have no transaction sequence. Correlate all echoed
    /// fields, and never treat the observed status/error class as success.
    package struct CommandResponse: Sendable {
        package enum Kind: UInt8, Sendable { case success = 0x01, status = 0x02 }
        package let kind: Kind
        package let header: Data
        package let payload: Data
        package var command: UInt8 { header[0] }
        package var transport: UInt8 { header[2] }
        package var subcommand: UInt8 { header[3] }

        package init?(_ frame: Data) {
            guard frame.count >= 8, let kind = Kind(rawValue: frame[frame.startIndex + 1]) else { return nil }
            self.kind = kind
            self.header = Data(frame.prefix(8))
            self.payload = Data(frame.dropFirst(8))
        }
    }
    package enum CommandFailure: Error, Sendable {
        case retired, unavailable, payloadTooLarge, frameTooLarge, queueFull, timeout
        case rejected(CommandResponse)
    }
    package typealias CommandResult = Result<CommandResponse, CommandFailure>

    private struct CommandRequest {
        package let token: UInt64
        package let id: UInt8
        package let frame: Data
        package let accepts: ((Data) -> Bool)?
        package let completion: (CommandResult) -> Void
    }
    private var nextCommandToken: UInt64 = 0
    private var pendingCommand: CommandRequest?
    private var queuedCommands: [CommandRequest] = []
    private var commandSubmitted = false
    private var writeStallTimeout: DispatchWorkItem?
    private var writeStallGeneration: UInt64 = 0
    private var pendingMotor: (value: Switch2.MotorVibration, expires: TimeInterval)?
    private var warnedMotorUnavailable = false
    private var pumpingWrites = false
    private var commandNotificationsReady = false
    private var commandTimeout: DispatchWorkItem?
    private var handshakeSteps: [(String, (@escaping (Bool) -> Void) -> Void)] = []

    /// 1-based player number shown on the LEDs; the engine reassigns it when
    /// logical players shuffle (e.g. Joy-Cons link into a grip).
    package private(set) var playerNumber: Int
    private var keepAliveTimer: DispatchSourceTimer?
    package var lastWriteAt: TimeInterval = 0
    private var vibrationPacketID: UInt8 = 0
    private var rumbleTarget: (strong: Double, weak: Double) = (0, 0)
    private var rumbleSetAt: TimeInterval = 0
    private var rumbleActive = false
    private var rumbleGeneration: UInt64 = 0

    /// Latest decoded state. All reads and writes belong to the Bluetooth
    /// queue; consumers receive a Sendable value snapshot, never this storage.
    package private(set) var state = ControllerState()
    package private(set) var reportCount: UInt64 = 0
    package private(set) var lastReportAt: TimeInterval = 0
    private var gapCount = 0

    /// Last time the HUMAN did something (button/stick/trigger change) —
    /// reports stream constantly, so idleness must be judged on content.
    package private(set) var lastActivityAt: TimeInterval = ProcessInfo.processInfo.systemUptime

    /// Internal queue-confined receiver; never a host output callback.
    package var onState: (@Sendable (Int, ControllerState) -> Void)?

    package init(peripheral: CBPeripheral, slot: Int, wasPairingMode: Bool,
         queue: DispatchQueue, delegate: ControllerSessionDelegate,
         diagnostics: Switch2Diagnostics = Switch2Diagnostics(),
         sensorProfile: Switch2.Feature.SensorProfile = .compatibility) {
        self.diagnostics = diagnostics
        self.sensorProfile = sensorProfile
        self.peripheral = peripheral
        self.slot = slot
        self.playerNumber = slot + 1
        self.wasPairingMode = wasPairingMode
        self.queue = queue
        self.delegate = delegate
        super.init()
        peripheral.delegate = self
    }

    /// Engine (btQueue): update the player LEDs to a new logical number.
    package func setPlayerNumber(_ player: Int) {
        guard player != playerNumber else { return }
        playerNumber = player
        if keepAliveTimer != nil {   // only once streaming (commands live)
            setPlayerLEDs()
        }
    }

    package var displayName: String { model.displayName }
    package var serialNumber: String {
        let serial = info?.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return serial.isEmpty || serial == "?" ? "peripheral-\(peripheral.identifier.uuidString)" : serial
    }
    package var isRetired: Bool { ended }
    package var batteryMillivolts: UInt16 { state.batteryMillivolts }

    // MARK: - Handshake

    /// Called by the engine once CoreBluetooth reports the connect.
    package func begin() {
        guard !ended else { return }
        log(.info, "slot \(slot + 1): discovering services")
        peripheral.discoverServices(nil)
    }

    package func teardown() {
        guard !ended else { return }
        ended = true
        lifetime.retire()
        peripheral.delegate = nil
        notifyCompletion = nil
        handshakeSteps.removeAll()
        onState = nil
        onRSSI = nil
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        commandTimeout?.cancel()
        commandTimeout = nil
        writeStallTimeout?.cancel()
        writeStallTimeout = nil
        pendingMotor = nil
        let cancelled = (pendingCommand.map { [$0] } ?? []) + queuedCommands
        pendingCommand = nil
        commandSubmitted = false
        queuedCommands.removeAll()
        // Complete external command waiters after making retirement terminal.
        for request in cancelled { request.completion(.failure(.retired)) }
        didRetire()
    }

    private func fail(_ reason: String) {
        guard !ended else { return }
        log(.error, "slot \(slot + 1): \(reason)")
        teardown()
        delegate?.sessionFailed(self, reason: reason)
    }

    private func runHandshake() {
        guard !ended else { return }
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
        guard !ended else { return }
        guard !handshakeSteps.isEmpty else {
            handshakeComplete = true
            // Keep the existing keep-alive while awaiting the first report.
            startKeepAlive()
            if announceReady() { onState?(slot, state) }
            return
        }
        let (name, step) = handshakeSteps.removeFirst()
        step { [weak self] ok in
            guard let self, !self.ended else { return }
            if ok {
                self.advanceHandshake()
            } else {
                self.fail("handshake step '\(name)' failed")
            }
        }
    }

    /// Notification subscription alone is not usable controller input.
    @discardableResult
    private func announceReady() -> Bool {
        guard !ended, handshakeComplete, reportCount > 0, !readyReported else { return false }
        readyReported = true
        log(.info, "slot \(slot + 1): handshake and first input complete — \(displayName)")
        delegate?.sessionReady(self)
        return true
    }

    // MARK: Handshake steps

    private func stepReadInfo(_ done: @escaping (Bool) -> Void) {
        readMemory(length: 0x40, address: Switch2.Address.controllerInfo) { [weak self] data in
            guard let self, let data, let info = Switch2.ControllerInfo(memoryBlock: data),
                  info.vendorID == Switch2.nintendoVendorID, let model = info.model else {
                done(false); return
            }
            self.info = info
            self.model = model
            done(true)
        }
    }

    private func stepReadCalibration(_ done: @escaping (Bool) -> Void) {
        readStickCalibration(user: Switch2.Address.userStick1,
                             factory: Switch2.Address.factoryStick1) { [weak self] cal in
            guard let self, !self.ended else { return }
            self.leftCal = cal
            guard self.model.hasSecondStick else {
                done(true)   // single-stick unit: slot-2 holds no valid data
                return
            }
            self.readStickCalibration(user: Switch2.Address.userStick2,
                                      factory: Switch2.Address.factoryStick2) { [weak self] cal in
                guard let self, !self.ended else { return }
                self.rightCal = cal
                done(true)   // calibration is best-effort; defaults are usable
            }
        }
    }

    private func readStickCalibration(user: UInt32, factory: UInt32,
                                      _ done: @escaping (Switch2.StickCalibration?) -> Void) {
        readMemory(length: 0x0B, address: user) { [weak self] data in
            guard let self, !self.ended else { return }
            if let data, let cal = Switch2.StickCalibration(validatedData: data) {
                done(cal)
                return
            }
            self.readMemory(length: 0x0B, address: factory) { data in
                done(data.flatMap { Switch2.StickCalibration(validatedData: $0) })
            }
        }
    }

    private func stepPlayerLEDs(_ done: @escaping (Bool) -> Void) {
        setPlayerLEDs { done($0) }
    }

    private func stepFeatures(_ done: @escaping (Bool) -> Void) {
        let flags = Data([Switch2.Feature.flags(for: model, profile: sensorProfile), 0, 0, 0])
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
                        if resp != nil { self.log(.info, "protocol bond operation completed") }
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

    /// Normal callers receive a payload only for a correlated success reply.
    /// An empty LED ACK is valid; memory additionally validates length/address.
    private func writeCommand(_ command: UInt8, _ subcommand: UInt8, _ data: Data,
                              flag: UInt8 = 0x01,
                              accepts: ((Data) -> Bool)? = nil,
                              completion: @escaping (Data?) -> Void) {
        sendCommand(command, subcommand, data, flag: flag, accepts: accepts) { result in
            if case .success(let response) = result { completion(response.payload) }
            else { completion(nil) }
        }
    }

    package func sendCommand(_ command: UInt8, _ subcommand: UInt8, _ data: Data,
                             flag: UInt8 = 0x01,
                             accepts: ((Data) -> Bool)? = nil,
                             completion: @escaping (CommandResult) -> Void) {
        guard !ended else { completion(.failure(.retired)); return }
        guard chars[Switch2.GATT.commandWrite] != nil else {
            completion(.failure(.unavailable)); return
        }
        guard data.count <= Int(UInt8.max) else {
            log(.warning, "command payload exceeds the protocol length field")
            completion(.failure(.payloadTooLarge)); return
        }
        let frame = Switch2.buildCommand(command, subcommand, flag: flag, data: data)
        guard frame.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
            log(.warning, "command exceeds negotiated write size; not fragmenting protocol frames")
            completion(.failure(.frameTooLarge)); return
        }
        guard queuedCommands.count + (pendingCommand == nil ? 0 : 1) < 32 else {
            log(.error, "command queue exhausted")
            fail("command queue exhausted")
            completion(.failure(.queueFull))
            return
        }
        nextCommandToken &+= 1
        queuedCommands.append(CommandRequest(token: nextCommandToken, id: command,
                                               frame: frame, accepts: accepts,
                                               completion: completion))
        pumpWrites()
    }

    /// Queue-confined: command frames remain atomic and FIFO. Motor intents
    /// may be replaced, but controller input reports are never coalesced here.
    package func pumpWrites() {
        guard !ended, !pumpingWrites else { return }
        pumpingWrites = true
        defer { pumpingWrites = false }
        if pendingCommand == nil, !queuedCommands.isEmpty {
            pendingCommand = queuedCommands.removeFirst()
            commandSubmitted = false
        }
        let waiting = (pendingCommand != nil && !commandSubmitted) || pendingMotor != nil
        guard waiting else { return }
        guard peripheral.canSendWriteWithoutResponse else {
            armWriteStallDeadline()
            return
        }
        writeStallTimeout?.cancel()
        writeStallTimeout = nil
        // Rumble stop/replacement must not wait for a command response.
        if let motor = pendingMotor, let characteristic = chars[Switch2.GATT.vibration(for: model)] {
            let value = ProcessInfo.processInfo.systemUptime < motor.expires
                ? motor.value : Switch2.MotorVibration.stopped
            let packet = Switch2.motorPacket(value, packetID: vibrationPacketID, model: model)
            if packet.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) {
                peripheral.writeValue(packet, for: characteristic, type: .withoutResponse)
                vibrationPacketID &+= 1
                lastWriteAt = ProcessInfo.processInfo.systemUptime
            }
            pendingMotor = nil
        }
        if pendingCommand != nil && !commandSubmitted && !peripheral.canSendWriteWithoutResponse {
            armWriteStallDeadline()
        }
        if let request = pendingCommand, !commandSubmitted,
           peripheral.canSendWriteWithoutResponse, let writeChar = chars[Switch2.GATT.commandWrite] {
            commandSubmitted = true
            // The response deadline starts at submission, not while waiting
            // for another command or for CoreBluetooth's outbound buffer.
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, !self.ended, self.pendingCommand?.token == request.token else { return }
                self.pendingCommand = nil
                self.commandSubmitted = false
                self.commandTimeout = nil
                // There is no sequence field to distinguish a late response
                // from a later identical command. Retire the stream before
                // notifying waiters, rather than misattributing a delayed ACK.
                self.fail("command \(String(format: "%#04x/%#04x", request.id, request.frame[3])) timed out")
                request.completion(.failure(.timeout))
            }
            commandTimeout = timeout
            queue.asyncAfter(deadline: .now() + 2, execute: timeout)
            peripheral.writeValue(request.frame, for: writeChar, type: .withoutResponse)
            lastWriteAt = ProcessInfo.processInfo.systemUptime
        }
    }

    private func armWriteStallDeadline() {
        guard writeStallTimeout == nil else { return }
        writeStallGeneration &+= 1
        let generation = writeStallGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.ended, self.writeStallTimeout != nil,
                  self.writeStallGeneration == generation else { return }
            self.writeStallTimeout = nil
            self.fail("Bluetooth write capacity unavailable for 5 seconds")
        }
        writeStallTimeout = work
        queue.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func handleCommandResponse(_ data: Data) {
        // A malformed, unrelated or not-yet-submitted reply must not consume
        // the current command/deadline. Sliced Data need not start at index 0.
        guard !ended, commandSubmitted, let pending = pendingCommand,
              let response = CommandResponse(data),
              response.command == pending.id,
              response.transport == pending.frame[2],
              response.subcommand == pending.frame[3] else { return }
        // A rejection need not include a memory result/address. Deliver it
        // immediately rather than leaving the request to time out. A success
        // must satisfy any command-specific payload correlation predicate.
        if response.kind == .success, !(pending.accepts?(response.payload) ?? true) { return }
        commandTimeout?.cancel()
        commandTimeout = nil
        pendingCommand = nil
        commandSubmitted = false
        if response.kind == .success {
            pending.completion(.success(response))
        } else {
            log(.warning, "command \(String(format: "%#04x/%#04x", pending.id, pending.frame[3])) returned status/error")
            pending.completion(.failure(.rejected(response)))
        }
        // State was cleared before callback: teardown or a reentrant enqueue
        // cannot be erased by completion of the preceding transaction.
        pumpWrites()
    }

    private func readMemory(length: UInt8, address: UInt32,
                            completion: @escaping (Data?) -> Void) {
        let payload = Switch2.memoryReadPayload(length: length, address: address)
        writeCommand(Switch2.Command.memory, Switch2.Subcommand.memoryRead, payload,
                     accepts: { response in
            response.count >= 8 + Int(length) && response[response.startIndex] == length
                && Switch2.u32(response, 4) == address
        }) { resp in
            guard let resp, resp.count >= 8 + Int(length),
                  resp[resp.startIndex] == length,
                  Switch2.u32(resp, 4) == address else {
                completion(nil); return
            }
            completion(resp.subdata(in: resp.startIndex + 8 ..< resp.endIndex))
        }
    }

    private func setPlayerLEDs(_ completion: @escaping (Bool) -> Void = { _ in }) {
        let pattern = customLEDPattern ?? Switch2.ledPatterns[min(max(playerNumber - 1, 0), 7)]
        writeCommand(Switch2.Command.leds, Switch2.Subcommand.ledsSetPlayer,
                     Data([pattern, 0, 0, 0])) { resp in
            completion(resp != nil)
        }
    }

    /// Directly drive the four player LEDs (bit 0..3). For Find-My flashing;
    /// bypasses persisted patterns. Restores normal LEDs when `nil`.
    package func setRawLEDs(_ pattern: UInt8?) {
        queue.async { [weak self] in
            guard let self, !self.ended else { return }
            if let pattern {
                self.writeCommand(Switch2.Command.leds, Switch2.Subcommand.ledsSetPlayer,
                                  Data([pattern, 0, 0, 0])) { _ in }
            } else {
                self.setPlayerLEDs()
            }
        }
    }

    /// Refresh LEDs now (e.g., after the user changes the custom pattern).
    package func refreshLEDs() {
        queue.async { [weak self] in self?.setPlayerLEDs() }
    }

    /// Read the current RSSI; result arrives via the rssi callback.
    package var onRSSI: ((Int) -> Void)?
    package func requestRSSI() {
        queue.async { [weak self] in
            guard let self, !self.ended else { return }
            self.peripheral.readRSSI()
        }
    }

    // MARK: - Keep-alive + rumble

    package func setRumble(strong: Double, weak: Double) {
        queue.async { [weak self] in self?.applyRumble(strong: strong, weak: weak) }
    }

    package func applyRumble(strong: Double, weak: Double) {
        guard !ended else { return }
        rumbleGeneration &+= 1
        rumbleTarget = (strong.isFinite ? max(0, min(1, strong)) : 0,
                        weak.isFinite ? max(0, min(1, weak)) : 0)
        rumbleSetAt = ProcessInfo.processInfo.systemUptime
        maintainTick()
    }

    /// Direct diagnostic, independent of player assignment or game output.
    /// GameCube clips finish in firmware: they are not duration-controlled
    /// effects and must not be advertised as general game-rumble support.


    package func pulseRumble(strong: Double, weak: Double = 0, duration: Double) {
        queue.async { [weak self] in
            self?.applyRumblePulse(strong: strong, weak: weak, duration: duration)
        }
    }

    /// Queue-confined so a direct test cannot jump ahead of a newer game
    /// request by enqueueing a second hop onto the same Bluetooth queue.
    package func applyRumblePulse(strong: Double, weak: Double, duration: Double) {
        guard !ended, duration.isFinite else { return }
        applyRumble(strong: strong, weak: weak)
        let generation = rumbleGeneration
        queue.asyncAfter(deadline: .now() + max(0, min(5, duration))) { [weak self] in
            guard let self, !self.ended, self.rumbleGeneration == generation else { return }
            self.applyRumble(strong: 0, weak: 0)
        }
    }

    private func startKeepAlive() {
        guard !ended, keepAliveTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1)
        timer.setEventHandler { [weak self] in self?.maintainTick() }
        timer.resume()
        keepAliveTimer = timer
    }

    private func maintainTick() {
        guard !ended else { return }
        defer {
            // One deadline while idle, sustain cadence only while rumbling.
            let active = rumbleActive || pendingMotor != nil
            let delay = active ? 0.05 : max(0.05, 1 - (ProcessInfo.processInfo.systemUptime - lastWriteAt))
            keepAliveTimer?.schedule(deadline: .now() + delay, leeway: .milliseconds(2))
        }
        let now = ProcessInfo.processInfo.systemUptime
        var (strong, weakMag) = rumbleTarget
        // Failsafe: rumble intents expire after 0.5 s so a crashed consumer
        // can never leave the motor running.
        if now - rumbleSetAt > 0.5 { strong = 0; weakMag = 0 }

        // The GameCube model explicitly lacks this motor protocol. Do not
        // suppress its LED keep-alive when an unsupported rumble is requested.
        if model.hasHDRumble && (strong > 0.001 || weakMag > 0.001 || rumbleActive) {
            let active = strong > 0.001 || weakMag > 0.001
            if writeMotor(Switch2.MotorVibration.waveform(strong: strong, weak: weakMag, model: model)) {
                rumbleActive = active
                return
            }
            // Missing characteristic / insufficient MTU is not an input failure.
            // Keep the link alive even when a game continuously requests rumble.
            rumbleActive = false
        }
        // Idle: the 1 Hz keep-alive that stops macOS terminating the link.
        if now - lastWriteAt >= 1.0, pendingCommand == nil {
            setPlayerLEDs()
        }
    }

    @discardableResult
    package func writeMotor(_ vib: Switch2.Vibration) -> Bool {
        writeMotor(Switch2.MotorVibration(vib))
    }

    @discardableResult
    private func writeMotor(_ motors: Switch2.MotorVibration) -> Bool {
        guard !ended, model.hasHDRumble else { return false }
        let size = Switch2.motorPacket(motors, packetID: 0, model: model).count
        guard chars[Switch2.GATT.vibration(for: model)] != nil,
              size <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
            if !warnedMotorUnavailable {
                log(.warning, "rumble unavailable: missing motor characteristic or write size below \(size) bytes")
                warnedMotorUnavailable = true
            }
            pendingMotor = nil
            return false
        }
        warnedMotorUnavailable = false
        pendingMotor = (motors, ProcessInfo.processInfo.systemUptime + 0.5)
        pumpWrites()
        return true
    }

    // MARK: - Input reports

    /// Nominal 12-bit range only when factory/user calibration is unavailable.
    /// This is degraded, uncalibrated input, not a claim of factory accuracy.
    private static func uncalibratedStick(_ raw: (UInt16, UInt16)) -> (Double, Double) {
        func axis(_ value: UInt16) -> Double {
            let offset = Double(value) - 2048
            return max(-1, min(1, offset / (offset >= 0 ? 2047 : 2048)))
        }
        return (axis(raw.0), axis(raw.1))
    }

    private func handleInputReport(_ data: Data) {
        guard !ended, let report = Switch2.InputReport(data: data) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if lastReportAt > 0, now - lastReportAt > 0.100 {
            gapCount += 1
            log(.warning, "slot \(slot + 1): BLE input gap #\(gapCount): \(Int((now - lastReportAt) * 1000)) ms")
        }
        lastReportAt = now
        reportCount &+= 1

        var s = ControllerState()
        s.buttons = report.buttons
        switch model {
        case .joyCon2Left:
            // One stick, reporting in the first field, calibrated by slot 1.
            s.leftStick = leftCal?.apply(report.leftStickRaw) ?? Self.uncalibratedStick(report.leftStickRaw)
        case .joyCon2Right:
            // One stick, reporting in the SECOND field — but calibrated by
            // the unit's slot-1 data (a Joy-Con has no slot-2 calibration).
            s.rightStick = leftCal?.apply(report.rightStickRaw) ?? Self.uncalibratedStick(report.rightStickRaw)
        default:
            s.leftStick = leftCal?.apply(report.leftStickRaw) ?? Self.uncalibratedStick(report.leftStickRaw)
            s.rightStick = rightCal?.apply(report.rightStickRaw) ?? Self.uncalibratedStick(report.rightStickRaw)
        }
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
        s.mouseX = report.mouseX
        s.mouseY = report.mouseY
        s.surfaceQuality = report.surfaceQuality
        s.liftDistance = report.liftDistance
        s.mag = report.mag
        s.chargeState = report.chargeState
        s.batteryCurrent = report.batteryCurrent
        s.temperatureC = 25.0 + Double(report.temperatureRaw) / 127.0

        // Activity: any button change, meaningful stick deflection change,
        // or trigger change counts. (Gyro noise deliberately excluded.)
        let old = state
        if !s.buttons.isEmpty || s.leftTrigger > 0 || s.rightTrigger > 0
            || abs(s.leftStick.x) > 0.15 || abs(s.leftStick.y) > 0.15
            || abs(s.rightStick.x) > 0.15 || abs(s.rightStick.y) > 0.15
            || s.buttons != old.buttons
            || abs(s.leftStick.x - old.leftStick.x) > 0.1
            || abs(s.leftStick.y - old.leftStick.y) > 0.1
            || abs(s.rightStick.x - old.rightStick.x) > 0.1
            || abs(s.rightStick.y - old.rightStick.y) > 0.1
            || s.leftTrigger != old.leftTrigger
            || s.rightTrigger != old.rightTrigger {
            lastActivityAt = now
        }

        state = s
        announceReady()
        onState?(slot, s)

        // Battery / rate refresh for the UI at ~1 Hz.
        if reportCount % 33 == 0 {
            delegate?.sessionDidUpdateState(self)
        }
    }

    package func log(_ level: Switch2LogLevel, _ message: String) {
        diagnostics.emit(level, .session, message)
    }
}

// MARK: - CBPeripheralDelegate

extension ControllerSession: CBPeripheralDelegate {

    package func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !ended else { return }
        if error != nil { fail("service discovery failed"); return }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    package func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard !ended else { return }
        if error != nil { fail("characteristic discovery failed"); return }
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

    package func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard !ended else { return }
        let uuid = UUID(uuidString: characteristic.uuid.uuidString)
        if error != nil {
            // Only the essential channels are fatal — an experimental
            // (promiscuous) subscribe may legitimately be refused.
            if uuid == Switch2.GATT.commandResponse || uuid == Switch2.GATT.inputReport {
                fail("essential notification subscription failed")
            } else {
                log(.debug, "optional notification subscription refused")
            }
            return
        }
        if uuid == Switch2.GATT.commandResponse || uuid == Switch2.GATT.inputReport {
            guard characteristic.isNotifying else { fail("essential notifications stopped"); return }
        }
        if uuid == Switch2.GATT.commandResponse {
            guard !commandNotificationsReady else { return }
            commandNotificationsReady = true
            runHandshake()
        } else if uuid == Switch2.GATT.inputReport {
            let completion = notifyCompletion
            notifyCompletion = nil
            completion?(true)
        }
    }

    package func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if !ended, error == nil { onRSSI?(RSSI.intValue) }
    }

    /// Outbound buffer has space again; resume bounded protocol and optional companion writes.
    package func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpWrites()
        writeCapacityAvailable()
    }

    package func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard !ended, invalidatedServices.contains(where: { service in
            (service.characteristics ?? []).contains { ch in chars.values.contains { $0 === ch } }
        }) else { return }
        fail("controller services changed; reconnect required")
    }

    package func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard !ended, error == nil, let data = characteristic.value else { return }
        let uuid = UUID(uuidString: characteristic.uuid.uuidString)
        if uuid == Switch2.GATT.inputReport {
            handleInputReport(data)
        } else if uuid == Switch2.GATT.commandResponse {
            handleCommandResponse(data)
        } else {
            receivedAuxiliaryValue(uuid: uuid, data: data)
        }
    }
}

// MARK: - Host Bluetooth adapter address

import IOBluetooth

enum HostBluetooth {
    /// The Mac's Bluetooth adapter MAC, little-endian bytes, for the
    /// protocol-level bond command. nil when unavailable.
    package static var macAddressBytesLE: Data? {
        guard let addr = IOBluetoothHostController.default()?.addressAsString() else {
            return nil
        }
        let parts = addr.split(whereSeparator: { $0 == ":" || $0 == "-" })
            .compactMap { UInt8($0, radix: 16) }
        guard parts.count == 6 else { return nil }
        return Data(parts.reversed())
    }
}

#endif
