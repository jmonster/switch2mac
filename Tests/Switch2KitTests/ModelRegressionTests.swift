import Foundation
import XCTest
import Switch2Kit

// Consolidates the compatible value-level regressions from draft PR #40.
// These tests are synthetic fixtures, not evidence of physical controller support.
final class ModelRegressionTests: XCTestCase {
    func testEveryPhysicalModelHasTheCorrectSticksAndRumbleBoundary() {
        XCTAssertEqual(Set(Switch2ControllerModel.allCases.map(\.rawValue)), [0x2066, 0x2067, 0x2069, 0x2073])
        for model in Switch2ControllerModel.allCases {
            XCTAssertEqual(model.capabilities.contains(.leftStick), model != .joyCon2Right)
            XCTAssertEqual(model.capabilities.contains(.rightStick), model != .joyCon2Left)
            XCTAssertEqual(model.capabilities.contains(.analogTriggers), model == .nsoGameCube)
            XCTAssertEqual(model.capabilities.contains(.rumble), model != .nsoGameCube)
            XCTAssertEqual(model.capabilities.contains(.opticalSensor), model == .joyCon2Left || model == .joyCon2Right)
        }
    }

    func testKnownButtonBitsAreUniqueAndUnknownBitsSurvive() {
        let buttons: [Switch2Buttons] = [.a, .b, .x, .y, .dpadUp, .dpadDown, .dpadLeft, .dpadRight,
            .l, .r, .zl, .zr, .minus, .plus, .home, .capture, .c, .lStick, .rStick, .gl, .gr,
            .slL, .srL, .slR, .srR]
        XCTAssertEqual(buttons.count, 25)
        XCTAssertEqual(Set(buttons.map(\.rawValue)).count, buttons.count)
        XCTAssertTrue(buttons.allSatisfy { $0.rawValue.nonzeroBitCount == 1 })
        XCTAssertEqual(Switch2Buttons(rawValue: 0x8000_0000).rawValue, 0x8000_0000)
        let opposing: Switch2Buttons = [.dpadUp, .dpadDown]
        XCTAssertTrue(opposing.contains(.dpadUp) && opposing.contains(.dpadDown))
    }

    func testEveryTriggerTravelValueIsIndependentOfDigitalClick() {
        for raw in UInt8.min...UInt8.max {
            let trigger = Switch2Trigger(isPressed: false, travel: Double(raw) / 255)
            XCTAssertEqual(trigger.travel, Double(raw) / 255)
            XCTAssertFalse(trigger.isPressed)
        }
        XCTAssertTrue(Switch2Trigger(isPressed: true, travel: 0).isPressed)
        XCTAssertNil(Switch2Trigger(isPressed: true).travel)
    }

    func testBatteryEstimatesAndRawMotionDoNotInventUnits() {
        XCTAssertEqual(Switch2Battery(millivolts: 3000).estimatedCharge, 0)
        XCTAssertEqual(Switch2Battery(millivolts: 4150).estimatedCharge, 1)
        XCTAssertEqual(Switch2Battery(millivolts: 5000).estimatedCharge, 1)
        let raw = Switch2RawVector3(x: -10, y: 20, z: 30)
        let motion = Switch2Motion(accelerationRaw: raw, angularVelocityRaw: raw,
            magneticFieldRaw: raw, temperatureCelsius: 25)
        XCTAssertEqual(motion.angularVelocityRaw, raw)
        XCTAssertEqual(motion.accelerationRaw, raw)
    }

    func testIdentityRoundTripAndPrivacyDefaults() throws {
        let id = Switch2ControllerID(rawValue: UUID())
        XCTAssertEqual(try JSONDecoder().decode(Switch2ControllerID.self, from: JSONEncoder().encode(id)), id)
        XCTAssertFalse(Switch2ControllerConfiguration().includeSerialNumbers)
        XCTAssertEqual(Switch2ControllerConfiguration().discoveryMode, .onDemand)
        let empty = Switch2ControllerState()
        XCTAssertNil(empty.leftStick)
        XCTAssertNil(empty.rightStick)
        XCTAssertNil(empty.motion)
        XCTAssertNil(empty.optical)
        XCTAssertNil(empty.battery.millivolts)
    }
}
