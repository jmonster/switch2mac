import Foundation

@main enum EngineTests {
    static func main() {
        let engine = BridgeEngine()
        engine.btQueue.sync {
            func session(_ slot: Int) -> ControllerSession {
                ControllerSession(peripheral: CBPeripheral(), slot: slot, wasPairingMode: false,
                                  queue: engine.btQueue, delegate: engine)
            }
            let old = session(0), replacement = session(0), other = session(1)
            engine.connecting[replacement.peripheral.identifier] = (replacement, 0)
            engine.sessions[1] = other
            engine.sessionReady(old)
            precondition(old.isRetired && engine.sessions[0] == nil)
            precondition(engine.connecting[replacement.peripheral.identifier]?.session === replacement)
            engine.sessionFailed(old, reason: "late failure")
            precondition(engine.central.cancelled.isEmpty)
            engine.sessionReady(replacement)
            precondition(engine.sessions[0] === replacement && engine.sessions[1] === other)
            let callback = replacement.onState
            callback?(0, ControllerState())
            precondition(engine.emissions == 1)
            engine.retire(replacement, cancel: true)
            precondition(replacement.isRetired && engine.sessions[1] === other)
            precondition(engine.disconnecting.contains(replacement.peripheral.identifier))
            precondition(engine.central.cancelled == [replacement.peripheral.identifier])
            let newest = session(0)
            engine.connecting[newest.peripheral.identifier] = (newest, 0)
            engine.sessionReady(newest)
            callback?(0, ControllerState())
            precondition(engine.emissions == 1, "Old input closure reached replacement output")
            engine.sessionFailed(replacement, reason: "late failure")
            engine.sessionDidUpdateState(replacement)
            precondition(engine.central.cancelled.count == 1 && engine.publishes == 0)
            engine.retire(replacement, cancel: true)
            precondition(engine.sessions[0] === newest && engine.central.cancelled.count == 1)
            print("PASS engine stale ready/failure/input ownership and unrelated controller preservation")

            let pending = session(2)
            engine.connecting[pending.peripheral.identifier] = (pending, 2)
            engine.armDeadline(pending, seconds: 45)
            let deadline = engine.deadlines[pending.peripheral.identifier]!
            deadline.perform()
            precondition(pending.isRetired && engine.connecting[pending.peripheral.identifier] == nil)
            precondition(engine.disconnecting.contains(pending.peripheral.identifier))
            precondition(engine.sessions[0] === newest && engine.sessions[1] === other)
            print("PASS engine pending deadline retires its own session")
        }
        let done = DispatchSemaphore(value: 0)
        engine.stop { done.signal() }
        precondition(done.wait(timeout: .now() + 2) == .success)
        engine.btQueue.sync {
            precondition(!engine.running && engine.sessions.isEmpty && engine.connecting.isEmpty)
            precondition(engine.deadlines.isEmpty && engine.keyboardMapper.resets == 1)
            precondition(engine.mouseController.resets >= 3 && engine.gestureRecognizer.resets == 1)
            print("PASS engine stop releases input and clears sessions/deadlines")
        }
        engine.resume(); engine.setSuspended(true)
        engine.btQueue.sync { precondition(engine.running && engine.suspended) }
        engine.setSuspended(false)
        engine.btQueue.sync { precondition(engine.running && !engine.suspended) }
        print("PASS engine pause/resume and sleep state")
    }
}
