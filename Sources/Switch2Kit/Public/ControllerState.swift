import Foundation

/// Two-dimensional normalized coordinates. Sticks use -1...1: +x right, +y up.
/// No application dead zone, inversion, mapping, or Joy-Con rotation is applied.
public struct Switch2Vector2: Equatable, Codable, Sendable {
    /// Horizontal component; normalized stick values are in -1...1.
    public let x: Double
    /// Vertical component; normalized stick values are in -1...1.
    public let y: Double
    /// Creates a vector. Values are not implicitly clamped or reoriented.
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    /// The origin.
    public static let zero = Self(x: 0, y: 0)
}

/// A three-dimensional physical vector; its containing field documents units and axes.
public struct Switch2Vector3: Equatable, Codable, Sendable {
    /// X component in the containing field's units.
    public let x: Double
    /// Y component in the containing field's units.
    public let y: Double
    /// Z component in the containing field's units.
    public let z: Double
    /// Creates a vector without converting units or axes.
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
}

/// Raw signed sensor counts, in the controller's native report coordinate frame.
/// Axes are not transformed into screen/world coordinates. Cross-model orientation
/// and gyro/accelerometer sensitivity have not been qualified by this library.
public struct Switch2RawVector3: Equatable, Codable, Sendable {
    /// Native X count (-32768...32767).
    public let x: Int16
    /// Native Y count (-32768...32767).
    public let y: Int16
    /// Native Z count (-32768...32767).
    public let z: Int16
    /// Creates a raw sample, for example for an input fixture.
    public init(x: Int16, y: Int16, z: Int16) { self.x = x; self.y = y; self.z = z }
}

/// A physical stick's raw and normalized positions.
public struct Switch2StickState: Equatable, Codable, Sendable {
    /// Calibrated -1...1 coordinates (+x right, +y up), with no application dead zone.
    public let position: Switch2Vector2
    /// Native 12-bit horizontal count (0...4095).
    public let rawX: UInt16
    /// Native 12-bit vertical count (0...4095).
    public let rawY: UInt16
    /// True when usable user/factory calibration was read; false means nominal
    /// normalization around 2048, not a claim of factory accuracy.
    public let isCalibrated: Bool
    /// Creates a stick snapshot. Callers constructing fixtures supply documented ranges.
    public init(position: Switch2Vector2, rawX: UInt16, rawY: UInt16, isCalibrated: Bool) {
        self.position = position; self.rawX = rawX; self.rawY = rawY; self.isCalibrated = isCalibrated
    }
}

/// Trigger travel and the independently decoded digital trigger bit.
public struct Switch2TriggerState: Equatable, Codable, Sendable {
    /// Travel in 0...255. Digital-only models use exactly 0 or 255.
    public let rawValue: UInt8
    /// Whether `rawValue` represents analog travel (GameCube) rather than a digital approximation.
    public let isAnalog: Bool
    /// The corresponding ZL/ZR report bit. This is not inferred from travel.
    /// Other model-specific click/shoulder bits remain available in `buttons`.
    public let isPressed: Bool
    /// Travel normalized to 0...1; independent of `isPressed` on analog models.
    public var value: Double { Double(rawValue) / 255 }
    /// Creates a trigger snapshot; no analog-click threshold is synthesized.
    public init(rawValue: UInt8 = 0, isAnalog: Bool = false, isPressed: Bool = false) {
        self.rawValue = rawValue; self.isAnalog = isAnalog; self.isPressed = isPressed
    }
}

/// Battery telemetry. The voltage-derived percentage is an estimate, not a fuel-gauge reading.
public struct Switch2BatteryState: Equatable, Codable, Sendable {
    /// Measured battery voltage in millivolts. A zero report is represented by absent battery state.
    public let millivolts: UInt16
    /// Uninterpreted report charge-state byte. Bit meanings are not asserted by the stable API.
    public let chargeStateRaw: UInt8
    /// Signed current count; positive values have been observed while charging.
    /// The physical current scale is not established here; do not label this value milliamperes.
    public let currentRaw: Int16
    /// Voltage in volts.
    public var volts: Double { Double(millivolts) / 1000 }
    /// Rough 0...100 estimate using 3300 mV empty and 4150 mV full, clamped at the ends.
    public var estimatedPercent: Int { min(100, max(0, Int((Double(millivolts) - 3300) / 850 * 100))) }
    /// Creates a battery sample without converting the raw charge/current fields.
    public init(millivolts: UInt16, chargeStateRaw: UInt8 = 0, currentRaw: Int16 = 0) {
        self.millivolts = millivolts; self.chargeStateRaw = chargeStateRaw; self.currentRaw = currentRaw
    }
}

