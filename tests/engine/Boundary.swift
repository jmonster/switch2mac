import Foundation

final class Central {
    var cancelled: [UUID] = []
    func stopScan() {}
    func cancelPeripheralConnection(_ peripheral: CBPeripheral) { cancelled.append(peripheral.identifier) }
}
final class Output {
    var resets = 0
    var acceptsPointer = false
    func handle(serial: String, model: Switch2.Model, state: ControllerState, configuration: ControllerConfiguration) -> Bool { acceptsPointer }
    func reset() { resets += 1 }
    func reset(serial: String) { resets += 1 }
}
enum AppConfig { static var idleSleepMinutes = 1.0 }
final class BridgeEngine: ControllerSessionDelegate, @unchecked Sendable {
    enum State { case paused }
    let btQueue = DispatchQueue(label: "engine-tests")
    let central = Central()
    let mouseController = Output(), keyboardMapper = Output(), gestureRecognizer = Output()
    var running = true, suspended = false
    var sessions: [Int: ControllerSession] = [:]
    var connecting: [UUID: (session: ControllerSession, slot: Int)] = [:]
    var disconnecting = Set<UUID>()
    var deadlines: [UUID: DispatchWorkItem] = [:]
    var connectedAt: [Int: Date] = [:]
    var retryAfter: [UUID: TimeInterval] = [:]
    var lastButtonsByPlayer: [Int: Int] = [:], captureLast: [Int: Int] = [:]
    @MainActor var liveStates: [Int: ControllerState] = [:]
    weak var findingSession: ControllerSession?
    let visualizer = VisualizerMailbox<ControllerState>(maxSlots: 4)
    var pointerActivity: [UUID: TimeInterval] = [:]
    var configurations: [String: ControllerConfiguration] = [:]
    var idleSweepTimer: DispatchSourceTimer?
    func scheduleVisualizerDrain() {}
    var recomputes = 0, publishes = 0, emissions = 0
    func stopFinding() { findingSession = nil }
    func recomputeLogical() { recomputes += 1 }
    func updateScanning() {}
    func publishState(_ state: State) {}
    func publishControllers() { publishes += 1 }
    func emitState(slot: Int, state: ControllerState) { emissions += 1 }
