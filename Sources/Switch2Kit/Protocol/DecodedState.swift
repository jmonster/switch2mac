import Foundation

// Package-internal compatibility value for legacy adapters; never exposed in the stable API.
package struct ControllerState: Sendable {
    package var buttons: Switch2.Buttons = []
    package var leftStick: (x: Double, y: Double) = (0, 0)
    package var rightStick: (x: Double, y: Double) = (0, 0)
    package var leftTrigger: UInt8 = 0    // 0...255
    package var rightTrigger: UInt8 = 0
    package var batteryMillivolts: UInt16 = 0
    package var gyro: (Int16, Int16, Int16) = (0, 0, 0)
    package var accel: (Int16, Int16, Int16) = (0, 0, 0)
    /// Optical mouse raw absolute counters (Joy-Con 2; wrap mod 2^16).
    package var mouseX: UInt16 = 0
    package var mouseY: UInt16 = 0
    package var surfaceQuality: UInt16 = 0
    package var liftDistance: UInt16 = 0
    /// Magnetometer raw (0.15 µT/LSB).
    package var mag: (Int16, Int16, Int16) = (0, 0, 0)
    /// Battery/thermal: charge state byte, signed current (+charging),
    /// IMU die temperature in °C.
    package var chargeState: UInt8 = 0
    package var batteryCurrent: Int16 = 0
    package var temperatureC: Double = 0
    package init() {}

    package func snapshot(model: Switch2ControllerModel, receivedAt: TimeInterval,
                          sensorProfile: Switch2.Feature.SensorProfile = .compatibility) -> Switch2ControllerState {
        let flags = Switch2.Feature.flags(for: model, profile: sensorProfile)
        return Switch2ControllerState(buttons: buttons,
            leftStick: model.capabilities.contains(.leftStick) ? .init(x: leftStick.x, y: leftStick.y) : nil,
            rightStick: model.capabilities.contains(.rightStick) ? .init(x: rightStick.x, y: rightStick.y) : nil,
            leftTrigger: .init(isPressed: buttons.contains(.zl), travel: model.hasAnalogTriggers ? Double(leftTrigger) / 255 : nil),
            rightTrigger: .init(isPressed: buttons.contains(.zr), travel: model.hasAnalogTriggers ? Double(rightTrigger) / 255 : nil),
            battery: .init(millivolts: batteryMillivolts, chargeStateRaw: chargeState, currentRaw: batteryCurrent),
            motion: flags & Switch2.Feature.motion != 0 ? .init(
                accelerationRaw: .init(x: accel.0, y: accel.1, z: accel.2),
                angularVelocityRaw: .init(x: gyro.0, y: gyro.1, z: gyro.2),
                magneticFieldRaw: .init(x: mag.0, y: mag.1, z: mag.2), temperatureCelsius: temperatureC) : nil,
            optical: flags & Switch2.Feature.mouse != 0 ? .init(xCounter: mouseX, yCounter: mouseY,
                surfaceQualityRaw: surfaceQuality, liftDistanceRaw: liftDistance) : nil,
            receivedAt: receivedAt)
    }
}
