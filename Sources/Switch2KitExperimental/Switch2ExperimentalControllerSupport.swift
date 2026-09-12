import Foundation
import Synchronization
import Switch2Kit

/// Unsupported research operations. Firmware behavior, formats and physical effects are unqualified.
/// Do not present these cases as stable controller capabilities or general GameCube rumble support.
public enum Switch2ExperimentalAction: Sendable {
    /// Runs the existing finite NFC discovery/read probe; decoded tag contents require explicit host handling.
    case nfcProbe
    /// Sends a finite 440 Hz headphone-format experiment, not an audio playback API.
    case audioTone
    /// Runs four finite PCM/framing experiments. Start with headphone volume at a safe level.
    case audioFormatProbe
    /// Runs a finite frequency-controlled actuator experiment on the HD-rumble lane.
    case hapticMelody
    /// Tests supported motors, or one finite GameCube firmware preset, at normalized intensity 0...1.
    /// Zero is mute. The GameCube preset cannot be cancelled after submission.
    case rumbleDiagnostic(intensity: Double)
}

/// A research tag result, delivered only after an explicit NFC action. Treat it as sensitive data.
public struct Switch2ExperimentalTag: Sendable {
    /// Tag UID text. Never automatically persist or log it.
    public let uid: String
    /// Provisional UTF-8 NDEF Text record, if decoded. It is untrusted external content.
    public let text: String?
    /// Number of bytes assembled by the bounded research read.
    public let byteCount: Int
}

/// Typed experimental-operation failures without raw transport/error contents.
public enum Switch2ExperimentalError: Error, Sendable {
    /// Another finite experiment is already active on this physical controller.
    case busy
    /// A ready session with the experimental companion is unavailable.
    case unavailable
    /// The firmware lacks the needed characteristic or the model lacks the actuator.
    case unsupported
    /// The explicitly selected capture directory could not be used.
    case captureFileUnavailable
}

/// Explicit audio-capture results. Files are never created unless the host chooses a directory.
public struct Switch2ExperimentalCapture: Sendable {
    /// File containing timestamped full notifications in the retained FTCWAUD2 research format.
    public let packetsURL: URL
    /// File containing timestamped extracted audio regions in the same format.
    public let framesURL: URL
    /// Count of notifications accepted by the writer, not proof of microphone audio.
    public let packetCount: Int
    /// Count of packets dropped by the 128-packet / 4096-byte-per-packet bound.
    public let droppedPacketCount: Int
}

/// Low-frequency research events, delivered serially on the host-selected queue, never the radio queue.
/// The newest 16 events are retained when the host is slow; raw audio packets are never queued here.
public enum Switch2ExperimentalEvent: Sendable {
    /// An explicit probe produced tag metadata. Do not treat its text as trusted UI markup or a command.
    case nfcTagRead(Switch2ControllerID, Switch2ExperimentalTag)
    /// An explicit capture finished or was stopped during retirement.
    case audioCaptureFinished(Switch2ControllerID, Switch2ExperimentalCapture)
    /// An experiment could not proceed.
    case failure(Switch2ControllerID, Switch2ExperimentalError)
}

