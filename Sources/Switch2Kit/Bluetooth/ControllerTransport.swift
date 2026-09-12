#if canImport(CoreBluetooth)
import Foundation
import CoreBluetooth
import Synchronization

// Sole production owner of CoreBluetooth and physical sessions. Every mutable field
// below is confined to btQueue. Public commands enqueue onto it; callbacks never
// pass a peripheral, session or mutable collection to host application code.
package final class ControllerTransport: NSObject, @unchecked Sendable {
    package let btQueue = DispatchQueue(label: "Switch2Kit.bluetooth")
    private struct RumbleIntent: Sendable {
        let strong: Double
        let weak: Double
        let duration: TimeInterval?
        let submittedAt: TimeInterval
        let generation: UUID?
    }
    private struct RumbleInbox: Sendable {
        var pending: [Switch2ControllerID: RumbleIntent] = [:]
        var scheduled = false
    }
    private let rumbleInbox = Mutex(RumbleInbox())
    private let hub: ControllerEventHub
    private let diagnostics: Switch2Diagnostics
    private let configuration: Switch2ControllerConfiguration
    private let sessionLimit: Int
    private var central: CBCentralManager!
    private var running = false
    private var suspended = false
    private var disconnecting = Set<UUID>()
    private var deadlines: [UUID: DispatchWorkItem] = [:]
    private var retryAfter: [UUID: TimeInterval] = [:]
    private struct RetryAdvertisement {
        let peripheral: CBPeripheral
        let wasPairingMode: Bool
        let expiresAt: TimeInterval
    }
    private var retryAdvertisements: [UUID: RetryAdvertisement] = [:]
    private var retryWake: DispatchWorkItem?
    private var retryWakeAt: TimeInterval?
    private var retryWakeGeneration: UInt64 = 0
    private var retryBlockedUntil: TimeInterval = 0
    private var sessions: [Int: ControllerSession] = [:]
    private var connecting: [UUID: (session: ControllerSession, slot: Int)] = [:]
    private var connectedAt: [Int: Date] = [:]
    private var currentControllers: [UUID: Switch2Controller] = [:]
    private var idleSweepTimer: DispatchSourceTimer?
    private var bluetoothState: Switch2BluetoothState = .unknown
    private var discoveryState: Switch2DiscoveryState = .stopped
    private enum ScanPhase { case paused, off, unauthorized, scanning, connecting, idle, ready }
    private lazy var discovery = ControllerDiscoveryPolicy(queue: btQueue,
        mode: configuration.discoveryMode, remembered: configuration.rememberedControllers.map(\.rawValue),
        capacity: sessionLimit) { [weak self] in self?.updateScanning() }
    // Package-only extension point, installed before start. No stable API exposes a session.
    package var attachCompanion: (@Sendable (ControllerSession) -> Void)?
    package var sensorProfile: Switch2.Feature.SensorProfile = .compatibility

    package init(configuration: Switch2ControllerConfiguration, hub: ControllerEventHub, diagnostics: Switch2Diagnostics) {
        self.configuration = configuration; self.hub = hub; self.diagnostics = diagnostics
        self.sessionLimit = min(64, max(1, configuration.maximumControllers))
        super.init()
    }
    package func submitRumble(_ id: Switch2ControllerID, strong: Double, weak: Double, duration: TimeInterval?) {
        let schedule = rumbleInbox.withLock { inbox in
            guard inbox.pending[id] != nil || inbox.pending.count < 64 else { return false }
            inbox.pending[id] = RumbleIntent(strong: strong, weak: weak, duration: duration,
                                            submittedAt: ProcessInfo.processInfo.systemUptime,
                                            generation: hub.snapshot.controllers.first { $0.id == id }?.sessionGeneration)
            guard !inbox.scheduled else { return false }
            inbox.scheduled = true; return true
        }
        if schedule { btQueue.async { [weak self] in self?.drainRumble() } }
    }
    private func drainRumble() {
        let intents = rumbleInbox.withLock { inbox in
            let result = inbox.pending; inbox.pending.removeAll(keepingCapacity: true)
            inbox.scheduled = false; return result
        }
        for (id, intent) in intents {
            guard let session = sessions.values.first(where: { $0.peripheral.identifier == id.rawValue }),
                  !session.isRetired else { failure(id, .controllerNotReady); continue }
            guard intent.generation == session.lifetime.id else { continue }
            guard session.model.hasHDRumble else { failure(id, .unsupportedOperation); continue }
            guard ProcessInfo.processInfo.systemUptime - intent.submittedAt < 0.5 else {
                session.applyRumble(strong: 0, weak: 0); continue
            }
            if let duration = intent.duration {
                session.applyRumblePulse(strong: intent.strong, weak: intent.weak, duration: duration)
            } else { session.applyRumble(strong: intent.strong, weak: intent.weak) }
        }
    }
    package func installCompanion(_ attach: @escaping @Sendable (ControllerSession) -> Void) {
        btQueue.async { [weak self] in
            guard let self, !self.running, self.attachCompanion == nil else { return }
            self.attachCompanion = attach
        }
    }
    package func setSensorProfile(_ profile: Switch2.Feature.SensorProfile) {
        btQueue.async { [weak self] in self?.sensorProfile = profile }
    }
    package func start() {
        btQueue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            if self.central == nil { self.central = CBCentralManager(delegate: self, queue: self.btQueue) }
            self.updateScanning()
            self.publishManagerStatus()
        }
    }
    package func stop(completion: (@Sendable () -> Void)? = nil) {
        btQueue.async { [self] in
            running = false
            rumbleInbox.withLock { $0.pending.removeAll() }
            if central != nil { resetConnections(cancel: true, reason: .stopped) }
            publishState(.paused)
            // A continuation or host completion is never executed on the Bluetooth callback queue.
            if let completion { DispatchQueue.global(qos: .userInitiated).async(execute: completion) }
        }
    }
    package func shutdown() {
        btQueue.async { [self] in
            running = false
            rumbleInbox.withLock { $0.pending.removeAll() }
            if central != nil { resetConnections(cancel: true, reason: .stopped) }
            central?.delegate = nil; central = nil
            hub.cancelAll()
        }
    }
    package func requestDiscoveryWindow(seconds: TimeInterval) {
        btQueue.async { [weak self] in
            guard let self, self.running, !self.suspended else { return }
            guard self.discovery.openWindow(seconds: seconds) else { self.failure(nil, .invalidParameter); return }
            self.updateScanning()
        }
    }
    package func configureDiscovery(mode: Switch2DiscoveryMode, remembered: [Switch2ControllerID]) {
        let limited = Array(remembered.prefix(64))
        btQueue.async { [weak self] in
            guard let self else { return }
            self.discovery.configure(mode: mode, remembered: limited.map(\.rawValue))
            if self.central != nil { self.updateScanning() }
            else { self.publishManagerStatus() }
        }
    }
    package func useConnectedForDiscovery() {
        btQueue.async { [weak self] in
            guard let self, self.running else { return }
            self.discovery.useConnected(self.sessions.values.map { $0.peripheral.identifier })
            self.updateScanning()
        }
    }
    package func disconnect(_ id: Switch2ControllerID, forget: Bool) {
        btQueue.async { [weak self] in
            guard let self else { return }
            if forget {
                self.discovery.forget(id.rawValue)

            }
            if let session = self.sessions.values.first(where: { $0.peripheral.identifier == id.rawValue })
                ?? self.connecting[id.rawValue]?.session {
                self.retire(session, cancel: true, reason: forget ? .forgotten : .requested)
            }
            if self.central != nil { self.updateScanning() }
            else { self.publishManagerStatus() }
        }
    }
    // Only package companion operations may use this queue-confined seam.
    package func withSession(_ id: Switch2ControllerID, operation: @escaping @Sendable (ControllerSession) -> Void) {
        btQueue.async { [weak self] in
            guard let self else { return }
            guard let session = self.sessions.values.first(where: { $0.peripheral.identifier == id.rawValue }),
                  !session.isRetired else { self.failure(id, .controllerNotReady); return }
            operation(session)
        }
    }
    package func failure(_ id: Switch2ControllerID?, _ error: Switch2KitError) {
        hub.publish(snapshot(), event: .failure(id, error))
    }
    private func snapshot() -> Switch2ManagerSnapshot {
        Switch2ManagerSnapshot(isRunning: running, bluetooth: bluetoothState, discovery: discoveryState,
            controllers: currentControllers.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString },
            rememberedControllers: discovery.remembered.map { Switch2ControllerID(rawValue: $0) })
    }
    private func controllerSnapshot(_ session: ControllerSession) -> Switch2Controller {
        let info = session.info
        return Switch2Controller(id: .init(rawValue: session.peripheral.identifier), model: session.model,
            state: session.state.snapshot(model: session.model, receivedAt: session.lastReportAt, sensorProfile: session.sensorProfile, sequence: session.reportCount),
            connectedAt: connectedAt[session.slot] ?? Date(),
            bodyColor: info.map { .init(red: $0.bodyColor.0, green: $0.bodyColor.1, blue: $0.bodyColor.2) },
            buttonColor: info.map { .init(red: $0.buttonColor.0, green: $0.buttonColor.1, blue: $0.buttonColor.2) },
            serialNumber: configuration.includeSerialNumbers ? session.serialNumber : nil,
            sessionGeneration: session.lifetime.id, lastActivityAt: session.lastActivityAt)
    }
    private func emitState(slot: Int, state: ControllerState) {
        guard let session = sessions[slot], !session.isRetired else { return }
        let controller = controllerSnapshot(session)
        currentControllers[session.peripheral.identifier] = controller
        hub.publish(snapshot(), event: .input(controller), lifetime: session.lifetime)
    }
    private func publishManagerStatus() {
        let value = snapshot()
        if hub.snapshot != value { hub.publish(value, event: .status(value)) }
    }
    private func publishState(_ phase: ScanPhase) {
        switch phase {
        case .paused, .off, .unauthorized: discoveryState = .stopped
        case .scanning: discoveryState = .scanning(until: discovery.deadline)
        case .connecting: discoveryState = .connecting
        case .idle: discoveryState = .capacityReached
        case .ready: discoveryState = .paused
        }
        publishManagerStatus()
    }
    private func bridgeLog(_ level: Switch2LogLevel, _ category: String, _ message: String) {
        diagnostics.emit(level, .bluetooth, message)
    }

    private func owns(_ session: ControllerSession) -> Bool {
        sessions[session.slot] === session || connecting[session.peripheral.identifier]?.session === session
    }

    private func retire(_ session: ControllerSession, cancel: Bool, recompute: Bool = true, reason: Switch2DisconnectionReason = .linkLost) {
        guard owns(session) else { return }
        let id = session.peripheral.identifier
        if connecting[id]?.session === session { connecting.removeValue(forKey: id) }
        if sessions[session.slot] === session { sessions.removeValue(forKey: session.slot) }
        deadlines.removeValue(forKey: id)?.cancel()
        connectedAt.removeValue(forKey: session.slot)
        retryAdvertisements.removeValue(forKey: id)
        session.teardown()
        currentControllers.removeValue(forKey: id)
        hub.publish(snapshot(), event: .disconnected(.init(rawValue: id), reason))
        if cancel {
            disconnecting.insert(id)
            central.cancelPeripheralConnection(session.peripheral)
        }
        updateIdleSweep()
        if recompute { publishManagerStatus(); updateScanning() }
    }

    private func resetConnections(cancel: Bool, reason: Switch2DisconnectionReason = .stopped) {
        resetConnectionRetries()
        discovery.cancelWindow()
        central.stopScan()
        let current = Array(sessions.values) + connecting.values.map { $0.session }
        for session in current { retire(session, cancel: cancel, recompute: false, reason: reason) }
        if !cancel { disconnecting.removeAll() }
        publishManagerStatus()
    }

    private func armDeadline(_ session: ControllerSession, seconds: Double) {
        let id = session.peripheral.identifier
        deadlines.removeValue(forKey: id)?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, self.connecting[id]?.session === session else { return }
            self.bridgeLog(.warning, "engine", "connection phase timed out; retiring attempt")
            self.noteConnectionFailure(id)
            self.failure(.init(rawValue: id), .timedOut)
            self.retire(session, cancel: true, reason: .timeout)
            self.updateScanning()
        }
        deadlines[id] = work
        btQueue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func noteConnectionFailure(_ id: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        retryAfter = retryAfter.filter { $0.value > now || disconnecting.contains($0.key) }
        retryAdvertisements = retryAdvertisements.filter { $0.value.expiresAt > now }
        retryAdvertisements.removeValue(forKey: id)
        if retryAfter[id] == nil && retryAfter.count >= sessionLimit * 8 {
            // Fail closed under exceptional churn: one global two-second
            // cooldown, no unbounded dictionary and no per-device timers.
            retryBlockedUntil = max(retryBlockedUntil, now + 2)
        } else {
            retryAfter[id] = now + 2
        }
    }

    private func cancelRetryWake() {
        retryWakeGeneration &+= 1
        retryWake?.cancel(); retryWake = nil; retryWakeAt = nil
    }

    private func resetConnectionRetries() {
        cancelRetryWake()
        retryAfter.removeAll(); retryAdvertisements.removeAll()
        retryBlockedUntil = 0
    }

    private func armRetryWake() {
        guard running, !suspended, central.state == .poweredOn,
              connecting.isEmpty, central.isScanning else { cancelRetryWake(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let future = Array(retryAfter.values) + [retryBlockedUntil]
        guard let deadline = future.filter({ $0 > now }).min() else { cancelRetryWake(); return }
        guard retryWake == nil || retryWakeAt != deadline else { return }
        cancelRetryWake()
        let generation = retryWakeGeneration
        let work = DispatchWorkItem { [weak self] in self?.wakeConnectionRetries(generation: generation) }
        retryWake = work; retryWakeAt = deadline
        btQueue.asyncAfter(deadline: .now() + max(0, deadline - now), execute: work)
    }

    private func wakeConnectionRetries(generation: UInt64) {
        guard generation == retryWakeGeneration, retryWake != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let deadline = retryWakeAt
        retryWake = nil; retryWakeAt = nil
        guard running, !suspended, central.state == .poweredOn else { resetConnectionRetries(); return }
        if let deadline, now < deadline { armRetryWake(); return }
        retryAfter = retryAfter.filter { $0.value > now || disconnecting.contains($0.key) }
        if retryBlockedUntil <= now { retryBlockedUntil = 0 }
        // Duplicate filtering may have consumed the only wake advertisement.
        // Cached, validated advertisements are retried directly below. Without
        // one, a single fresh scan permits rediscovery; duplicates stay disabled.
        if central.isScanning { central.stopScan() }
        updateScanning()
    }

    private func beginConnection(_ peripheral: CBPeripheral, wasPairingMode: Bool) -> Bool {
        let id = peripheral.identifier
        let now = ProcessInfo.processInfo.systemUptime
        guard running, !suspended, central.state == .poweredOn, connecting.isEmpty,
              !disconnecting.contains(id), now >= retryBlockedUntil,
              now >= (retryAfter[id] ?? 0),
              !sessions.values.contains(where: { $0.peripheral.identifier == id }),
              let slot = freeSlot() else { return false }
        retryAfter.removeValue(forKey: id); retryAdvertisements.removeValue(forKey: id)
        cancelRetryWake()
        let session = ControllerSession(peripheral: peripheral, slot: slot,
                                        wasPairingMode: wasPairingMode, queue: btQueue, delegate: self, diagnostics: diagnostics, sensorProfile: sensorProfile)
        attachCompanion?(session)
        connecting[id] = (session, slot)
        central.stopScan()
        publishState(.connecting)
        hub.publish(snapshot(), event: .connectionChanged(.init(rawValue: id), .connecting), lifetime: session.lifetime)
        central.connect(peripheral, options: nil)
        armDeadline(session, seconds: 10)
        return true
    }

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

    private func updateScanning() {
        guard central != nil else { return }
        guard running, !suspended else {
            central.stopScan(); resetConnectionRetries(); publishState(.paused); return
        }
        guard central.state == .poweredOn else { resetConnectionRetries(); publishState(.off); return }
        let now = ProcessInfo.processInfo.systemUptime
        retryAdvertisements = retryAdvertisements.filter { $0.value.expiresAt > now }
        // Complete one connection/handshake before admitting another. Existing
        // ready sessions continue delivering input while a retry waits.
        guard connecting.isEmpty else {
            central.stopScan(); cancelRetryWake(); publishState(.connecting); return
        }
        let occupied = sessions.count
        let shouldDiscover = discovery.shouldScan(readyIDs: sessions.values.map { $0.peripheral.identifier })
        if occupied < sessionLimit && shouldDiscover {
            for (id, advertisement) in retryAdvertisements.sorted(by: {
                if $0.value.expiresAt != $1.value.expiresAt { return $0.value.expiresAt < $1.value.expiresAt }
                return $0.key.uuidString < $1.key.uuidString
            }) where now >= (retryAfter[id] ?? 0) && !disconnecting.contains(id) {
                if beginConnection(advertisement.peripheral, wasPairingMode: advertisement.wasPairingMode) { return }
            }
            if !central.isScanning {
                central.scanForPeripherals(withServices: nil, options: [
                    CBCentralManagerScanOptionAllowDuplicatesKey: false
                ])
            }
            publishState(.scanning)
            armRetryWake()
        } else {
            if central.isScanning { central.stopScan() }
            if !shouldDiscover { retryAdvertisements.removeAll() }
            cancelRetryWake()
            publishState(occupied >= sessionLimit ? .idle : .ready)
        }
    }

    private func freeSlot() -> Int? {
        for slot in 0..<sessionLimit
        where sessions[slot] == nil && !connecting.values.contains(where: { $0.slot == slot }) {
            return slot
        }
        return nil
    }

    private func sweepIdleSessions() {
        guard running, !suspended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for session in Array(sessions.values) {
            if !session.isExperimentActive && now - session.lastReportAt > 5 {
                diagnostics.emit(.warning, .session, "Input stream stopped; retiring stale session")
                failure(.init(rawValue: session.peripheral.identifier), .timedOut)
                retire(session, cancel: true, reason: .timeout)
            }
        }
    }
}

extension ControllerTransport: CBCentralManagerDelegate {

    package func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        switch central.state {
        case .unknown: bluetoothState = .unknown
        case .resetting: bluetoothState = .resetting
        case .unsupported: bluetoothState = .unsupported
        case .unauthorized: bluetoothState = .unauthorized
        case .poweredOff: bluetoothState = .poweredOff
        case .poweredOn: bluetoothState = .poweredOn
        @unknown default: bluetoothState = .unknown
        }
        switch central.state {
        case .poweredOn:
            bridgeLog(.info, "engine", "Bluetooth ready")
            updateScanning()
        case .unauthorized:
            resetConnections(cancel: false, reason: .bluetoothUnavailable)
            bridgeLog(.error, "engine",
                      "Bluetooth permission denied — grant it in System Settings > Privacy & Security > Bluetooth")
            publishState(.unauthorized)
        case .poweredOff:
            resetConnections(cancel: false, reason: .bluetoothUnavailable)
            bridgeLog(.warning, "engine", "Bluetooth is off")
            publishState(.off)
        default:
            resetConnections(cancel: false, reason: .bluetoothUnavailable)
            publishState(.off)
        }
    }

    package func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard central === self.central else { return }
        guard running, !suspended, central.state == .poweredOn, central.isScanning,
              let manu = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manu.count > 2,
              Switch2.u16(manu, 0) == Switch2.nintendoCompanyID,
              let adv = Switch2.parseAdvertisement(manufacturerData: manu.dropFirst(2)),
              connecting[peripheral.identifier] == nil,
              !sessions.values.contains(where: { $0.peripheral.identifier == peripheral.identifier })
        else { return }

        let id = peripheral.identifier
        let now = ProcessInfo.processInfo.systemUptime
        if let notBefore = retryAfter[id], now < notBefore || disconnecting.contains(id) {
            // Retain only the validated identity and pairing flag, not arbitrary
            // advertisement data. Never reuse observations older than 10 seconds.
            if retryAdvertisements[id] != nil || retryAdvertisements.count < sessionLimit * 8 {
                retryAdvertisements[id] = RetryAdvertisement(peripheral: peripheral,
                    wasPairingMode: adv.isPairing, expiresAt: now + 10)
            }
            armRetryWake()
            return
        }
        guard !disconnecting.contains(id), now >= retryBlockedUntil else { armRetryWake(); return }
        bridgeLog(.info, "engine",
                  "found \(adv.model.displayName) rssi=\(RSSI) \(adv.isPairing ? "(pairing mode)" : "(wake)")")
        _ = beginConnection(peripheral, wasPairingMode: adv.isPairing)
    }

    package func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central else { return }
        guard !disconnecting.contains(peripheral.identifier), running, !suspended,
              let pending = connecting[peripheral.identifier], pending.session.peripheral === peripheral else {
            central.cancelPeripheralConnection(peripheral); return
        }
        bridgeLog(.info, "engine", "connected, starting handshake")
        armDeadline(pending.session, seconds: 45)
        hub.publish(snapshot(), event: .connectionChanged(.init(rawValue: peripheral.identifier), .handshaking),
                    lifetime: pending.session.lifetime)
        pending.session.begin()
    }

    package func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard central === self.central else { return }
        if disconnecting.remove(peripheral.identifier) != nil, central.isScanning {
            // A deferred advertisement may have expired while cancellation was
            // pending. Refresh duplicate filtering once at the terminal event.
            central.stopScan()
        }
        if let pending = connecting[peripheral.identifier], pending.session.peripheral === peripheral {
            noteConnectionFailure(peripheral.identifier)
            retire(pending.session, cancel: false)
            failure(.init(rawValue: peripheral.identifier), .connectionFailed)
            bridgeLog(.warning, "engine", "Bluetooth connection failed")
        }
        updateScanning()
    }

    package func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard central === self.central else { return }
        if disconnecting.remove(peripheral.identifier) != nil, central.isScanning {
            // A deferred advertisement may have expired while cancellation was
            // pending. Refresh duplicate filtering once at the terminal event.
            central.stopScan()
        }
        if let pending = connecting[peripheral.identifier], pending.session.peripheral === peripheral {
            noteConnectionFailure(peripheral.identifier)
            retire(pending.session, cancel: false)
        }
        if let session = sessions.values.first(where: { $0.peripheral === peripheral }) {
            retire(session, cancel: false)
        }
        updateScanning()
    }
}

