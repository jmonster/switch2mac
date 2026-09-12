import Foundation

// Only the optional orchestration boundary is a fake. Commands, status handling,
// audio serialization and finite rumble execute the real experimental companion.
final class ExperimentalOperations { func cancel() {} }

extension ControllerSession {
    var experimentalFixture: ExperimentalControllerSession {
        if let value = companion as? ExperimentalControllerSession { return value }
        let value = ExperimentalControllerSession(base: self)
        companion = value
        return value
    }
    func experimentalCommand(_ command: UInt8, _ subcommand: UInt8, payload: Data,
                             flag: UInt8 = 0x01, completion: @escaping (Data?) -> Void) {
        experimentalFixture.experimentalCommand(command, subcommand, payload: payload, flag: flag, completion: completion)
    }
    func experimentalCommandResult(_ command: UInt8, _ subcommand: UInt8, payload: Data,
                                   flag: UInt8 = 0x01, completion: @escaping (CommandResult) -> Void) {
        experimentalFixture.experimentalCommandResult(command, subcommand, payload: payload, flag: flag, completion: completion)
    }
    func testRumble(intensity: Double) { experimentalFixture.testRumble(intensity: intensity) }
    var lastRumbleTestAt: TimeInterval {
        get { experimentalFixture.lastRumbleTestAt }
        set { experimentalFixture.lastRumbleTestAt = newValue }
    }
}
