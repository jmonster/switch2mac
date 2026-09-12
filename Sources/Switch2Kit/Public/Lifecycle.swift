import Foundation

/// CoreBluetooth adapter availability, independent of individual controller sessions.
public enum Switch2BluetoothState: String, Sendable {
    /// Adapter state has not been delivered yet.
    case unknown
    /// The adapter is resetting; existing sessions have been retired.
    case resetting
    /// This host does not support the required Bluetooth operations.
    case unsupported
    /// The host application has not been authorized to use Bluetooth.
    case unauthorized
    /// Bluetooth is switched off.
    case poweredOff
    /// Bluetooth is on; controller support may scan or connect.
    case poweredOn
}

/// Progress of one connection attempt. Readiness requires a handshake AND an input report.
public enum Switch2ConnectionState: String, Sendable {
    /// A validated advertisement has been admitted for a connection attempt.
    case connecting
    /// The link is open and service discovery or the controller handshake is running.
    case handshaking
    /// The handshake and first valid input report are both complete.
    case ready
    /// The session is terminal. No new reports from it are accepted.
    case disconnected
}

/// Why a physical-controller session ended; not a macOS pairing-state description.
public enum Switch2DisconnectionReason: String, Sendable {
    /// The link ended, for example because the controller powered off or moved out of range.
    case linkLost
    /// The application explicitly disconnected the controller.
    case requested
    /// The application forgot its local remembered identity.
    case forgotten
    /// Controller support stopped, including an explicit sleep/lifecycle stop.
    case stopped
    /// Bluetooth became unavailable or unauthorized.
    case bluetoothUnavailable
    /// A connection phase, command, write capacity or input freshness deadline expired.
    case timeout
    /// A required protocol or characteristic operation failed.
    case protocolFailure
}

/// Radio discovery state. A paused scan does not pause existing controllers or keep-alives.
public enum Switch2DiscoveryState: Equatable, Sendable {
    /// Support is stopped, Bluetooth is unavailable, or no discovery window has been requested.
    case stopped
    /// Scanning. The optional deadline is monotonic seconds since boot, not a wall-clock date.
    case scanning(until: TimeInterval?)
    /// A connection/handshake is in flight; scanning resumes afterward if policy permits.
    case connecting
    /// The remembered physical-controller set is ready, or an on-demand window expired.
    case paused
    /// The configurable physical-session resource limit has been reached.
    case capacityReached
}

/// Discovery policy; no preferences or persistent storage are read by Switch2Kit.
public enum Switch2DiscoveryMode: String, Sendable {
    /// Scan only inside an explicit, replaceable bounded window.
    case onDemand
    /// Continuously scan while support is running and capacity is available.
    case automatic
    /// Open a 60-second setup window on entry, then pause when all remembered units are ready.
    /// Missing remembered units resume scanning; this is not a claim that the radio is idle.
    case quietWhenReady
}

/// Typed, privacy-safe failures. Error payloads never contain raw controller identifiers or frames.
public enum Switch2KitError: Error, Equatable, Sendable {
    /// The requested operation needs a ready controller, but its current session is absent.
    case controllerNotReady
    /// The model does not support the requested stable operation (notably GameCube HD rumble).
    case unsupportedOperation
    /// A finite duration, intensity or resource bound was outside its documented range.
    case invalidParameter
    /// More than 32 event observers were requested; cancel an old observation first.
    case observerLimitReached
    /// A Bluetooth link could not be established.
    case connectionFailed
    /// Service discovery, characteristic subscription or controller handshake failed.
    case protocolFailure
    /// A 10-second connect, 45-second handshake/first-report, or 5-second input deadline expired.
    case timedOut
    /// Bluetooth is unauthorized, off, resetting or unsupported.
    case bluetoothUnavailable
}

/// Immutable manager-wide state; use it to resynchronize after event backpressure.
public struct Switch2ManagerSnapshot: Equatable, Sendable {
    /// Whether support is started. Starting does not imply Bluetooth permission or readiness.
    public let isRunning: Bool
    /// The most recent adapter state.
    public let bluetooth: Switch2BluetoothState
    /// The current discovery state.
    public let discovery: Switch2DiscoveryState
    /// First-report-ready physical controllers, ordered by locally scoped identity.
    public let controllers: [Switch2Controller]
    /// The current quiet-discovery set. Save it only by an explicit host persistence decision.
    public let rememberedControllers: [Switch2ControllerID]
    package init(isRunning: Bool = false, bluetooth: Switch2BluetoothState = .unknown,
                 discovery: Switch2DiscoveryState = .stopped, controllers: [Switch2Controller] = [],
                 rememberedControllers: [Switch2ControllerID] = []) {
        self.isRunning = isRunning; self.bluetooth = bluetooth; self.discovery = discovery
        self.controllers = controllers; self.rememberedControllers = rememberedControllers
    }
}

/// Ordered controller events, delivered off the Bluetooth queue to a bounded observation.
/// A slow observer receives an authoritative `.snapshot` rather than an unbounded backlog.
/// Lifecycle events are not an audit log: after overflow, reconcile identities from that snapshot.
public enum Switch2ControllerEvent: Sendable {
    /// Initial state or resynchronization after observer overflow.
    case snapshot(Switch2ManagerSnapshot)
    /// An adapter, discovery, running or remembered-set state change.
    case status(Switch2ManagerSnapshot)
    /// A connection attempt entered a new phase.
    case connectionChanged(Switch2ControllerID, Switch2ConnectionState)
    /// A physical controller became usable after handshake and its first input report.
    case connected(Switch2Controller)
    /// A complete calibrated input report. Fast observers receive every decoded report.
    case input(Switch2Controller)
    /// A controller or connection attempt was retired; clear any application-held controls.
    case disconnected(Switch2ControllerID, Switch2DisconnectionReason)
    /// A requested signal-strength reading in dBm; relative proximity only, not a calibrated distance.
    case signalStrengthChanged(Switch2ControllerID, decibels: Int)
    /// A typed operation/lifecycle failure; the optional ID is for host routing, not logging.
    case failure(Switch2ControllerID?, Switch2KitError)
}

/// Resource and privacy choices for one independent manager. No singleton is required.
public struct Switch2ControllerConfiguration: Sendable {
    /// Initial discovery policy. On-demand is the reusable-library default.
    public var discoveryMode: Switch2DiscoveryMode
    /// Initial locally remembered identities. Duplicates are removed; the resource limit bounds storage.
    public var rememberedControllers: [Switch2ControllerID]
    /// Physical-controller resource limit, clamped to 1...64. It is not a logical-player limit.
    public var maximumControllers: Int
    /// Explicitly include hardware serials in controller snapshots for legacy host mappings.
    /// False by default. This never enables serials in diagnostic records.
    public var includeSerialNumbers: Bool
    /// Creates configuration; applications own any persistence and sleep/wake policy.
    public init(discoveryMode: Switch2DiscoveryMode = .onDemand,
                rememberedControllers: [Switch2ControllerID] = [], maximumControllers: Int = 16,
                includeSerialNumbers: Bool = false) {
        self.discoveryMode = discoveryMode; self.rememberedControllers = rememberedControllers
        self.maximumControllers = min(64, max(1, maximumControllers)); self.includeSerialNumbers = includeSerialNumbers
    }
}
