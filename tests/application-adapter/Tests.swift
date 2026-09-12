import Foundation

// Includes all pointer/output-stop assertions previously colocated in EngineTests.
// Physical stale-input deadlines are tested against the complete kit transport.
@main enum AdapterTests {
    static func snapshot(id: Switch2ControllerID = .init(rawValue: UUID()), generation: UUID = UUID(),
                         model: Switch2ControllerModel = .proController2,
                         state: Switch2ControllerState = .init(), activity: TimeInterval? = nil) -> Switch2Controller {
        .init(id: id, model: model, state: state, connectedAt: Date(), bodyColor: nil, buttonColor: nil,
              serialNumber: nil, sessionGeneration: generation,
              lastActivityAt: activity ?? ProcessInfo.processInfo.systemUptime)
    }
    static func main() {
        let engine = BridgeEngine()
        engine.btQueue.sync {
            engine.updateIdleSweep()
            precondition(engine.idleSweepTimer == nil, "An empty application engine must not poll")
            let raw = Switch2RawVector3(x: -12, y: 34, z: 56)
            let input = Switch2ControllerState(buttons: [.a, .zr, .dpadUp],
                leftStick: .init(x: -0.5, y: 0.75), rightStick: .init(x: 1, y: -1),
                leftTrigger: .init(isPressed: false, travel: 128.0 / 255), rightTrigger: .init(isPressed: true, travel: 1),
                battery: .init(millivolts: 3900, chargeStateRaw: 2, currentRaw: -33),
                motion: .init(accelerationRaw: raw, angularVelocityRaw: raw, magneticFieldRaw: raw, temperatureCelsius: 32),
                optical: .init(xCounter: 65535, yCounter: 19, surfaceQualityRaw: 77, liftDistanceRaw: 88))
            let controller = snapshot(model: .nsoGameCube, state: input)
            engine.receiveController(.connected(controller))
            let first = engine.sessions[0]!
            let output = engine.emitted.last!.1
            precondition(output.buttons == input.buttons)
            precondition(output.leftStick == (-0.5, 0.75) && output.rightStick == (1, -1))
            precondition(output.leftTrigger == 128 && output.rightTrigger == 255)
            precondition(!output.buttons.contains(.zl) && output.buttons.contains(.zr))
            precondition(output.batteryMillivolts == 3900 && output.chargeState == 2 && output.batteryCurrent == -33)
            precondition(output.gyro == (-12, 34, 56) && output.accel == output.gyro && output.mag == output.gyro)
            precondition(output.temperatureC == 32 && output.mouseX == 65535 && output.mouseY == 19)
            precondition(output.surfaceQuality == 77 && output.liftDistance == 88)
            precondition(engine.idleSweepTimer != nil)
            print("PASS public snapshots reach the application output boundary with all state fields intact")

            let neutral = snapshot(id: controller.id, generation: controller.connectionID, model: controller.model)
            engine.receiveController(.input(neutral))
            precondition(engine.sessions[0] === first && engine.emitted.last!.1.buttons.isEmpty)
            precondition(engine.emitted.last!.1.leftStick == (0, 0) && engine.emitted.last!.1.leftTrigger == 0)
            first.update(controller)
            first.update(snapshot(id: controller.id, state: .init(buttons: .b)))
            precondition(first.state.buttons == controller.state.buttons, "An old record cannot accept another generation")
            let other = snapshot(state: .init(buttons: .b))
            engine.receiveController(.connected(other))
            precondition(engine.sessions.count == 2)
            engine.receiveController(.snapshot(.init(isRunning: true, bluetooth: .poweredOn, discovery: .paused, controllers: [neutral])))
            precondition(engine.sessions.count == 1 && engine.sessions[0] === first)
            precondition(engine.emitted.last!.1.buttons.isEmpty, "Overflow resynchronization must deliver releases")
            engine.receiveController(.disconnected(controller.id, .requested))
            precondition(first.isRetired && engine.sessions.isEmpty && engine.idleSweepTimer == nil)
            first.update(controller)
            precondition(first.state.buttons.isEmpty, "Retired application records must remain terminal")
            print("PASS input/release conversion, multiple controllers, snapshot resynchronization and retired generations")

            for rawTravel in UInt8.min...UInt8.max {
                let state = Switch2ControllerState(leftTrigger: .init(isPressed: false, travel: Double(rawTravel) / 255),
                    rightTrigger: .init(isPressed: true))
                let value = Switch2KitStateAdapter.outputState(state)
                precondition(value.leftTrigger == rawTravel && value.rightTrigger == 255)
            }
            var left = ControllerState(), right = ControllerState()
            left.buttons = [.dpadUp, .zl]; right.buttons = [.a, .zr]
            left.leftStick = (-1, 1); right.rightStick = (0.5, -0.5)
            left.leftTrigger = 3; right.rightTrigger = 7
            left.batteryMillivolts = 3800; right.batteryMillivolts = 3900
            right.gyro = (1, 2, 3); right.accel = (-4, 5, -6)
            let pair = BridgeEngine.mergeStates(left: left, right: right)
            precondition(pair.buttons == [.dpadUp, .zl, .a, .zr] && pair.leftStick == (-1, 1) && pair.rightStick == (0.5, -0.5))
            precondition(pair.leftTrigger == 3 && pair.rightTrigger == 7 && pair.batteryMillivolts == 3800)
            precondition(pair.gyro == right.gyro && pair.accel == right.accel)
            left.batteryMillivolts = 0
            precondition(BridgeEngine.mergeStates(left: left, right: right).batteryMillivolts == 3900)
            print("PASS all trigger travel values and production Joy-Con grouping orientation/battery/motion")

            let now = ProcessInfo.processInfo.systemUptime
            engine.receiveController(.connected(snapshot(activity: now - 120)))
            engine.receiveController(.connected(snapshot(activity: now - 120)))
            let newest = engine.sessions[0]!, rejected = engine.sessions[1]!
            engine.mouseController.acceptsPointer = true
            engine.handlePointerInput(newest, state: ControllerState())
            engine.mouseController.acceptsPointer = false
            engine.handlePointerInput(rejected, state: ControllerState())
            engine.sweepIdleSessions()
            precondition(engine.sessions[0] === newest && engine.sessions[1] == nil,
                         "Accepted pointer input must prevent idle retirement; rejected input must not")
            precondition(engine.controllerManager.disconnects == [rejected.id])
            engine.receiveController(.disconnected(newest.id, .timeout))
            precondition(engine.sessions.isEmpty && engine.idleSweepTimer == nil)
            precondition(engine.pointerActivity.isEmpty, "Retirement must drop pointer ownership")
            engine.mouseController.acceptsPointer = true
            engine.handlePointerInput(newest, state: ControllerState())
            precondition(engine.pointerActivity.isEmpty, "Late pointer input must not revive a retired owner")
            print("PASS application pointer-only activity, idle retirement and stale-session event cleanup")
        }
        let done = DispatchSemaphore(value: 0)
        engine.stop { done.signal() }
        precondition(done.wait(timeout: .now() + 2) == .success)
        engine.btQueue.sync {
            precondition(!engine.running && engine.sessions.isEmpty && engine.idleSweepTimer == nil)
            precondition(engine.keyboardMapper.resets == 1 && engine.mouseController.resets >= 3 && engine.gestureRecognizer.resets == 1)
            precondition(engine.controllerManager.stops == 1)
        }
        engine.resume(); engine.setSuspended(true)
        engine.btQueue.sync { precondition(engine.running && engine.suspended && engine.controllerManager.stops == 2) }
        engine.setSuspended(false)
        engine.btQueue.sync {
            precondition(engine.running && !engine.suspended && engine.controllerManager.starts == 2)
            engine.running = false; engine.resetConnections(cancel: false)
        }
        print("PASS application stop, resume and sleep retain output reset and manager lifecycle behavior")
    }
}