extension ControllerTransport: ControllerSessionDelegate {

    package func sessionReady(_ session: ControllerSession) {
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
        session.onRSSI = { [weak self, weak session] value in
            guard let self, let session, self.sessions[session.slot] === session, !session.isRetired else { return }
            self.hub.publish(self.snapshot(), event: .signalStrengthChanged(.init(rawValue: id), decibels: value),
                             lifetime: session.lifetime)
        }
        session.onState = { [weak self, weak session] slot, state in
            guard let self, let session, self.sessions[slot] === session else { return }
            self.emitState(slot: slot, state: state)
        }
        let controller = controllerSnapshot(session)
        currentControllers[id] = controller
        hub.publish(snapshot(), event: .connected(controller), lifetime: session.lifetime)
        updateScanning()
    }

    package func sessionFailed(_ session: ControllerSession, reason: String) {
        guard owns(session) else { return }
        noteConnectionFailure(session.peripheral.identifier)
        failure(.init(rawValue: session.peripheral.identifier), .protocolFailure)
        retire(session, cancel: true, reason: .protocolFailure)
        updateScanning()
    }

    package func sessionDidUpdateState(_ session: ControllerSession) {
        guard sessions[session.slot] === session else { return }
        // Input events already update the manager snapshot at full rate.
    }
}
#endif