/// Native motion telemetry. No fusion, bias correction, or world-frame transformation is applied.
public struct Switch2MotionState: Equatable, Codable, Sendable {
    /// Raw gyroscope counts; not radians/second or degrees/second.
    public let gyroscopeRaw: Switch2RawVector3
    /// Raw accelerometer counts; not metres/second squared or g.
    public let accelerometerRaw: Switch2RawVector3
    /// Raw magnetometer counts when requested/available; 0.15 microtesla per count.
    public let magnetometerRaw: Switch2RawVector3?
    /// Approximate IMU die temperature in degrees Celsius, decoded as 25 + raw/127.
    /// This is not ambient/controller-surface temperature.
    public let temperatureCelsius: Double
    /// Magnetic field in microteslas in native report axes; nil when the sensor is unavailable.
    public var magneticFieldMicroteslas: Switch2Vector3? {
        magnetometerRaw.map { .init(x: Double($0.x) * 0.15, y: Double($0.y) * 0.15, z: Double($0.z) * 0.15) }
    }
    /// Creates a motion sample with explicitly raw gyroscope/accelerometer values.
    public init(gyroscopeRaw: Switch2RawVector3, accelerometerRaw: Switch2RawVector3,
                magnetometerRaw: Switch2RawVector3? = nil, temperatureCelsius: Double) {
        self.gyroscopeRaw = gyroscopeRaw; self.accelerometerRaw = accelerometerRaw
        self.magnetometerRaw = magnetometerRaw; self.temperatureCelsius = temperatureCelsius
    }
}

/// Joy-Con 2 optical telemetry, without mouse/navigation policy.
public struct Switch2OpticalState: Equatable, Codable, Sendable {
    /// Free-running horizontal counter, wrapping modulo 65536. Not pixels or velocity.
    public let xCounter: UInt16
    /// Free-running vertical counter, wrapping modulo 65536. Native sensor orientation is retained.
    public let yCounter: UInt16
    /// Raw surface-quality/roughness reading. Lower values have indicated better tracking.
    public let surfaceQualityRaw: UInt16
    /// Raw lift reading; zero means no surface reference. Physical distance units are not established.
    public let liftDistanceRaw: UInt16
    /// Creates a raw optical sample. Hosts decide how to handle wrap, lift, and orientation.
    public init(xCounter: UInt16, yCounter: UInt16, surfaceQualityRaw: UInt16, liftDistanceRaw: UInt16) {
        self.xCounter = xCounter; self.yCounter = yCounter
        self.surfaceQualityRaw = surfaceQualityRaw; self.liftDistanceRaw = liftDistanceRaw
    }
}

/// An immutable, calibrated physical-controller report. Safe to transfer between actors.
/// Optional fields distinguish absent/not-requested features from a valid zero reading.
public struct Switch2ControllerState: Equatable, Codable, Sendable {
    /// Per-connection sequence, starting at one. Gaps in a stream indicate dropped reports.
    public let sequence: UInt64
    /// Host monotonic receipt time in seconds (`ProcessInfo.systemUptime`), not wall-clock time.
    public let timestamp: TimeInterval
    /// Native 32-bit timestamp/counter. Its clock units are not asserted; it may wrap.
    public let deviceTimestamp: UInt32
    /// All reported button bits, including D-pad and digital trigger/click bits.
    public let buttons: Switch2Buttons
    /// Left stick, or nil on a right Joy-Con.
    public let leftStick: Switch2StickState?
    /// Right stick, or nil on a left Joy-Con.
    public let rightStick: Switch2StickState?
    /// Left trigger travel and digital ZL state.
    public let leftTrigger: Switch2TriggerState
    /// Right trigger travel and digital ZR state.
    public let rightTrigger: Switch2TriggerState
    /// Battery telemetry, or nil when the reported voltage is zero/unavailable.
    public let battery: Switch2BatteryState?
    /// Motion telemetry when enabled; native axes and raw gyro/accelerometer counts.
    public let motion: Switch2MotionState?
    /// Optical telemetry on supported Joy-Cons when enabled; not pointer events.
    public let opticalSensor: Switch2OpticalState?
    /// Creates a complete immutable snapshot, also useful for testing in-process input consumers.
    public init(sequence: UInt64 = 0, timestamp: TimeInterval = 0, deviceTimestamp: UInt32 = 0,
                buttons: Switch2Buttons = [], leftStick: Switch2StickState? = nil,
                rightStick: Switch2StickState? = nil, leftTrigger: Switch2TriggerState = .init(),
                rightTrigger: Switch2TriggerState = .init(), battery: Switch2BatteryState? = nil,
                motion: Switch2MotionState? = nil, opticalSensor: Switch2OpticalState? = nil) {
        self.sequence = sequence; self.timestamp = timestamp; self.deviceTimestamp = deviceTimestamp
        self.buttons = buttons; self.leftStick = leftStick; self.rightStick = rightStick
        self.leftTrigger = leftTrigger; self.rightTrigger = rightTrigger; self.battery = battery
        self.motion = motion; self.opticalSensor = opticalSensor
    }
}
