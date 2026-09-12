import Foundation

/// Opaque physical-controller identity. It is not a serial number or a system game-controller ID.
/// The underlying CoreBluetooth identifier is privacy-sensitive: persist only by explicit host choice
/// and do not include it in diagnostics. It is stable only as long as macOS preserves that identity.
public struct Switch2ControllerID: RawRepresentable, Hashable, Codable, Sendable {
    /// Identifier suitable for equality and host-controlled local persistence; not a Bluetooth address.
    public let rawValue: UUID
    /// Restores an identifier from host-controlled storage, or creates a fixture identity.
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// An 8-bit-per-channel controller housing/button colour, in RGB order.
public struct Switch2RGBColor: Equatable, Codable, Sendable {
    /// Red intensity, 0...255.
    public let red: UInt8
    /// Green intensity, 0...255.
    public let green: UInt8
    /// Blue intensity, 0...255.
    public let blue: UInt8
    /// Creates an RGB colour without colour-space conversion.
    public init(red: UInt8, green: UInt8, blue: UInt8) { self.red = red; self.green = green; self.blue = blue }
}

/// Validated controller identity information. Serial disclosure requires an explicit host configuration.
public struct Switch2ControllerIdentity: Equatable, Codable, Sendable {
    /// Raw hardware serial only when the host opted in; nil by default. Never logged by Switch2Kit.
    public let serialNumber: String?
    /// Validated Nintendo USB vendor ID (0x057e); this is model information, not a unique identity.
    public let vendorID: UInt16
    /// Supported Nintendo product ID, equivalent to the controller model's raw value.
    public let productID: UInt16
    /// Reported body colour, or nil when identity memory has not been read.
    public let bodyColor: Switch2RGBColor?
    /// Reported button colour, or nil when identity memory has not been read.
    public let buttonColor: Switch2RGBColor?
    /// Creates identity data without exposing any CoreBluetooth object.
    public init(serialNumber: String? = nil, vendorID: UInt16 = 0x057e, productID: UInt16,
                bodyColor: Switch2RGBColor? = nil, buttonColor: Switch2RGBColor? = nil) {
        self.serialNumber = serialNumber; self.vendorID = vendorID; self.productID = productID
        self.bodyColor = bodyColor; self.buttonColor = buttonColor
    }
}

/// A physical connection's current phase. Ready means handshake AND a valid first input report.
public enum Switch2ConnectionState: String, Codable, Sendable {
    /// A supported advertisement was admitted and CoreBluetooth connection is pending.
    case connecting
    /// GATT discovery or the application-level handshake is in progress.
    case handshaking
    /// The handshake and at least one valid input report have completed.
    case ready
    /// The connection has been retired; its reports and commands cannot be delivered again.
    case disconnected
}

/// CoreBluetooth availability; hosts supply user-facing permission and power UI.
public enum Switch2BluetoothState: String, Codable, Sendable {
    /// The manager has not received the adapter state yet.
    case unknown
    /// The adapter/stack is resetting; existing sessions have been retired.
    case resetting
    /// Bluetooth Low Energy is unavailable on this platform/adapter.
    case unsupported
    /// The host application does not have Bluetooth authorization.
    case unauthorized
    /// The Bluetooth adapter is switched off.
    case poweredOff
    /// The adapter is available. This alone does not mean a controller is connected.
    case poweredOn
}

/// Why scanning is running or paused. Existing ready controllers continue streaming while scanning is quiet.
public enum Switch2DiscoveryState: Equatable, Sendable {
    /// Support is stopped, suspended, or an on-demand window has ended.
    case stopped
    /// Support is enabled but the Bluetooth adapter is not available.
    case waitingForBluetooth
    /// Scanning for validated advertisements. A nil deadline means automatic/remembered reconnection scanning.
    case scanning(until: Date?)
    /// Serial connection/handshake admission temporarily pauses scanning.
    case connecting
    /// Every remembered controller is ready and the discovery window has ended.
    case quiet
    /// The host-configured physical-controller resource budget is full; not a protocol player limit.
    case capacityReached
}

/// Why a physical connection was retired. This is separate from the Bluetooth adapter state.
public enum Switch2DisconnectReason: String, Codable, Sendable {
    /// The host explicitly disconnected this controller.
    case requested
    /// Support was stopped or suspended by the host.
    case stopped
    /// The adapter became unavailable, unauthorized, or reset.
    case bluetoothUnavailable
    /// CoreBluetooth ended the link.
    case linkLost
    /// Input reports stopped outside an explicitly active audio experiment.
    case staleInput
    /// Connection, handshake, or command processing failed.
    case failed
    /// The host removed this device from remembered discovery state.
    case forgotten
}

/// Typed failures. Associated identifiers identify a device only when the host already owns that identity.
/// Error descriptions contain no raw serial, peripheral identifier, advertisement, bond, or sensor payload.
public enum Switch2KitError: Error, Equatable, Sendable {
    /// Controller support is not running.
    case notStarted
    /// Bluetooth authorization was denied.
    case bluetoothUnauthorized
    /// Bluetooth is powered off or otherwise unavailable.
    case bluetoothUnavailable
    /// The requested controller/connection is no longer ready.
    case controllerUnavailable
    /// The physical model or negotiated link does not support this operation.
    case unsupportedOperation
    /// A duration, intensity, capacity, or LED value was outside the documented range.
    case invalidArgument
    /// A connection or handshake phase exceeded its deadline.
    case connectionTimeout
    /// A connection attempt failed at the CoreBluetooth boundary.
    case connectionFailed
    /// The ordered controller handshake/command stream failed and was retired.
    case protocolFailure
    /// The bounded command ingress is full. Nothing was queued for this request.
    case commandQueueFull
    /// A lifecycle observer did not consume events within its bounded capacity; resubscribe and read `snapshot`.
    case eventBufferOverflow
    /// The configured observer resource budget is exhausted.
    case tooManyObservers
}

/// An immutable physical-controller snapshot. No slots, peripheral objects, or mutable sessions escape the kit.
public struct Switch2Controller: Identifiable, Equatable, Sendable {
    /// Opaque identity of the physical controller, independent of app player assignment.
    public let id: Switch2ControllerID
    /// Transient token for this connection attempt. Changes on reconnect; never a persistent device identifier.
    /// Use it to distinguish a retained old snapshot from a replacement connection to the same device.
    public let connectionID: UUID
    /// Validated supported physical model.
    public let model: Switch2ControllerModel
    /// Physical model name. Custom names and logical Joy-Con pair names belong to the host.
    public var name: String { model.displayName }
    /// Features enabled and available on this negotiated connection.
    public let capabilities: Switch2ControllerCapabilities
    /// Current connection phase; first-report readiness is explicit.
    public let connectionState: Switch2ConnectionState
    /// Identity/colour metadata after the handshake reads controller memory; nil before that.
    public let identity: Switch2ControllerIdentity?
    /// Host wall-clock time at readiness, or nil before readiness.
    public let connectedAt: Date?
    /// Most recent immutable input report, or nil before a valid report arrives.
    public let state: Switch2ControllerState?
    /// Creates a value snapshot, useful for fixtures. This does not create a Bluetooth connection.
    public init(id: Switch2ControllerID, connectionID: UUID, model: Switch2ControllerModel,
                capabilities: Switch2ControllerCapabilities, connectionState: Switch2ConnectionState,
                identity: Switch2ControllerIdentity? = nil, connectedAt: Date? = nil,
                state: Switch2ControllerState? = nil) {
        self.id = id; self.connectionID = connectionID; self.model = model; self.capabilities = capabilities
        self.connectionState = connectionState; self.identity = identity
        self.connectedAt = connectedAt; self.state = state
    }
}

/// Atomic manager state, readable from any actor. Controllers include admitted connecting attempts and ready devices.
public struct Switch2ManagerSnapshot: Equatable, Sendable {
    /// Whether support is running (as distinct from adapter power or scanning).
    public let isRunning: Bool
    /// Current Bluetooth availability.
    public let bluetoothState: Switch2BluetoothState
    /// Current scanning/admission state.
    public let discoveryState: Switch2DiscoveryState
    /// Physical snapshots, deterministically ordered by connection admission.
    public let controllers: [Switch2Controller]
    /// Host-controlled remembered identities for quiet-when-ready discovery; never persisted automatically.
    public let rememberedControllers: [Switch2ControllerID]
    /// Ready physical controllers; not logical players or system GCController instances.
    public var connectedControllers: [Switch2Controller] { controllers.filter { $0.connectionState == .ready } }
    /// Creates a snapshot without starting support; intended for fixtures/previews.
    public init(isRunning: Bool = false, bluetoothState: Switch2BluetoothState = .unknown,
                discoveryState: Switch2DiscoveryState = .stopped, controllers: [Switch2Controller] = [],
                rememberedControllers: [Switch2ControllerID] = []) {
        self.isRunning = isRunning; self.bluetoothState = bluetoothState; self.discoveryState = discoveryState
        self.controllers = controllers; self.rememberedControllers = rememberedControllers
    }
}

/// Ordered low-frequency lifecycle events. A bounded observer fails explicitly on overflow instead of silently losing retirement.
public enum Switch2ControllerEvent: Equatable, Sendable {
    /// Current atomic state, also delivered first to a new lifecycle observer.
    case snapshotChanged(Switch2ManagerSnapshot)
    /// Handshake and first input completed for this connection.
    case connected(Switch2Controller)
    /// A connection was retired. The transient token distinguishes a replacement connection to the same device.
    case disconnected(Switch2ControllerID, connectionID: UUID, reason: Switch2DisconnectReason)
    /// A typed failure, optionally associated with an already-known physical controller.
    case failed(Switch2ControllerID?, Switch2KitError)
}

/// One full-rate input delivery. The embedded controller/state are immutable and refer to one connection generation.
public struct Switch2InputUpdate: Equatable, Sendable {
    /// Ready controller snapshot at this report's receipt time.
    public let controller: Switch2Controller
    /// Decoded input state (always present, unlike a connecting controller snapshot's state).
    public let state: Switch2ControllerState
    /// Creates a delivery value for a fixture; no report is sent to hardware.
    public init(controller: Switch2Controller, state: Switch2ControllerState) { self.controller = controller; self.state = state }
}
