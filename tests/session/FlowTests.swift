import Foundation

final class FailureRecorder: ControllerSessionDelegate {
    var failures = 0
    func sessionReady(_ session: ControllerSession) {}
    func sessionFailed(_ session: ControllerSession, reason: String) { failures += 1 }
    func sessionDidUpdateState(_ session: ControllerSession) {}
}

@main struct FlowTests {
    static func main() {
        let radio = CBPeripheral()
        let queue = DispatchQueue(label: "flow-tests")
        let recorder = FailureRecorder()
        let session = ControllerSession(peripheral: radio, slot: 0,
            wasPairingMode: false, queue: queue, delegate: recorder)
        for uuid in [Switch2.GATT.commandWrite, Switch2.GATT.vibrationPro] {
            session.chars[uuid] = CBCharacteristic(uuid)
        }
        queue.sync {
            radio.canSendWriteWithoutResponse = false
            var replies: [Int] = []
            for id in 1...3 {
                session.writeCommand(UInt8(id), 7, Data()) { _ in replies.append(id) }
            }
            precondition(radio.writes.isEmpty && session.commandTimeout == nil)
            session.handleCommandResponse(Data([1,1,1,7,0x10,0x78,0,0]))
            precondition(replies.isEmpty)
            radio.canSendWriteWithoutResponse = true
            session.peripheralIsReady(toSendWriteWithoutResponse: radio)
            precondition(radio.writes.count == 1 && session.commandTimeout != nil)
            for id in 1...3 { session.handleCommandResponse(Data([UInt8(id),1,1,7,0x10,0x78,0,0])) }
            precondition(replies == [1,2,3])
            precondition(radio.writes.map { $0.0.first! } == [1,2,3])
            print("PASS capacity, unsent-response rejection and command FIFO")

            var memory: Data?
            session.readMemory(length: 1, address: 0x13000) { memory = $0 }
            var response = Data([2,1,1,4,0x10,0x78,0,0,1,0x7e,0,0,0x42,0x30,1,0,0xaa])
            session.handleCommandResponse(response)
            precondition(memory == nil && session.pendingCommand != nil)
            response[12] = 0
            session.handleCommandResponse(response)
            precondition(memory == Data([0xaa]))
            print("PASS memory reply retains transaction until its address matches")

            radio.canSendWriteWithoutResponse = false
            let writes = radio.writes.count
            session.writeMotor(.waveform(strong: 1, weak: 0))
            precondition(radio.writes.count == writes)
            session.pendingMotor?.expires = 0
            radio.canSendWriteWithoutResponse = true
            session.peripheralIsReady(toSendWriteWithoutResponse: radio)
            precondition(radio.writes.last!.0 == Switch2.motorPacket(
                .waveform(strong: 0, weak: 0), packetID: 0, model: .proController2))
            print("PASS blocked and expired motor intent")

            var report = Data(repeating: 0, count: 63)
            report[4] = 8
            session.handleInputReport(report)
            session.lastActivityAt = 0
            session.handleInputReport(report)
            precondition(session.lastActivityAt > 0)
            print("PASS held control remains active")

            radio.canSendWriteWithoutResponse = false
            var cancelled = 0
            session.writeCommand(9, 7, Data(repeating: 1, count: 512)) {
                if $0 == nil { cancelled += 1 }
            }
            precondition(cancelled == 1 && session.pendingCommand == nil)
            for _ in 0..<33 {
                session.writeCommand(9, 7, Data()) { if $0 == nil { cancelled += 1 } }
            }
            precondition(recorder.failures == 1 && cancelled == 34)
            session.teardown()
            precondition(cancelled == 34)
            print("PASS payload/queue limits and exactly-once teardown")
        }
    }
}
