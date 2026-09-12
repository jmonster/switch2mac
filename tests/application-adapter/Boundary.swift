import Foundation

enum LogLevel { case debug, info, warning, error }
func bridgeLog(_ level: LogLevel, _ category: String, _ message: String) {}

// Test-only transport/output boundaries. ApplicationController, snapshot conversion,
// event reconciliation, retirement, pointer policy and grouping come from Sources.
final class Switch2ControllerManager: @unchecked Sendable {
    var starts = 0, stops = 0
    var disconnects: [Switch2ControllerID] = []
    func start() { starts += 1 }
    func stop(completion: @escaping @Sendable () -> Void) { stops += 1; completion() }
    func disconnect(_ id: Switch2ControllerID) { disconnects.append(id) }
    func setRumble(for id: Switch2ControllerID, strong: Double, weak: Double = 0) throws {}
    func pulseRumble(for id: Switch2ControllerID, strong: Double, weak: Double = 0, duration: Double) throws {}
    func setPlayerNumber(_ value: Int, for id: Switch2ControllerID) throws {}
    func setPlayerLEDPattern(_ value: UInt8?, for id: Switch2ControllerID) throws {}
    func requestSignalStrength(for id: Switch2ControllerID) {}
}
enum ExperimentalAction { case rumbleDiagnostic(intensity: Double) }
final class Switch2ExperimentalControllerSupport: @unchecked Sendable {
    func perform(_ action: ExperimentalAction, on id: Switch2ControllerID) throws {}
}
final class Output {
    var resets = 0
    var acceptsPointer = false
    func handle(serial: String, model: Switch2.Model, state: ControllerState, configuration: ControllerConfiguration) -> Bool { acceptsPointer }
    func reset() { resets += 1 }
    func reset(serial: String) { resets += 1 }
}
enum AppConfig { static let idleSleepMinutes = 1.0 }
enum DiscoveryPolicy {
    // The preference adapter has its own suite. This boundary never writes real application keys.
    static let enabledKey = "Switch2KitFixtureQuietDiscovery"
    static let rememberedKey = "Switch2KitFixtureRemembered"
}
final class BridgeEngine: @unchecked Sendable {
    static let maxSessions = 8
    static let maxPlayers = 4
    enum State { case paused, off, unauthorized, scanning, connecting, idle, ready }
    let btQueue = DispatchQueue(label: "application-output-tests")
    let controllerManager = Switch2ControllerManager()
    let experimentalSupport = Switch2ExperimentalControllerSupport()
    let mouseController = Output(), keyboardMapper = Output(), gestureRecognizer = Output()
    var running = true, suspended = false
    var sessions: [Int: ApplicationController] = [:]
    var connectedAt: [Int: Date] = [:]
    var lastButtonsByPlayer: [Int: Int] = [:], captureLast: [Int: Int] = [:]
    weak var findingSession: ApplicationController?
    let visualizer = VisualizerMailbox<ControllerState>(maxSlots: 4)
    var pointerActivity: [UUID: TimeInterval] = [:]
    var configurations: [String: ControllerConfiguration] = [:]
    var idleSweepTimer: DispatchSourceTimer?
    var lastControllerPublication: TimeInterval = 0
    var emitted: [(Int, ControllerState)] = []
    var recomputes = 0, publishes = 0
    var lastState: State?
    func stopFinding() { findingSession = nil }
    func recomputeLogical() { recomputes += 1 }
    func publishControllers() { publishes += 1 }
    func publishState(_ state: State) { lastState = state }
    func emitState(slot: Int, state: ControllerState) { emitted.append((slot, state)) }
    func scheduleVisualizerDrain() {}
    func updateScanning() {}
