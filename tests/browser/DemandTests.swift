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
        // Disabled input is inert. Four small lifecycle records support live enablement.
        for hub in [WebSocketHub(enabled: false, allowedOrigins: origins),
                    WebSocketHub(enabled: true, allowedOrigins: [])] {
            hub.controllerConnected(slot: 0, model: .proController2)
            hub.controllerName(slot: 0, name: "disabled")
            for _ in 0..<1_000 { hub.controllerState(slot: 0, state: ControllerState()) }
            hub.queue.sync {
                precondition(hub.listener == nil && hub.pingTimer == nil)
                precondition(hub.connected.count == 1 && hub.connected[0]?.name == "disabled")
                precondition(hub.lastState.isEmpty && hub.seq.isEmpty)
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
            hub.rumbleOwners[0] = id
            let stops = Mutex(0)
            hub.onRumble = { _, strong, weak in
                if strong == 0 && weak == 0 { stops.withLock { $0 += 1 } }
            }
            let oldGeneration = hub.generation
            hub.applyConfiguration(enabled: false, origins: origins)
            precondition(hub.pingTimer == nil && hub.listener == nil && hub.clients.isEmpty)
            precondition(stops.withLock { $0 } == 1 && hub.rumbleOwners.isEmpty)
            precondition(hub.connected[0]?.name == "late join", "Live enable must not need re-pairing")
            hub.applyConfiguration(enabled: true, origins: origins)
            // Model a producer which read the old admission epoch immediately
            // before a reconfiguration, then submitted after its clearAll().
            hub.stateMailbox.submit(slot: 0, state: Input(generation: oldGeneration, state: state))
            hub.drainStates()
            precondition(hub.lastState.isEmpty, "A retired generation must not feed replacement clients")
            hub.publishState(slot: 0, state: state)
            precondition(hub.lastState[0]?.sequence == 1)
            let current = hub.generation
            hub.applyConfiguration(enabled: true, origins: origins)
            precondition(hub.generation == current, "Unchanged settings must not restart clients")
            hub.listener?.cancel(); hub.listener = nil
            hub.scheduleRetry()
            let retiredRetry = hub.retry!
            hub.applyConfiguration(enabled: false, origins: origins)
            retiredRetry.perform()
            precondition(hub.listener == nil && hub.retry == nil)
            precondition(hub.admission.withLock { !$0.enabled })
        }
        hub.controllerDisconnected(slot: 0)
        hub.queue.sync { precondition(hub.lastState.isEmpty && hub.connected.isEmpty) }
        print("Browser demand regressions passed")
    }
}

@main enum DemandTests {
    static func main() { WebSocketHub.verifyDemandBehavior() }
}
