import Foundation

final class PowerDelegate: ControllerSessionDelegate {
    func sessionReady(_ session: ControllerSession) {}
    func sessionFailed(_ session: ControllerSession, reason: String) {}
    func sessionDidUpdateState(_ session: ControllerSession) {}
}
@main enum PowerTests {
    static func main() {
        typealias Profile = Switch2.Feature.SensorProfile
        let expected = Profile(rawValue: CommandLine.arguments[1])!
        precondition(ApplicationSensorPolicy.selectedProfile == expected)
        for profile in Profile.allCases {
            precondition(Profile.resolve(profile.rawValue, acknowledged: false) == .compatibility)
            precondition(Profile.resolve(profile.rawValue, acknowledged: true) == profile)
            for model in Switch2.Model.allCases {
                let optical = model == .joyCon2Left || model == .joyCon2Right
                let flags = Switch2.Feature.flags(for: model, profile: profile)
                let wanted: UInt8
                switch profile {
                case .compatibility: wanted = optical ? 0xB7 : 0xA7
                case .gamepad: wanted = 0x23
                case .motion: wanted = 0x27
                case .pointer: wanted = optical ? 0x33 : 0x23
                }
                precondition(flags == wanted && flags & 0x23 == 0x23)
                precondition(optical || flags & 0x10 == 0)
            }
        }
        for bad in ["", "ALL", "0xFF", "255", "gamepad,mouse", String(repeating: "x", count: 1000)] {
            precondition(Profile.resolve(bad, acknowledged: true) == .compatibility)
        }
        // Execute the real ControllerSession command writer and both feature
        // handshake steps against its existing fake CoreBluetooth boundary.
        for model in Switch2.Model.allCases {
            let radio = CBPeripheral(), queue = DispatchQueue(label: "power-profile-test")
            let delegate = PowerDelegate()
            let session = ControllerSession(peripheral: radio, slot: 0, wasPairingMode: false,
                                            queue: queue, delegate: delegate, sensorProfile: ApplicationSensorPolicy.selectedProfile)
            session.model = model
            session.chars[Switch2.GATT.commandWrite] = CBCharacteristic(Switch2.GATT.commandWrite)
            queue.sync {
                var completed = false
                session.stepFeatures { completed = $0 }
                precondition(radio.writes.count == 1 && !completed)
                session.handleCommandResponse(Data([0x0C, 1, 1, 2, 0x10, 0x78, 0, 0, 0, 0, 0, 0]))
                precondition(radio.writes.count == 2 && !completed)
                session.handleCommandResponse(Data([0x0C, 1, 1, 4, 0x10, 0x78, 0, 0, 0, 0, 0, 0]))
                precondition(completed)
                let flags = Switch2.Feature.flags(for: model, profile: expected)
                for (index, write) in radio.writes.enumerated() {
                    precondition(write.0 == Switch2.buildCommand(0x0C, index == 0 ? 2 : 4,
                                                                 data: Data([flags, 0, 0, 0])))
                }
                session.teardown()
            }
            withExtendedLifetime(delegate) {}
        }
        print("PASS all sensor masks, explicit opt-in and real feature handshake for " + expected.rawValue)
    }
}