/// Opt-in companion for unsupported dashboard research features. Install it before `manager.start()`.
/// Stable Switch2Kit does not link this target. This companion shares the manager's private serial
/// executor through package-only hooks; its public API still exposes only IDs and Sendable values.
public final class Switch2ExperimentalControllerSupport: Sendable {
    private let manager: Switch2ControllerManager
    private let events: ExperimentalEventPipe
    /// Attaches research support without starting Bluetooth. The host supplies its delivery queue.
    /// This initializer never enables raw diagnostic logging or creates capture files.
    public init(manager: Switch2ControllerManager, on queue: DispatchQueue = .main,
                handler: @escaping @Sendable (Switch2ExperimentalEvent) -> Void = { _ in }) {
        self.manager = manager
        let events = ExperimentalEventPipe(queue: queue, handler: handler)
        self.events = events
        manager.transport.installCompanion { session in
            let companion = ExperimentalControllerSession(base: session)
            companion.operations = ExperimentalOperations(session: companion, events: events)
            session.companion = companion
        }
    }
    /// Requests a bounded research operation. Availability failures arrive through the event handler.
    /// Non-finite/out-of-range rumble intensities throw `Switch2KitError.invalidParameter`.
    public func perform(_ action: Switch2ExperimentalAction, on id: Switch2ControllerID) throws {
        if case .rumbleDiagnostic(let intensity) = action,
           !intensity.isFinite || !(0...1).contains(intensity) { throw Switch2KitError.invalidParameter }
        manager.transport.withSession(id) { [events] base in
            guard let session = base.companion as? ExperimentalControllerSession,
                  let operations = session.operations else { events.submit(.failure(id, .unavailable)); return }
            switch action {
            case .nfcProbe: operations.nfcProbe()
            case .audioTone: operations.audioPlayTone()
            case .audioFormatProbe: operations.audioToneTest()
            case .hapticMelody:
                guard base.model.hasHDRumble else { events.submit(.failure(id, .unsupported)); return }
                operations.hapticMelody()
            case .rumbleDiagnostic(let intensity): session.testRumble(intensity: intensity)
            }
        }
    }
    /// Captures up to 30 seconds of unsupported headset notifications into an explicit host directory.
    /// File IO is off the Bluetooth queue, bounded and opt-in. This can suppress ordinary input on
    /// some firmware. Captures stop on retirement; no microphone/audio qualification is implied.
    public func captureAudio(on id: Switch2ControllerID, directory: URL, seconds: TimeInterval = 30) throws {
        guard directory.isFileURL, seconds.isFinite, (0.1...30).contains(seconds) else { throw Switch2KitError.invalidParameter }
        manager.transport.withSession(id) { [events] base in
            guard let session = base.companion as? ExperimentalControllerSession,
                  let operations = session.operations else { events.submit(.failure(id, .unavailable)); return }
            operations.captureAudio(directory: directory, seconds: seconds)
        }
    }
    /// Selects the prior experimental sensor profile for FUTURE sessions. The default remains compatibility.
    /// This is unqualified power research, not a battery-life guarantee; reconnect to apply a change.
    public func setSensorProfile(_ profile: Switch2ExperimentalSensorProfile) {
        manager.transport.setSensorProfile(Switch2.Feature.SensorProfile(rawValue: profile.rawValue) ?? .compatibility)
    }
}

/// Explicit, unqualified sensor demand profiles. No process environment or app preferences are read here.
public enum Switch2ExperimentalSensorProfile: String, CaseIterable, Sendable {
    /// Original full sensor set, including optical sensing on Joy-Con models.
    case compatibility
    /// Buttons, sticks, triggers, baseline and battery telemetry.
    case gamepad
    /// Gamepad input plus motion sensing.
    case motion
    /// Gamepad input plus Joy-Con optical sensing where available.
    case pointer
}

// Mutable queue is mutex-protected; one serial drain invokes the host away from Bluetooth.
final class ExperimentalEventPipe: Sendable {
    private struct Inbox: Sendable { var pending: [Switch2ExperimentalEvent] = []; var scheduled = false }
    private let inbox = Mutex(Inbox())
    private let queue: DispatchQueue
    private let handler: @Sendable (Switch2ExperimentalEvent) -> Void
    init(queue: DispatchQueue, handler: @escaping @Sendable (Switch2ExperimentalEvent) -> Void) {
        self.queue = queue; self.handler = handler
    }
    func submit(_ event: Switch2ExperimentalEvent) {
        let schedule = inbox.withLock { value in
            if value.pending.count == 16 { value.pending.removeFirst() }
            value.pending.append(event)
            guard !value.scheduled else { return false }
            value.scheduled = true; return true
        }
        if schedule { queue.async { [weak self] in self?.drain() } }
    }
    private func drain() {
        let pending = inbox.withLock { value in
            let events = value.pending; value.pending.removeAll(keepingCapacity: true); return events
        }
        for event in pending { handler(event) }
        let again = inbox.withLock { value in
            if value.pending.isEmpty { value.scheduled = false; return false }; return true
        }
        if again { queue.async { [weak self] in self?.drain() } }
    }
}
