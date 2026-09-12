import Foundation
import Switch2Kit
import Switch2KitExperimental

// Module-local compatibility names, not copied parsers, calibration or protocol implementations.
// Only this application and the unsupported companion use package-scoped legacy value helpers.
typealias Switch2 = Switch2Kit.Switch2
typealias ControllerState = Switch2Kit.ControllerState

/// The dashboard's value adapter. It performs no decoding, calibration, Bluetooth or output IO.
/// Missing physical controls remain neutral in existing logical-player/output wire formats.
enum Switch2KitStateAdapter {
    static func outputState(_ value: Switch2ControllerState) -> ControllerState {
        var state = ControllerState()
        state.buttons = value.buttons
        state.leftStick = (value.leftStick?.x ?? 0, value.leftStick?.y ?? 0)
        state.rightStick = (value.rightStick?.x ?? 0, value.rightStick?.y ?? 0)
        state.leftTrigger = value.leftTrigger.travel.map { UInt8(($0 * 255).rounded()) }
            ?? (value.leftTrigger.isPressed ? 255 : 0)
        state.rightTrigger = value.rightTrigger.travel.map { UInt8(($0 * 255).rounded()) }
            ?? (value.rightTrigger.isPressed ? 255 : 0)
        state.batteryMillivolts = value.battery.millivolts ?? 0
        state.chargeState = value.battery.chargeStateRaw; state.batteryCurrent = value.battery.currentRaw
        if let motion = value.motion {
            state.gyro = (motion.angularVelocityRaw.x, motion.angularVelocityRaw.y, motion.angularVelocityRaw.z)
            state.accel = (motion.accelerationRaw.x, motion.accelerationRaw.y, motion.accelerationRaw.z)
            state.mag = (motion.magneticFieldRaw.x, motion.magneticFieldRaw.y, motion.magneticFieldRaw.z)
            state.temperatureC = motion.temperatureCelsius
        }
        if let optical = value.optical {
            state.mouseX = optical.xCounter; state.mouseY = optical.yCounter
            state.surfaceQuality = optical.surfaceQualityRaw; state.liftDistance = optical.liftDistanceRaw
        }
        return state
    }
}

/// Application-queue-confined record of a physical snapshot and its dashboard slot.
/// This is NOT a Bluetooth session: it owns no peripheral, handshake, retry, or decoder.
final class ApplicationController: @unchecked Sendable {
    let slot: Int
    private let manager: Switch2ControllerManager
    private let experimental: Switch2ExperimentalControllerSupport
    private(set) var snapshot: Switch2Controller
    private(set) var state: ControllerState
    private(set) var isRetired = false
    var onRSSI: ((Int) -> Void)?
    var id: Switch2ControllerID { snapshot.id }
    var model: Switch2.Model { snapshot.model }
    var displayName: String { snapshot.name }
    var serialNumber: String { snapshot.serialNumber ?? "peripheral-\(id.rawValue.uuidString)" }
    var batteryMillivolts: UInt16 { snapshot.state.battery.millivolts ?? 0 }
    var lastReportAt: TimeInterval { snapshot.state.receivedAt }
    var lastActivityAt: TimeInterval { snapshot.lastActivityAt }
    var info: Switch2.ControllerInfo? {
        Switch2.ControllerInfo(serialNumber: serialNumber, vendorID: Switch2.nintendoVendorID,
            productID: model.rawValue,
            bodyColor: (snapshot.bodyColor?.red ?? 128, snapshot.bodyColor?.green ?? 128, snapshot.bodyColor?.blue ?? 128),
            buttonColor: (snapshot.buttonColor?.red ?? 128, snapshot.buttonColor?.green ?? 128, snapshot.buttonColor?.blue ?? 128))
    }
    init(snapshot: Switch2Controller, slot: Int, manager: Switch2ControllerManager,
         experimental: Switch2ExperimentalControllerSupport) {
        self.snapshot = snapshot; self.slot = slot; self.manager = manager; self.experimental = experimental
        self.state = Switch2KitStateAdapter.outputState(snapshot.state)
    }
    func update(_ value: Switch2Controller) {
        guard !isRetired, value.id == id, value.sessionGeneration == snapshot.sessionGeneration else { return }
        snapshot = value; state = Switch2KitStateAdapter.outputState(value.state)
    }
    func teardown() { isRetired = true; onRSSI = nil }
    func setRumble(strong: Double, weak: Double) {
        guard !isRetired, model.hasHDRumble else { return }
        try? manager.setRumble(for: id, strong: strong, weak: weak)
    }
    func pulseRumble(strong: Double, weak: Double = 0, duration: Double) {
        guard !isRetired, model.hasHDRumble else { return }
        // The session's existing safety intent already expires after 500 ms.
        if duration <= 0 { try? manager.setRumble(for: id, strong: 0); return }
        try? manager.pulseRumble(for: id, strong: strong, weak: weak, duration: min(0.5, max(0.01, duration)))
    }
    func testRumble(intensity: Double) {
        guard !isRetired else { return }
        try? experimental.perform(.rumbleDiagnostic(intensity: intensity), on: id)
    }
    func setPlayerNumber(_ value: Int) {
        guard !isRetired else { return }
        try? manager.setPlayerNumber(value, for: id); refreshLEDs()
    }
    private var savedLEDPattern: UInt8? {
        let values = UserDefaults.standard.dictionary(forKey: "controllerSettings")?[serialNumber] as? [String: Any]
        guard let pattern = values?["ledPattern"] as? Int, pattern > 0 else { return nil }
        return UInt8(pattern & 15)
    }
    func refreshLEDs() {
        guard !isRetired else { return }
        try? manager.setPlayerLEDPattern(savedLEDPattern, for: id)
    }
    func setRawLEDs(_ pattern: UInt8?) {
        guard !isRetired else { return }
        try? manager.setPlayerLEDPattern(pattern ?? savedLEDPattern, for: id)
    }
    func requestRSSI() {
        guard !isRetired else { return }
        manager.requestSignalStrength(for: id)
    }
}

// Process environment selection remains an explicit application experiment, not library policy.
enum ApplicationSensorPolicy {
    static let selectedProfile = Switch2.Feature.SensorProfile.resolve(
        ProcessInfo.processInfo.environment["SWITCH2MAC_EXPERIMENTAL_SENSORS"],
        acknowledged: ProcessInfo.processInfo.environment["SWITCH2MAC_ACKNOWLEDGE_UNQUALIFIED_POWER"] == "1")
}
