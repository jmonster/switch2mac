import Foundation

/// Discovery policy, independent of application preferences and logical players.
public enum Switch2DiscoveryMode: String, Codable, Sendable {
    /// Scan whenever Bluetooth and a physical-controller resource slot are available.
    case automatic
    /// Open a setup window when enabled, then scan only while a remembered controller is missing.
    /// An empty remembered set continues scanning so initial setup remains possible.
    case remembered
    /// Scan only during an explicitly requested, bounded discovery window.
    case onDemand
}

/// Resource and privacy policy for one independent manager. The kit never persists these settings itself.
public struct Switch2Configuration: Sendable {
    /// Maximum simultaneous physical connections (1...64). Default 32 is a memory/admission budget,
    /// not a Nintendo player limit; the dashboard explicitly chooses its existing eight-controller budget.
    public let maximumControllers: Int
    /// Maximum independently registered input/lifecycle observers (1...128).
    public let maximumObservers: Int
    /// Default full-rate input capacity per observer (1...4096 reports); overflow drops oldest input.
    public let inputBufferCapacity: Int
    /// Default lifecycle capacity per observer (1...4096 events); overflow terminates with a typed error.
    public let eventBufferCapacity: Int
    /// Initial scanning policy. The default requires an explicit discovery window.
    public let discoveryMode: Switch2DiscoveryMode
    /// Remembered identities supplied by the host; deduplicated and capped at `maximumControllers`.
    public let rememberedControllers: [Switch2ControllerID]
    /// Explicitly disclose hardware serials in identity snapshots. False by default.
    /// The kit still never logs them, even when enabled. Hosts own secure persistence and UI disclosure.
    public let exposesSerialNumbers: Bool
    /// Creates configuration. Invalid resource budgets are programmer errors and fail a precondition.
    /// No disk access, permission prompt, or Bluetooth activity occurs here.
    public init(maximumControllers: Int = 32, maximumObservers: Int = 32,
                inputBufferCapacity: Int = 256, eventBufferCapacity: Int = 128,
                discoveryMode: Switch2DiscoveryMode = .onDemand,
                rememberedControllers: [Switch2ControllerID] = [], exposesSerialNumbers: Bool = false) {
        precondition((1...64).contains(maximumControllers) && (1...128).contains(maximumObservers))
        precondition((1...4096).contains(inputBufferCapacity) && (1...4096).contains(eventBufferCapacity))
        self.maximumControllers = maximumControllers; self.maximumObservers = maximumObservers
        self.inputBufferCapacity = inputBufferCapacity; self.eventBufferCapacity = eventBufferCapacity
        self.discoveryMode = discoveryMode; self.exposesSerialNumbers = exposesSerialNumbers
        var seen = Set<Switch2ControllerID>()
        self.rememberedControllers = Array(rememberedControllers.filter { seen.insert($0).inserted }.prefix(maximumControllers))
    }
}
