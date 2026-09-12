import Foundation

private final class ResponseDelegate: ControllerSessionDelegate {
    var ready = 0, failures = 0
    func sessionReady(_ session: ControllerSession) { ready += 1 }
    func sessionFailed(_ session: ControllerSession, reason: String) { failures += 1 }
    func sessionDidUpdateState(_ session: ControllerSession) {}
}

@main private enum ResponseTests {
    static func frame(_ command: UInt8, _ subcommand: UInt8, kind: UInt8 = 1,
                      transport: UInt8 = 1, payload: Data = Data()) -> Data {
        Data([command, kind, transport, subcommand, 0x10, 0x78, 0, 0]) + payload
    }
    static func main() {
        let selected = CommandLine.arguments.last ?? "all"
        func test(_ name: String, _ body: (ControllerSession, CBPeripheral, ResponseDelegate) -> Void) {
            guard selected == "all" || selected == name else { return }
            let radio = CBPeripheral(), queue = DispatchQueue(label: "response-tests"), delegate = ResponseDelegate()
            let session = ControllerSession(peripheral: radio, slot: 0, wasPairingMode: true,
                                            queue: queue, delegate: delegate)
            session.chars[Switch2.GATT.commandWrite] = CBCharacteristic(Switch2.GATT.commandWrite)
            session.chars[Switch2.GATT.inputReport] = CBCharacteristic(Switch2.GATT.inputReport)
            queue.sync { body(session, radio, delegate); session.teardown() }
            print("PASS response \(name)")
        }
        test("status-is-not-success") { s, _, _ in
            var result: Bool?
            s.stepPlayerLEDs { result = $0 }
            s.handleCommandResponse(frame(9, 7, kind: 2, payload: Data([7])))
            precondition(result == false && s.pendingCommand == nil, "status/error ACK was treated as LED success")
        }
        test("subcommand-and-transport") { s, _, _ in
            var result: Bool?
            s.stepPlayerLEDs { result = $0 }
            let token = s.pendingCommand!.token
            s.handleCommandResponse(frame(9, 8))
            s.handleCommandResponse(frame(9, 7, transport: 0))
            s.handleCommandResponse(frame(8, 7))
            precondition(result == nil && s.pendingCommand?.token == token, "unrelated header consumed transaction")
            // Nonzero slice index, and a legitimate payload-free LED ACK.
            s.handleCommandResponse((Data([0xff]) + frame(9, 7)).dropFirst())
            precondition(result == true && s.pendingCommand == nil)
        }
        test("feature-rejection") { s, radio, _ in
            var results: [Bool] = []
            s.stepFeatures { results.append($0) }
            s.handleCommandResponse(frame(0x0c, 2, kind: 2))
            precondition(results == [false] && radio.writes.count == 1, "rejected init still enabled features")
            s.stepFeatures { results.append($0) }
            s.handleCommandResponse(frame(0x0c, 2, payload: Data(repeating: 0, count: 4)))
            let writes = radio.writes.count
            s.handleCommandResponse(frame(0x0c, 2)) // delayed init must not complete enable
            precondition(results == [false] && s.pendingCommand != nil)
            s.handleCommandResponse(frame(0x0c, 4, kind: 2))
            precondition(results == [false, false] && radio.writes.count == writes)
        }
        test("memory-rejection") { s, _, _ in
            var calls = 0
            s.readMemory(length: 11, address: 0x13000) { result in
                calls += 1; precondition(result == nil)
            }
            s.handleCommandResponse(frame(2, 4, kind: 2, payload: Data([7])))
            precondition(calls == 1 && s.pendingCommand == nil, "short memory error ignored until timeout")
        }
        test("bond-rejection") { s, radio, _ in
            IOBluetoothHostController.testAddress = "01:23:45:67:89:ab"
            defer { IOBluetoothHostController.testAddress = nil }
            for stage in 0..<4 {
                var result: Bool?
                let start = radio.writes.count
                s.stepBond { result = $0 }
                let subs: [UInt8] = [1, 4, 2, 3]
                for i in 0...stage {
                    s.handleCommandResponse(frame(0x15, subs[i], kind: i == stage ? 2 : 1,
                                                  payload: Data([1])))
                }
                precondition(result == false && radio.writes.count == start + stage + 1)
            }
        }
        test("malformed-and-reentrancy") { s, radio, _ in
            var calls = 0
            s.writeCommand(9, 7, Data()) { _ in
                calls += 1
                s.writeCommand(0x0c, 4, Data()) { _ in calls += 1; s.teardown() }
            }
            let token = s.pendingCommand!.token
            for length in 0..<8 { s.handleCommandResponse(frame(9, 7).prefix(length)) }
            s.handleCommandResponse(frame(9, 7, kind: 3))
            precondition(calls == 0 && s.pendingCommand?.token == token && s.commandTimeout != nil)
            s.handleCommandResponse(frame(9, 7))
            precondition(calls == 1 && s.pendingCommand?.id == 0x0c && radio.writes.count == 2)
            s.handleCommandResponse(frame(9, 7))
            precondition(calls == 1)
            s.handleCommandResponse(frame(0x0c, 4))
            precondition(calls == 2 && s.isRetired && s.pendingCommand == nil)
        }
        test("timeout-retires-ambiguous-stream") { s, radio, delegate in
            var calls = 0
            s.writeCommand(9, 7, Data()) { payload in
                calls += 1; precondition(payload == nil && s.isRetired)
                s.writeCommand(9, 7, Data()) { p in calls += 1; precondition(p == nil) }
            }
            s.writeCommand(9, 7, Data()) { p in calls += 1; precondition(p == nil) }
            s.commandTimeout!.perform()
            s.handleCommandResponse(frame(9, 7)) // cannot acknowledge the next same-ID request
            precondition(calls == 3 && radio.writes.count == 1 && delegate.failures == 1)
            s.teardown(); precondition(calls == 3)
        }
        test("cancelled-timeout-cannot-retire-new-command") { s, _, delegate in
            var calls = 0
            s.writeCommand(9, 7, Data()) { _ in calls += 1 }
            let timeout = s.commandTimeout!
            s.handleCommandResponse(frame(9, 7))
            s.writeCommand(9, 7, Data()) { _ in calls += 1 }
            timeout.perform()
            precondition(!s.isRetired && delegate.failures == 0 && calls == 1)
            s.handleCommandResponse(frame(9, 7)); precondition(calls == 2)
        }
        test("raw-experiment-status") { s, _, _ in
            var result: Data?
            s.experimentalCommand(1, 5, payload: Data()) { result = $0 }
            s.handleCommandResponse(frame(1, 5, kind: 2, payload: Data([7, 0x41])))
            precondition(result == Data([7, 0x41]), "NFC polling must retain raw status payloads")
        }
    }
}
