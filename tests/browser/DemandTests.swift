// Appended to a temporary copy of WebSocketHub.swift by run.sh. Same-file
// access tests queue-confined invariants without shipping test hooks in the app.
import Synchronization

enum TestJSON {
    private static let counts = Mutex([String: Int]())
    static func record(_ object: [String: Any]) {
        guard let type = object["t"] as? String else { return }
        counts.withLock { $0[type, default: 0] += 1 }
    }
    static var states: Int { counts.withLock { $0["state", default: 0] } }
}

enum LogLevel { case info, warning, error, debug }
func bridgeLog(_ level: LogLevel, _ category: String, _ message: String) {}
protocol ControllerOutputSink: AnyObject {
    var onRumble: ((Int, Double, Double) -> Void)? { get set }
    func controllerConnected(slot: Int, model: Switch2.Model)
    func controllerDisconnected(slot: Int)
    func controllerName(slot: Int, name: String)
    func controllerState(slot: Int, state: ControllerState)
}

extension WebSocketHub {
    static func verifyDemandBehavior() {
        let origins = origins(from: String(repeating: "a", count: 32))
        // Both an opt-out and an incomplete opt-in must be completely inert.
        for hub in [WebSocketHub(enabled: false, allowedOrigins: origins),
                    WebSocketHub(enabled: true, allowedOrigins: [])] {
            hub.controllerConnected(slot: 0, model: .proController2)
            hub.controllerName(slot: 0, name: "disabled")
            for _ in 0..<1_000 { hub.controllerState(slot: 0, state: ControllerState()) }
            hub.queue.sync {
                precondition(hub.listener == nil && hub.pingTimer == nil)
                precondition(hub.connected.isEmpty && hub.lastState.isEmpty && hub.seq.isEmpty)
                precondition(hub.stateMailbox.take().isEmpty)
                precondition(TestJSON.states == 0, "disabled bridge encoded reports")
            }
        }
        let hub = WebSocketHub(enabled: true, allowedOrigins: origins)
        hub.controllerConnected(slot: 0, model: .proController2)
        hub.controllerName(slot: 0, name: "late join")
        hub.queue.sync {
            precondition(hub.pingTimer == nil, "an empty listener must not wake periodically")
            for _ in 0..<1_000 { hub.publishState(slot: 0, state: ControllerState()) }
            precondition(TestJSON.states == 0, "no-client stream encoded reports")
            var state = ControllerState()
            state.buttons = [.a]; state.leftStick = (.nan, 2); state.rightStick = (-2, .infinity)
            state.leftTrigger = 73; state.rightTrigger = 255
            hub.publishState(slot: 0, state: state)
            precondition(hub.lastState.count == 1)
            let snapshot = hub.lastState[0]!
            precondition(snapshot.sequence == 1_001 && snapshot.state.buttons == [.a])
            let message = stateMessage(slot: 0, sequence: snapshot.sequence, state: snapshot.state)!
            let object = try! JSONSerialization.jsonObject(with: Data(message.utf8)) as! [String: Any]
            precondition(object["seq"] as? Int == 1_001 && object["lt"] as? Int == 73)
            precondition(object["lx"] as? Double == 0 && object["ly"] as? Double == 1)
            precondition(object["rx"] as? Double == -1 && object["ry"] as? Double == 0)
            hub.seq[0] = .max
            hub.publishState(slot: 0, state: state)
            precondition(hub.lastState[0]?.sequence == 0, "sequence wrap changed")
            // A ready observer starts maintenance; removing the last stops it.
            let connection = NWConnection(host: "127.0.0.1", port: 24810, using: .tcp)
            let client = Client(connection)
            client.ready = true
            let id = ObjectIdentifier(connection)
            hub.clients[id] = client
            hub.startPing()
            precondition(hub.pingTimer != nil)
            hub.remove(id)
            precondition(hub.pingTimer == nil)
        }
        hub.controllerDisconnected(slot: 0)
        hub.queue.sync { precondition(hub.lastState.isEmpty && hub.connected.isEmpty) }
        print("Browser demand regressions passed")
    }
}

@main enum DemandTests {
    static func main() { WebSocketHub.verifyDemandBehavior() }
}
