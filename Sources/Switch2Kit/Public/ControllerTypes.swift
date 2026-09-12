import Foundation

/// An opaque physical-controller identity assigned by CoreBluetooth on this Mac.
/// Persist only with the user's consent. It is not a hardware serial, player number,
/// authentication credential, or a cross-Mac identifier. Never include it in default logs.
public struct Switch2ControllerID: Hashable, Codable, Sendable, Identifiable {
    /// The locally scoped identifier. Treat this value as potentially identifying data.
    public let rawValue: UUID
    /// The identity itself, for identifiable collections.
    public var id: Self { self }
    /// Restores an identifier previously saved by the host application.
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Recognized physical Nintendo controller models. A Joy-Con pair remains two devices.
public enum Switch2ControllerModel: UInt16, CaseIterable, Codable, Sendable {
    /// Right Nintendo Joy-Con 2, product 0x2066.
    case joyCon2Right = 0x2066
    /// Left Nintendo Joy-Con 2, product 0x2067.
    case joyCon2Left = 0x2067
    /// Nintendo Switch 2 Pro Controller, product 0x2069.
    case proController2 = 0x2069
    /// Nintendo Switch Online GameCube controller, product 0x2073.
    case nsoGameCube = 0x2073
    /// A model label, not a Bluetooth advertisement's untrusted local name.
    public var displayName: String {
        switch self {
        case .joyCon2Right: return "Joy-Con 2 (R)"
        case .joyCon2Left: return "Joy-Con 2 (L)"
        case .proController2: return "Pro Controller 2"
        case .nsoGameCube: return "NSO GameCube Controller"
        }
    }
    /// Controller-level support. Host application outputs may support fewer features.
    public var capabilities: Switch2ControllerCapabilities {
        var result: Switch2ControllerCapabilities = [.buttons, .battery, .motion, .playerLEDs]
        switch self {
        case .joyCon2Left: result.formUnion([.leftStick, .opticalSensor, .rumble])
        case .joyCon2Right: result.formUnion([.rightStick, .opticalSensor, .rumble])
        case .proController2: result.formUnion([.leftStick, .rightStick, .rumble])
        case .nsoGameCube: result.formUnion([.leftStick, .rightStick, .analogTriggers])
        }
        return result
    }
    package var hasAnalogTriggers: Bool { self == .nsoGameCube }
    package var hasSecondStick: Bool { self == .proController2 || self == .nsoGameCube }
    package var hasHDRumble: Bool { self != .nsoGameCube }
}

/// Capabilities understood by this library, not proof of support in another application.
public struct Switch2ControllerCapabilities: OptionSet, Hashable, Sendable {
    /// Stable option bits; unknown future bits may be ignored.
    public let rawValue: UInt16
    /// Creates a capability set from its bit representation.
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    /// Digital buttons and D-pad directions.
    public static let buttons = Self(rawValue: 1 << 0)
    /// A calibrated left stick.
    public static let leftStick = Self(rawValue: 1 << 1)
    /// A calibrated right stick.
    public static let rightStick = Self(rawValue: 1 << 2)
    /// Independent analog trigger travel, in addition to digital clicks.
    public static let analogTriggers = Self(rawValue: 1 << 3)
    /// Battery voltage and raw charge telemetry.
    public static let battery = Self(rawValue: 1 << 4)
    /// Raw accelerometer, gyroscope and magnetometer telemetry.
    public static let motion = Self(rawValue: 1 << 5)
    /// Raw Joy-Con optical counters and surface telemetry.
    public static let opticalSensor = Self(rawValue: 1 << 6)
    /// Established HD rumble. GameCube preset research is intentionally excluded.
    public static let rumble = Self(rawValue: 1 << 7)
    /// Four player indicator lights; this does not assign a logical player.
    public static let playerLEDs = Self(rawValue: 1 << 8)
}

/// Simultaneous digital controls. Opposing D-pad directions can both be present.
/// GameCube analog travel is separate from its digital L/R trigger clicks.
public struct Switch2Buttons: OptionSet, Hashable, Codable, Sendable {
    /// Controller report bitmask, independent of a host's logical-player mapping.
    public let rawValue: UInt32
    /// Creates a button set from report bits; unknown bits are retained.
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    /// Y face button.
    public static let y = Self(rawValue: 0x0000_0001)
    /// X face button.
    public static let x = Self(rawValue: 0x0000_0002)
    /// B face button.
    public static let b = Self(rawValue: 0x0000_0004)
    /// A face button.
    public static let a = Self(rawValue: 0x0000_0008)
    /// Right Joy-Con rail SR button.
    public static let srR = Self(rawValue: 0x0000_0010)
    /// Right Joy-Con rail SL button.
    public static let slR = Self(rawValue: 0x0000_0020)
    /// R shoulder button.
    public static let r = Self(rawValue: 0x0000_0040)
    /// ZR digital trigger or GameCube R click.
    public static let zr = Self(rawValue: 0x0000_0080)
    /// Minus button.
    public static let minus = Self(rawValue: 0x0000_0100)
    /// Plus button.
    public static let plus = Self(rawValue: 0x0000_0200)
    /// Right stick click.
    public static let rStick = Self(rawValue: 0x0000_0400)
    /// Left stick click.
    public static let lStick = Self(rawValue: 0x0000_0800)
    /// Home button.
    public static let home = Self(rawValue: 0x0000_1000)
    /// Capture button.
    public static let capture = Self(rawValue: 0x0000_2000)
    /// C button.
    public static let c = Self(rawValue: 0x0000_4000)
    /// Down D-pad direction.
    public static let dpadDown = Self(rawValue: 0x0001_0000)
    /// Up D-pad direction.
    public static let dpadUp = Self(rawValue: 0x0002_0000)
    /// Right D-pad direction.
    public static let dpadRight = Self(rawValue: 0x0004_0000)
    /// Left D-pad direction.
    public static let dpadLeft = Self(rawValue: 0x0008_0000)
    /// Left Joy-Con rail SR button.
    public static let srL = Self(rawValue: 0x0010_0000)
    /// Left Joy-Con rail SL button.
    public static let slL = Self(rawValue: 0x0020_0000)
    /// L shoulder button.
    public static let l = Self(rawValue: 0x0040_0000)
    /// ZL digital trigger or GameCube L click.
    public static let zl = Self(rawValue: 0x0080_0000)
    /// GR rear button.
    public static let gr = Self(rawValue: 0x0100_0000)
    /// GL rear button.
    public static let gl = Self(rawValue: 0x0200_0000)
}

/// A calibrated stick position. Each component is clamped to -1...1; zero is center.
/// Positive x is right; positive y is up. No application dead zone is applied.
public struct Switch2Stick: Equatable, Sendable {
    /// Horizontal position in -1...1.
    public let x: Double
    /// Vertical position in -1...1, with up positive.
    public let y: Double
    /// Creates a position, clamping finite components and replacing non-finite ones with zero.
    public init(x: Double = 0, y: Double = 0) {
        self.x = x.isFinite ? min(1, max(-1, x)) : 0
        self.y = y.isFinite ? min(1, max(-1, y)) : 0
    }
}

/// A signed three-axis sensor sample in sensor-native X/Y/Z order.
/// Values are raw counts, NOT calibrated rad/s, m/s², or world-space coordinates.
/// Axes depend on the physical model and orientation; no handedness conversion is implied.
public struct Switch2RawVector3: Equatable, Sendable {
    /// Raw sensor X count.
    public let x: Int16
    /// Raw sensor Y count.
    public let y: Int16
    /// Raw sensor Z count.
    public let z: Int16
    /// Creates a raw sensor vector without calibration or coordinate conversion.
    public init(x: Int16 = 0, y: Int16 = 0, z: Int16 = 0) { self.x = x; self.y = y; self.z = z }
}

/// One trigger's digital click and, where supported, independent analog travel.
public struct Switch2Trigger: Equatable, Sendable {
    /// True while the corresponding ZL/ZR report bit is set.
    public let isPressed: Bool
    /// GameCube travel in 0...1 (raw travel / 255); nil on digital-only models.
    public let travel: Double?
    /// Creates a trigger; finite analog travel is clamped to 0...1.
    public init(isPressed: Bool = false, travel: Double? = nil) {
        self.isPressed = isPressed
        self.travel = travel.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    }
}

/// Battery information from the controller, without claiming a calibrated fuel gauge.
public struct Switch2Battery: Equatable, Sendable {
    /// Battery voltage in millivolts; nil when the report contains zero/unavailable.
    public let millivolts: UInt16?
    /// Raw charge-state byte. Undocumented bit meanings are deliberately not guessed.
    public let chargeStateRaw: UInt8
    /// Signed raw current count; positive means charging. Conversion to amperes is unqualified.
    public let currentRaw: Int16
    /// Rough 0...1 voltage estimate between 3.30 V empty and 4.15 V full; not battery health.
    public var estimatedCharge: Double? {
        millivolts.map { min(1, max(0, (Double($0) - 3300) / 850)) }
    }
    /// Creates battery telemetry. Zero millivolts is treated as unavailable.
    public init(millivolts: UInt16? = nil, chargeStateRaw: UInt8 = 0, currentRaw: Int16 = 0) {
        self.millivolts = millivolts.flatMap { $0 == 0 ? nil : $0 }
        self.chargeStateRaw = chargeStateRaw; self.currentRaw = currentRaw
    }
}

/// Raw motion and thermal telemetry. A zero sample does not prove a sensor is active.
public struct Switch2Motion: Equatable, Sendable {
    /// Accelerometer counts in sensor-native axes; no gravity removal or SI scaling.
    public let accelerationRaw: Switch2RawVector3
    /// Gyroscope counts in sensor-native axes; no bias compensation or SI scaling.
    public let angularVelocityRaw: Switch2RawVector3
    /// Magnetometer counts in sensor-native axes; research reports 0.15 µT/count.
    public let magneticFieldRaw: Switch2RawVector3
    /// Estimated IMU die temperature in degrees Celsius (25 + raw / 127), not ambient temperature.
    public let temperatureCelsius: Double
    /// Creates telemetry without changing coordinate systems.
    public init(accelerationRaw: Switch2RawVector3, angularVelocityRaw: Switch2RawVector3,
                magneticFieldRaw: Switch2RawVector3, temperatureCelsius: Double) {
        self.accelerationRaw = accelerationRaw; self.angularVelocityRaw = angularVelocityRaw
        self.magneticFieldRaw = magneticFieldRaw; self.temperatureCelsius = temperatureCelsius
    }
}

/// Joy-Con optical telemetry, NOT cursor coordinates or a navigation policy.
public struct Switch2OpticalState: Equatable, Sendable {
    /// Raw absolute X counter, wrapping modulo 65536. Convert successive samples using wrap-aware deltas.
    public let xCounter: UInt16
    /// Raw absolute Y counter, wrapping modulo 65536. Its orientation depends on how the Joy-Con is held.
    public let yCounter: UInt16
    /// Raw surface quality count; no portable physical unit is established.
    public let surfaceQualityRaw: UInt16
    /// Raw lift-distance count; not a distance in millimeters.
    public let liftDistanceRaw: UInt16
    /// Creates a raw optical sample.
    public init(xCounter: UInt16, yCounter: UInt16, surfaceQualityRaw: UInt16, liftDistanceRaw: UInt16) {
        self.xCounter = xCounter; self.yCounter = yCounter
        self.surfaceQualityRaw = surfaceQualityRaw; self.liftDistanceRaw = liftDistanceRaw
    }
}

/// An immutable, calibrated physical-controller input snapshot.
/// Values describe the device, before remapping, dead zones, Joy-Con grouping, or output conversion.
public struct Switch2ControllerState: Equatable, Sendable {
    /// Held digital controls, including D-pad and trigger clicks.
    public let buttons: Switch2Buttons
    /// Calibrated left stick, or nil when physically absent.
    public let leftStick: Switch2Stick?
    /// Calibrated right stick, or nil when physically absent.
    public let rightStick: Switch2Stick?
    /// Left digital click and optional analog travel.
    public let leftTrigger: Switch2Trigger
    /// Right digital click and optional analog travel.
    public let rightTrigger: Switch2Trigger
    /// Voltage and raw charge telemetry.
    public let battery: Switch2Battery
    /// Raw motion telemetry, or nil when the selected sensor configuration does not request it.
    public let motion: Switch2Motion?
    /// Raw optical telemetry, only on a Joy-Con with optical sensing requested.
    public let optical: Switch2OpticalState?
    /// Host monotonic receive time in seconds since boot; never compare across machines or boots.
    public let receivedAt: TimeInterval
    /// Creates an input value, useful for host adapters and deterministic tests.
    public init(buttons: Switch2Buttons = [], leftStick: Switch2Stick? = nil,
                rightStick: Switch2Stick? = nil, leftTrigger: Switch2Trigger = .init(),
                rightTrigger: Switch2Trigger = .init(), battery: Switch2Battery = .init(),
                motion: Switch2Motion? = nil, optical: Switch2OpticalState? = nil,
                receivedAt: TimeInterval = 0) {
        self.buttons = buttons; self.leftStick = leftStick; self.rightStick = rightStick
        self.leftTrigger = leftTrigger; self.rightTrigger = rightTrigger; self.battery = battery
        self.motion = motion; self.optical = optical; self.receivedAt = receivedAt
    }
}

/// Controller housing/button color in eight-bit sRGB components, without an alpha channel.
public struct Switch2Color: Equatable, Sendable {
    /// Red component in 0...255.
    public let red: UInt8
    /// Green component in 0...255.
    public let green: UInt8
    /// Blue component in 0...255.
    public let blue: UInt8
    /// Creates an opaque sRGB color.
    public init(red: UInt8, green: UInt8, blue: UInt8) { self.red = red; self.green = green; self.blue = blue }
}

/// An immutable snapshot of one physical controller. It never exposes a peripheral or session.
public struct Switch2Controller: Identifiable, Equatable, Sendable {
    /// Locally scoped physical identity, independent of player assignment.
    public let id: Switch2ControllerID
    /// Verified controller model from its identity block.
    public let model: Switch2ControllerModel
    /// Supported controller operations; this is not a system-wide gamepad registration.
    public var capabilities: Switch2ControllerCapabilities { model.capabilities }
    /// A safe model label. Hosts may maintain their own user-chosen names.
    public var name: String { model.displayName }
    /// The most recent complete input report; ready snapshots always have one.
    public let state: Switch2ControllerState
    /// Connection readiness; connected snapshots represent usable, first-report-ready devices.
    public let connectionState: Switch2ConnectionState
    /// Host wall-clock time when handshake and first report both became ready.
    public let connectedAt: Date
    /// Housing color supplied by the controller identity block.
    public let bodyColor: Switch2Color?
    /// Button color supplied by the controller identity block.
    public let buttonColor: Switch2Color?
    /// Hardware serial only when the host explicitly enables identity access. Nil by default.
    /// Never log this automatically. No raw identity or serial is passed to the diagnostic handler.
    public let serialNumber: String?
    package let sessionGeneration: UUID
    package let lastActivityAt: TimeInterval
    package init(id: Switch2ControllerID, model: Switch2ControllerModel, state: Switch2ControllerState,
                 connectedAt: Date, bodyColor: Switch2Color?, buttonColor: Switch2Color?, serialNumber: String?,
                 sessionGeneration: UUID, lastActivityAt: TimeInterval) {
        self.id = id; self.model = model; self.state = state; self.connectedAt = connectedAt
        self.connectionState = .ready; self.bodyColor = bodyColor; self.buttonColor = buttonColor
        self.serialNumber = serialNumber
        self.sessionGeneration = sessionGeneration; self.lastActivityAt = lastActivityAt
    }
}
