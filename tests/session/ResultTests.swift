import Foundation

private final class ResultDelegate: ControllerSessionDelegate {
    var failures = 0
    func sessionReady(_ session: ControllerSession) {}
    func sessionFailed(_ session: ControllerSession, reason: String) { failures += 1 }
    func sessionDidUpdateState(_ session: ControllerSession) {}
}
@main private enum ResultTests {
    static func main() {
        let radio = CBPeripheral(), queue = DispatchQueue(label: "result-tests"), delegate = ResultDelegate()
        let session = ControllerSession(peripheral: radio, slot: 0, wasPairingMode: false,
                                        queue: queue, delegate: delegate)
        queue.sync {
            var failures: [ControllerSession.CommandFailure] = []
            func capture(_ result: ControllerSession.CommandResult) {
                guard case .failure(let failure) = result else { fatalError("expected typed failure") }
                failures.append(failure)
            }
            session.experimentalCommandResult(1, 5, payload: Data(), completion: capture)
            guard case .unavailable = failures.removeLast() else { fatalError("wrong missing-characteristic result") }
            session.chars[Switch2.GATT.commandWrite] = CBCharacteristic(Switch2.GATT.commandWrite)
            session.experimentalCommandResult(1, 5, payload: Data(count: 256), completion: capture)
            guard case .payloadTooLarge = failures.removeLast() else { fatalError("wrong payload failure") }
            radio.writeLimit = 8
            session.experimentalCommandResult(1, 5, payload: Data([1]), completion: capture)
            guard case .frameTooLarge = failures.removeLast() else { fatalError("wrong MTU failure") }
            radio.writeLimit = 180
            let frame = Data([1, 2, 1, 5, 0x10, 0x78, 0, 0, 7, 0x41])
            session.experimentalCommandResult(1, 5, payload: Data(), completion: capture)
            session.handleCommandResponse((Data([0xff]) + frame).dropFirst())
            guard case .rejected(let response) = failures.removeLast() else { fatalError("status lost") }
            precondition(response.kind == .status && response.header == frame.prefix(8))
            precondition(response.payload == frame.suffix(2) && response.command == 1 && response.subcommand == 5)
            session.experimentalCommandResult(1, 5, payload: Data(), completion: capture)
            session.commandTimeout!.perform()
            guard case .timeout = failures.removeLast() else { fatalError("timeout lost") }
            precondition(delegate.failures == 1 && session.isRetired)
            session.experimentalCommandResult(1, 5, payload: Data(), completion: capture)
            guard case .retired = failures.removeLast() else { fatalError("retirement lost") }
            precondition(failures.isEmpty)
        }
        print("PASS typed unavailable, payload, MTU, status/header preservation, timeout and retirement outcomes")
    }
}
