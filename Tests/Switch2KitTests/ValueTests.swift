import Foundation
import XCTest
import Switch2Kit

final class ValueTests: XCTestCase {
    func testAllSupportedPhysicalModelsAndCapabilities() {
        XCTAssertEqual(Set(Switch2ControllerModel.allCases.map(\.rawValue)), [0x2066, 0x2067, 0x2069, 0x2073])
        XCTAssertFalse(Switch2ControllerModel.joyCon2Right.capabilities.contains(.leftStick))
        XCTAssertFalse(Switch2ControllerModel.joyCon2Left.capabilities.contains(.rightStick))
        XCTAssertTrue(Switch2ControllerModel.proController2.capabilities.isSuperset(of: [.leftStick, .rightStick, .rumble]))
        XCTAssertTrue(Switch2ControllerModel.nsoGameCube.hasAnalogTriggers)
        XCTAssertFalse(Switch2ControllerModel.nsoGameCube.capabilities.contains(.rumble))
        XCTAssertTrue(Switch2ControllerModel.joyCon2Left.capabilities.contains(.opticalSensor))
    }
    func testButtonMasksAreUniqueAndPreserveUnknownBits() {
        let masks = Switch2Buttons.allCases.map(\.rawValue)
        XCTAssertEqual(masks.count, 25)
        XCTAssertEqual(Set(masks).count, masks.count)
        XCTAssertTrue(masks.allSatisfy { $0.nonzeroBitCount == 1 })
        let both: Switch2Buttons = [.dpadUp, .dpadDown, .zl, .zr]
        XCTAssertTrue(both.contains(.dpadUp) && both.contains(.dpadDown))
        XCTAssertEqual(Switch2Buttons(rawValue: 0x8000_0000).rawValue, 0x8000_0000)
        XCTAssertEqual(Switch2Buttons.a.displayName, "A")
    }
    func testTriggerTravelDoesNotInventDigitalClicks() {
        for raw in UInt8.min...UInt8.max {
            let trigger = Switch2TriggerState(rawValue: raw, isAnalog: true, isPressed: false)
            XCTAssertEqual(trigger.value, Double(raw) / 255)
            XCTAssertFalse(trigger.isPressed)
        }
        XCTAssertTrue(Switch2TriggerState(rawValue: 0, isAnalog: true, isPressed: true).isPressed)
    }
    func testBatteryAndMotionUnitsAreExplicit() {
        XCTAssertEqual(Switch2BatteryState(millivolts: 3000).estimatedPercent, 0)
        XCTAssertEqual(Switch2BatteryState(millivolts: 4150).estimatedPercent, 100)
        XCTAssertEqual(Switch2BatteryState(millivolts: 5000).estimatedPercent, 100)
        XCTAssertEqual(Switch2BatteryState(millivolts: 4000).volts, 4)
        let raw = Switch2RawVector3(x: -10, y: 20, z: 30)
        let motion = Switch2MotionState(gyroscopeRaw: raw, accelerometerRaw: raw,
                                       magnetometerRaw: raw, temperatureCelsius: 25)
        XCTAssertEqual(motion.gyroscopeRaw, raw)
        XCTAssertEqual(motion.magneticFieldMicroteslas, .init(x: -1.5, y: 3, z: 4.5))
    }
    func testPrivacyAndRememberedCapacityDefaults() throws {
        let ids = (0..<80).map { _ in Switch2ControllerID(rawValue: UUID()) }
        let config = Switch2Configuration(rememberedControllers: ids + ids)
        XCTAssertFalse(config.exposesSerialNumbers)
        XCTAssertEqual(config.discoveryMode, .onDemand)
        XCTAssertEqual(config.rememberedControllers, Array(ids.prefix(32)))
        let encoded = try JSONEncoder().encode(ids[0])
        XCTAssertEqual(try JSONDecoder().decode(Switch2ControllerID.self, from: encoded), ids[0])
    }
    func testOptionalInputsAndNamedValuesRoundTrip() throws {
        let empty = Switch2ControllerState()
        XCTAssertNil(empty.leftStick); XCTAssertNil(empty.rightStick)
        XCTAssertNil(empty.motion); XCTAssertNil(empty.battery); XCTAssertNil(empty.opticalSensor)
        let state = Switch2ControllerState(sequence: 42, timestamp: 123.5, buttons: [.a, .zl],
            leftStick: .init(position: .init(x: -1, y: 1), rawX: 0, rawY: 4095, isCalibrated: true),
            leftTrigger: .init(rawValue: 127, isAnalog: true, isPressed: true),
            battery: .init(millivolts: 4000, chargeStateRaw: 2, currentRaw: -10))
        XCTAssertEqual(try JSONDecoder().decode(Switch2ControllerState.self, from: JSONEncoder().encode(state)), state)
    }
    func testReadyFilterAndConnectionGenerationIdentity() {
        let id = Switch2ControllerID(rawValue: UUID())
        let waiting = Switch2Controller(id: id, connectionID: UUID(), model: .proController2,
            capabilities: [], connectionState: .handshaking)
        let ready = Switch2Controller(id: id, connectionID: UUID(), model: .proController2,
            capabilities: .rumble, connectionState: .ready)
        XCTAssertNotEqual(waiting.connectionID, ready.connectionID)
        XCTAssertEqual(Switch2ManagerSnapshot(controllers: [waiting, ready]).connectedControllers, [ready])
    }
}
