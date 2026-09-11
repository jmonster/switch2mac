import Foundation

final class Delegate: ControllerSessionDelegate {
    var ready = 0
    var failures = 0
    func sessionReady(_ session: ControllerSession) { ready += 1 }
    func sessionFailed(_ session: ControllerSession, reason: String) { failures += 1 }
    func sessionDidUpdateState(_ session: ControllerSession) {}
}

final class StateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main
enum SessionTests {
    static func fixture() -> (ControllerSession, CBPeripheral, DispatchQueue, Delegate) {
        let p = CBPeripheral(), q = DispatchQueue(label: "session-test"), d = Delegate()
        let s = ControllerSession(peripheral: p, slot: 0, wasPairingMode: false, queue: q, delegate: d)
        for uuid in [Switch2.GATT.commandWrite, Switch2.GATT.commandResponse, Switch2.GATT.inputReport,
                     Switch2.GATT.vibrationPro, Switch2.GATT.vibrationJoyConL, Switch2.GATT.vibrationJoyConR] {
            s.chars[uuid] = CBCharacteristic(uuid)
        }
        return (s, p, q, d)
    }
    static func main() {
        let selected = CommandLine.arguments.last!
        func run(_ name: String, _ test: () -> Void) {
            if selected == "all" || selected == name { test(); print("PASS \(name)") }
        }
        run("retired-notification") {
            let (s, _, _, d) = fixture(); defer { _ = d }
            var calls = 0
            s.notifyCompletion = { _ in calls += 1 }
            s.teardown()
            let input = s.chars[Switch2.GATT.inputReport]!
            input.isNotifying = true
            s.peripheral(s.peripheral, didUpdateNotificationStateFor: input, error: nil)
            precondition(calls == 0, "A retired subscription callback resumed its handshake")
        }
        run("retired-input-command") {
            let (s, p, q, d) = fixture(); defer { _ = d }
            let states = StateCounter()
            s.onState = { _, _ in states.increment() }
            s.teardown()
            s.handleInputReport(Data(repeating: 0, count: 63))
            s.experimentalCommand(9, 7, payload: Data()) { _ in }
            q.sync {}
            precondition(states.value == 0 && p.writes.isEmpty, "Retired input/commands must not reach outputs")
        }
        run("ready-needs-input") {
            let (s, _, _, d) = fixture(); defer { s.teardown() }
            s.advanceHandshake()
            precondition(d.ready == 0, "Subscription/handshake without a valid input report is not ready")
            s.handleInputReport(Data(repeating: 0, count: 10))
            precondition(d.ready == 0)
            s.handleInputReport(Data(repeating: 0, count: 63))
            precondition(d.ready == 1)
            s.handleInputReport(Data(repeating: 0, count: 63))
            precondition(d.ready == 1)
        }
        run("early-report-is-delivered") {
            let (s, _, _, d) = fixture(); defer { s.teardown() }
            s.handleInputReport(Data(repeating: 0, count: 63))
            precondition(d.ready == 0)
            let states = StateCounter()
            s.onState = { _, _ in states.increment() }
            s.advanceHandshake()
            precondition(d.ready == 1 && states.value == 1, "Input received during handshake must not be lost")
        }
        run("retired-keepalive") {
            let (s, p, q, d) = fixture(); defer { _ = d }
            q.sync {
                s.advanceHandshake()
                s.teardown()
                s.maintainTick()
                s.begin()
                precondition(s.keepAliveTimer == nil && p.writes.isEmpty)
            }
        }
        run("notification-disabled") {
            let (s, _, _, d) = fixture(); defer { s.teardown() }
            let input = s.chars[Switch2.GATT.inputReport]!
            input.isNotifying = false
            s.peripheral(s.peripheral, didUpdateNotificationStateFor: input, error: nil)
            precondition(d.failures == 1, "Disabled essential notifications are not success")
        }
        run("notification-completion-reentrancy") {
            let (s, _, _, d) = fixture(); defer { s.teardown(); _ = d }
            let input = s.chars[Switch2.GATT.inputReport]!
            input.isNotifying = true
            s.notifyCompletion = { _ in s.notifyCompletion = { _ in } }
            s.peripheral(s.peripheral, didUpdateNotificationStateFor: input, error: nil)
            precondition(s.notifyCompletion != nil, "A completed callback erased replacement work")
        }
        run("rumble") {
            for model in Switch2.Model.allCases {
                let (s, p, q, d) = fixture(); defer { s.teardown(); _ = d }
                s.model = model
                s.setRumble(strong: 1, weak: 0)
                q.sync { s.maintainTick() }
                let motors = p.writes.filter { $0.1.uuid.uuidString == Switch2.GATT.vibration(for: model).uuidString }
                precondition(motors.isEmpty == !model.hasHDRumble, "GameCube must not receive unsupported HD motor writes")
                if !model.hasHDRumble {
                    precondition(p.writes.contains { $0.0.first == Switch2.Command.leds }, "Unsupported rumble must not suppress keep-alive")
                    let count = p.writes.count
                    s.writeMotor(.tone(freqHz: 200, amp: 1))
                    precondition(p.writes.count == count, "Direct/experimental motor calls must obey capability")
                }
            }
        }
        run("calibration") {
            let (s, _, _, d) = fixture(); defer { s.teardown(); _ = d }
            var bytes = Data(repeating: 0, count: 63)
            bytes[10] = 0xff; bytes[11] = 0x0f; bytes[12] = 0x00 // X=4095, Y=0
            bytes[13] = 0x00; bytes[14] = 0x08; bytes[15] = 0x80 // centered
            s.handleInputReport(bytes)
            precondition(s.state.leftStick.x == 1 && s.state.leftStick.y == -1, "Missing calibration must not freeze the stick")
            precondition(s.state.rightStick == (0, 0))
        }
        run("unrelated-response") {
            let (s, _, _, d) = fixture(); defer { s.teardown(); _ = d }
            var calls = 0
            s.writeCommand(0x09, 0x07, Data()) { _ in calls += 1 }
            s.handleCommandResponse(Data([2, 1, 1, 7, 0x10, 0x78, 0, 0]))
            precondition(s.pendingCommand != nil && calls == 0, "Unrelated reply consumed the active command")
            s.handleCommandResponse(Data([9, 1, 1, 7, 0x10, 0x78, 0, 0]))
            precondition(calls == 1 && s.pendingCommand == nil)
        }
        run("memory-address") {
            let (s, _, _, d) = fixture(); defer { s.teardown(); _ = d }
            var succeeded = false
            s.readMemory(length: 1, address: 0x13000) { succeeded = $0 != nil }
            let frame = Data([2, 1, 1, 4, 0x10, 0x78, 0, 0, 1, 0x7e, 0, 0, 0x42, 0x30, 1, 0, 0xaa])
            s.handleCommandResponse(frame)
            precondition(!succeeded, "A different memory address must not supply calibration/identity data")
        }
    }
}
