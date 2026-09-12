#if canImport(CoreBluetooth)
import Foundation
import Combine

/// Owns independent, in-process Nintendo controller support for one host application.
/// Create one manager per intended radio owner, usually on your App/scene's main actor.
/// CoreBluetooth and sessions live on a private serial queue; no peripheral is exposed.
/// Observable snapshots update at most about 10 Hz. Use `observe` for full-rate input.
/// The host owns Bluetooth permission UI, lifecycle, persistence and all output mappings.
@MainActor
public final class Switch2ControllerManager: ObservableObject {
    /// Main-actor presentation snapshot, bounded/coalesced to approximately 10 Hz.
    @Published public private(set) var snapshot = Switch2ManagerSnapshot()
    /// Current main-actor Bluetooth presentation state.
    public var bluetoothState: Switch2BluetoothState { snapshot.bluetooth }
    /// Current main-actor discovery presentation state.
    public var discoveryState: Switch2DiscoveryState { snapshot.discovery }
    /// First-report-ready physical controllers, not logical players or Joy-Con groups.
    public var controllers: [Switch2Controller] { snapshot.controllers }
    /// Whether support is started, independently of Bluetooth permission/power.
    public var isRunning: Bool { snapshot.isRunning }
    /// Immediate thread-safe snapshot, without the presentation throttle.
    public nonisolated var currentSnapshot: Switch2ManagerSnapshot { hub.snapshot }

    private nonisolated let hub: ControllerEventHub
    package nonisolated let transport: ControllerTransport
    private var presentationObservation: Switch2ControllerObservation?

    /// Creates an independent manager; this does not open Bluetooth or start discovery.
    /// The optional handler receives privacy-safe, bounded diagnostics on a utility queue.
    /// No files, preferences or app entitlements are created by the library.
    public init(configuration: Switch2ControllerConfiguration = .init(),
                minimumLogLevel: Switch2LogLevel = .info, logHandler: Switch2LogHandler? = nil) {
        let hub = ControllerEventHub()
        self.hub = hub
        self.transport = ControllerTransport(configuration: configuration, hub: hub,
            diagnostics: Switch2Diagnostics(minimum: minimumLogLevel, handler: logHandler))
        self.presentationObservation = try? hub.observe(queue: .main, capacity: 1, interval: 0.1) { [weak self, hub] _ in
            MainActor.assumeIsolated { self?.snapshot = hub.snapshot }
        }
    }
    deinit { presentationObservation?.cancel(); transport.shutdown() }

    /// Starts support idempotently. Bluetooth authorization may be requested by macOS.
    /// The default on-demand configuration scans only after `discover(for:)` is requested.
    public nonisolated func start() { transport.start() }

    /// Stops scanning, cancels timers/retries, retires every attempt, and releases sessions.
    /// Returning means the transport teardown has run and the presentation snapshot is current.
    /// Previously emitted values are immutable; an already-running host handler may finish.
    /// A later `start()` creates fresh sessions, never revives a retired one.
    public nonisolated func stop() async {
        await withCheckedContinuation { continuation in transport.stop { continuation.resume() } }
        await MainActor.run { self.snapshot = self.hub.snapshot }
    }

    /// Completion-based stop for AppKit termination and other callback lifecycles.
    /// Completion runs asynchronously on a global queue, never the Bluetooth queue.
    /// Teardown is complete when called; marshal any UI work to the main actor.
    public nonisolated func stop(completion: @escaping @Sendable () -> Void) { transport.stop(completion: completion) }

    /// Opens/replaces a discovery window of 0.1...300 seconds; the default is 60 seconds.
    /// Call `start()` first. Existing ready controllers remain connected. Automatic mode
    /// intentionally continues scanning after a request; use on-demand mode for window-only scanning.
    /// Throws `invalidParameter` for non-finite or out-of-range durations.
    public nonisolated func discover(for seconds: TimeInterval = 60) throws {
        guard seconds.isFinite, (0.1...300).contains(seconds) else { throw Switch2KitError.invalidParameter }
        transport.requestDiscoveryWindow(seconds: seconds)
    }

    /// Replaces discovery policy and its explicit remembered identity set.
    /// Quiet mode preserves the original full setup window; no user defaults are read.
    /// Store `currentSnapshot.rememberedControllers` yourself to persist that policy across launches.
    public nonisolated func configureDiscovery(_ mode: Switch2DiscoveryMode, remembered: [Switch2ControllerID] = []) {
        transport.configureDiscovery(mode: mode, remembered: remembered)
    }

