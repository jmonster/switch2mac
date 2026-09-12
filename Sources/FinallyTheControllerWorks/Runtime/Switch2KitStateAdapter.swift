import Switch2Kit

// Application-owned conversion; no protocol decoding or transport ownership.
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
