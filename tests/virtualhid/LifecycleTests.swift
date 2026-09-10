import Foundation
import CoreHID

private final class Messages: @unchecked Sendable {
    static let shared = Messages()
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    func contains(_ value: String) -> Bool { lock.withLock { values.contains { $0.contains(value) } } }
}
enum LogLevel { case info, warning }
func bridgeLog(_ level: LogLevel, _ category: String, _ message: String) { Messages.shared.append(message) }

private func check(_ condition: @autoclosure () -> Bool, _ message: String,
                   line: UInt = #line) {
    if !condition() { print("FAIL line \(line): \(message)"); exit(1) }
}
private func until(_ message: String, _ predicate: @Sendable () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate() {
        check(ContinuousClock.now < deadline, "timeout: \(message)")
        try? await Task.sleep(for: .milliseconds(1))
    }
}
private func events(_ kind: String, id: Int = 0) -> [Event] {
    Probe.shared.events.filter { $0.id == id && $0.kind == kind }
}
private let neutral = Data(repeating: 0, count: 13) + Data([8])
private func state(_ pressed: Bool) -> ControllerState {
    var state = ControllerState(); state.buttons = pressed ? [.a] : []
    return state
}

@main
struct LifecycleTests {
    static func main() async {
        let name = CommandLine.arguments[1]
        let probe = Probe.shared
        var sink: VirtualHIDSink? = VirtualHIDSink()
        switch name {
        case "activation":
            probe.configure(activation: true)
            sink!.controllerConnected(slot: 0, model: .nsoGameCube)
            await until("activation start") { !events("activating").isEmpty }
            let earliest = SuspendingClock.now
            sink!.controllerState(slot: 0, state: state(true))
            sink!.controllerState(slot: 0, state: state(false))
            let latest = SuspendingClock.now
            try? await Task.sleep(for: .milliseconds(30))
            check(events("writing").isEmpty, "report submitted before activation finished")
            await probe.devices[0].activation.release()
            await until("tap") { events("sent").count == 2 }
            check(events("sent").map { $0.data[0] } == [2, 0], "tap order changed")
            check(events("sent").allSatisfy { earliest <= $0.timestamp! && $0.timestamp! <= latest },
                  "timestamps must reflect admission, not a delayed send")
        case "order", "disconnect", "failure", "replacement", "overflow", "shutdown":
            probe.configure(writes: true)
            sink!.controllerConnected(slot: 0, model: .proController2)
            await until("active") { !events("activated").isEmpty }
            sink!.controllerState(slot: 0, state: state(true))
            await until("first write") { events("writing").count == 1 }
            sink!.controllerState(slot: 0, state: state(false))
            sink!.controllerState(slot: 0, state: state(true))
            if name == "disconnect" { sink!.controllerDisconnected(slot: 0) }
            if name == "failure" || name == "replacement" { probe.failNext(0) }
            if name == "shutdown" { sink = nil }
            if name == "replacement" {
                probe.configure()
                for _ in 0..<1000 {
                    sink!.controllerDisconnected(slot: 0)
                    sink!.controllerConnected(slot: 0, model: .nsoGameCube)
                    sink!.controllerState(slot: 0, state: state(true))
                }
            }
            if name == "overflow" {
                for _ in 0..<1000 { sink!.controllerState(slot: 0, state: state(true)) }
                check(Messages.shared.contains("queue full"), "overflow must be explicit")
            }
            try? await Task.sleep(for: .milliseconds(30))
            check(events("writing").count == 1, "writes overlapped across suspension")
            check(probe.devices.count == 1, "replacement allocated before old device retired")
            await probe.devices[0].writes.release()
            if name == "order" {
                await until("ordered writes") { events("sent").count == 3 }
                check(events("sent").map { $0.data[0] } == [2, 0, 2], "ordered tap lost")
            } else {
                await until("old device released") { !events("destroyed").isEmpty }
                check(events("writing").count == 2, "queued reports survived retirement")
                check(events("sent").last!.data == neutral, "final report was not neutral")
                if name == "replacement" {
                    await until("replacement input") { events("sent", id: 1).count == 1 }
                    check(probe.devices.count == 2, "rapid reconnect created obsolete devices")
                    let trace = probe.events
                    check(trace.firstIndex { $0.kind == "destroyed" && $0.id == 0 }! <
                          trace.firstIndex { $0.kind == "created" && $0.id == 1 }!, "device lifetimes overlap")
                    check(events("sent", id: 1)[0].data[0] == 2, "old failure discarded replacement input")
                    check(probe.devices[1].properties.productID == 0x2073, "replacement model changed")
                } else if name == "failure" || name == "overflow" {
                    sink!.controllerState(slot: 0, state: state(true))
                    check(probe.devices.count == 1, "failed output automatically retried")
                    probe.configure()
                    sink!.controllerDisconnected(slot: 0)
                    sink!.controllerConnected(slot: 0, model: .proController2)
                    sink!.controllerState(slot: 0, state: state(true))
                    await until("explicit retry") { events("sent", id: 1).count == 1 }
                }
            }
        case "cancel-activation", "shutdown-activation", "stale":
            probe.configure(activation: true)
            sink!.controllerConnected(slot: 0, model: .proController2)
            await until("blocked activation") { !events("activating").isEmpty }
            sink!.controllerState(slot: 0, state: state(true))
            if name == "stale" { try? await Task.sleep(for: .milliseconds(1100)) }
            else if name == "shutdown-activation" { sink = nil }
            else { sink!.controllerDisconnected(slot: 0) }
            await probe.devices[0].activation.release()
            await until("retire after activation") { !events("destroyed").isEmpty }
            check(events("sent").map(\.data) == [neutral], "obsolete input escaped activation")
            if name == "stale" { check(Messages.shared.contains("queue stale"), "stale input failed silently") }
        case "independent-slots":
            probe.configure(activation: true)
            sink!.controllerConnected(slot: 0, model: .proController2)
            await until("first device") { probe.devices.count == 1 }
            probe.configure()
            sink!.controllerConnected(slot: 1, model: .nsoGameCube)
            sink!.controllerState(slot: 1, state: state(true))
            await until("second slot works") { events("sent", id: 1).count == 1 }
            check(events("writing").isEmpty, "blocked slot leaked a write")
            sink!.controllerDisconnected(slot: 0)
            await probe.devices[0].activation.release()
            await until("first retired") { !events("destroyed").isEmpty }
            check(events("destroyed", id: 1).isEmpty, "unrelated slot retired")
        case "neutral-failure":
            sink!.controllerConnected(slot: 0, model: .proController2)
            sink!.controllerState(slot: 0, state: state(true))
            await until("held report") { events("sent").count == 1 }
            probe.failNext(0)
            sink!.controllerDisconnected(slot: 0)
            await until("release after neutral error") { !events("destroyed").isEmpty }
            check(Messages.shared.contains("neutral report failed"), "neutral failure hidden")
        case "creation-retry":
            probe.configure(refused: true)
            sink!.controllerConnected(slot: 0, model: .proController2)
            await until("refused creation") { Messages.shared.contains("creation refused") }
            for _ in 0..<1000 { sink!.controllerState(slot: 0, state: state(true)) }
            check(probe.creationAttempts == 1, "creation retried per report")
            probe.configure()
            sink!.controllerConnected(slot: 0, model: .nsoGameCube)
            sink!.controllerState(slot: 0, state: state(true))
            await until("creation recovers") { !events("sent").isEmpty }
            check(probe.creationAttempts == 2, "transient failure latched permanently")
        case "layout":
            sink!.controllerConnected(slot: -1, model: .proController2)
            sink!.controllerConnected(slot: 4, model: .proController2)
            check(probe.creationAttempts == 0, "invalid slot allocated device")
            sink!.controllerConnected(slot: 0, model: .nsoGameCube)
            var input = state(true); input.buttons.formUnion([.l, .r, .c, .dpadUp, .dpadRight])
            input.leftStick = (1, -1); input.rightStick = (-1, 1)
            for value in 0...255 {
                input.leftTrigger = UInt8(value); input.rightTrigger = UInt8(255 - value)
                sink!.controllerState(slot: 0, state: input)
                await until("trigger \(value)") { events("sent").count == value + 1 }
                let report = events("sent")[value].data
                check(report == Data([2, 6, 4, 0xff, 0x7f, 0xff, 0x7f, 1, 0x80, 1, 0x80,
                                      UInt8(value), UInt8(255-value), 1]), "14-byte mapping changed")
            }
            input.leftStick = (.nan, .infinity); input.rightStick = (-.infinity, .nan)
            sink!.controllerState(slot: 0, state: input)
            await until("finite fallback") { events("sent").count == 257 }
            check(events("sent").last!.data[3..<11] == Data(repeating: 0, count: 8), "nonfinite axis not neutral")
            check(probe.devices[0].properties.vendorID == 0x057e, "vendor changed")
        default: fatalError("unknown case")
        }
        sink = nil
        await until("all owned devices released") {
            probe.events.filter { $0.kind == "created" }.count == probe.events.filter { $0.kind == "destroyed" }.count
        }
        print("PASS \(name)")
    }
}