    /// Closes the discovery window and remembers only the currently ready physical devices.
    /// Does not erase protocol bonds, remap controls, or disconnect a ready controller.
    public nonisolated func useOnlyConnectedControllersForDiscovery() { transport.useConnectedForDiscovery() }

    /// Receives ordered events on a host-selected queue, never the Bluetooth queue.
    /// Retain the returned observation. The handler must finish promptly; delivery is serial
    /// even on a concurrent queue. Capacity is 1...4096 events (default 256), at most 32 observers
    /// including the manager's presentation observer. On overflow, pending events are replaced
    /// by an authoritative snapshot. Reconcile that snapshot to release missing/changed controls.
    /// Pending input from retired attempts is discarded before handler invocation. Cancellation
    /// cannot retract a value already delivered to caller code. This API is intentionally bounded,
    /// not a lossless recording service for a slow consumer.
    public nonisolated func observe(on queue: DispatchQueue, bufferingNewest capacity: Int = 256,
                                   handler: @escaping @Sendable (Switch2ControllerEvent) -> Void) throws -> Switch2ControllerObservation {
        try hub.observe(queue: queue, capacity: capacity, handler: handler)
    }

    /// Retires the selected session, including a pending connection attempt.
    /// The controller can reconnect through a later valid advertisement while discovery permits it.
    /// This is not macOS SMP unpairing and does not erase the controller's protocol bond.
    public nonisolated func disconnect(_ id: Switch2ControllerID) { transport.disconnect(id, forget: false) }

    /// Removes the local remembered identity and retires the session. The controller still
    /// remembers its protocol bond; a later valid button-wake or Sync advertisement may connect
    /// again while discovery permits it. No macOS pairing entry, application settings or
    /// controller-stored bond is deleted. The host owns any persistent settings removal.
    public nonisolated func forget(_ id: Switch2ControllerID) { transport.disconnect(id, forget: true) }

    /// Sets normalized HD-rumble intent: each channel is 0...1. Pro uses strong=left, weak=right;
    /// a Joy-Con mixes the channels into its single actuator. GameCube is rejected with a typed event.
    /// Zero stops rumble. A 500 ms failsafe stops an intent unless renewed; this protects stalled hosts.
    /// Repeated intents coalesce in a bounded inbox. Values must be finite and in range.
    public nonisolated func setRumble(for id: Switch2ControllerID, strong: Double, weak: Double = 0) throws {
        guard strong.isFinite, weak.isFinite, (0...1).contains(strong), (0...1).contains(weak) else {
            throw Switch2KitError.invalidParameter
        }
        transport.submitRumble(id, strong: strong, weak: weak, duration: nil)
    }

    /// Plays a bounded 0.01...0.5 second HD-rumble pulse. A later pulse/intent replaces it;
    /// generation checks prevent an old stop callback from cancelling newer rumble.
    /// The channel mapping and model restrictions are the same as `setRumble`.
    public nonisolated func pulseRumble(for id: Switch2ControllerID, strong: Double = 0.5,
                                       weak: Double = 0, duration: TimeInterval = 0.15) throws {
        guard duration.isFinite, (0.01...0.5).contains(duration), strong.isFinite, weak.isFinite,
              (0...1).contains(strong), (0...1).contains(weak) else { throw Switch2KitError.invalidParameter }
        transport.submitRumble(id, strong: strong, weak: weak, duration: duration)
    }

    /// Requests RSSI; a `signalStrengthChanged` event delivers dBm on the observation's queue.
    /// RSSI is approximate proximity, not distance. Unavailable readings are not fabricated.
    public nonisolated func requestSignalStrength(for id: Switch2ControllerID) {
        transport.withSession(id) { $0.requestRSSI() }
    }

    /// Sets a physical controller's 1...8 player-indicator pattern without assigning a logical player.
    /// A custom pattern set with `setPlayerLEDPattern` takes precedence until cleared.
    public nonisolated func setPlayerNumber(_ number: Int, for id: Switch2ControllerID) throws {
        guard (1...8).contains(number) else { throw Switch2KitError.invalidParameter }
        transport.withSession(id) { $0.setPlayerNumber(number) }
    }

    /// Overrides the four LED bits (0...15), or restores the player-number pattern with nil.
    /// This is in-process controller control; the library does not persist the selection.
    public nonisolated func setPlayerLEDPattern(_ pattern: UInt8?, for id: Switch2ControllerID) throws {
        guard pattern == nil || pattern! <= 15 else { throw Switch2KitError.invalidParameter }
        transport.withSession(id) { session in session.customLEDPattern = pattern; session.refreshLEDs() }
    }
}
#endif
