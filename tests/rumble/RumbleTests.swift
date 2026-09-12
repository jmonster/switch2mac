import Foundation

private final class RumbleDelegate: ControllerSessionDelegate {
    var failures = 0
    func sessionReady(_ session: ControllerSession) {}
    func sessionFailed(_ session: ControllerSession, reason: String) { failures += 1 }
    func sessionDidUpdateState(_ session: ControllerSession) {}
}

@main enum RumbleTests {
    private static func fixture(_ model: Switch2.Model, slot: Int = 0,
                                queue: DispatchQueue) -> (ControllerSession, CBPeripheral, RumbleDelegate) {
        let radio = CBPeripheral(), delegate = RumbleDelegate()
        let session = ControllerSession(peripheral: radio, slot: slot, wasPairingMode: false,
                                        queue: queue, delegate: delegate)
        queue.sync {
            session.model = model
            session.handshakeComplete = true
            session.readyReported = true
            session.lastWriteAt = ProcessInfo.processInfo.systemUptime
            for uuid in [Switch2.GATT.commandWrite, Switch2.GATT.commandResponse,
                         Switch2.GATT.inputReport, Switch2.GATT.vibration(for: model)] {
                session.chars[uuid] = CBCharacteristic(uuid)
            }
        }
        return (session, radio, delegate)
    }

    // Public entry points may enqueue a session action and then a pulse.
    private static func drain(_ queue: DispatchQueue) { for _ in 0..<4 { queue.sync {} } }
    private static func reply(_ session: ControllerSession, success: Bool = true) {
        let frame = session.pendingCommand!.frame
        session.handleCommandResponse(Data([frame[0], success ? 1 : 2, frame[2], frame[3], 0, 0, 0, 0]))
    }
    private static func motorWrites(_ radio: CBPeripheral, model: Switch2.Model) -> [Data] {
        radio.writes.filter { $0.1.uuid.uuidString == Switch2.GATT.vibration(for: model).uuidString }.map { $0.0 }
    }
    private static func resetTest(_ session: ControllerSession, _ radio: CBPeripheral) {
        session.lastRumbleTestAt = -.infinity
        radio.writes.removeAll()
    }
    private static func settings(_ serial: String, intensity: Double) {
        UserDefaults.standard.set([serial: ["rumble": intensity]], forKey: "controllerSettings")
    }

    static func main() {
        let originalSettings = UserDefaults.standard.object(forKey: "controllerSettings")
        defer {
            if let originalSettings { UserDefaults.standard.set(originalSettings, forKey: "controllerSettings") }
            else { UserDefaults.standard.removeObject(forKey: "controllerSettings") }
        }
        func test(_ name: String, _ body: () -> Void) { body(); print("PASS direct rumble \(name)") }

        test("known preset wire bytes, discrete policy and invalid intensity") {
            precondition(Switch2.GameCubeRumblePreset.forTest(intensity: 0.05) == .soft)
            precondition(Switch2.GameCubeRumblePreset.forTest(intensity: 0.49) == .soft)
            precondition(Switch2.GameCubeRumblePreset.forTest(intensity: 0.5) == .strong)
            precondition(Switch2.GameCubeRumblePreset.forTest(intensity: 100) == .strong)
            for intensity in [0, -1, Double.nan, .infinity, -.infinity] {
                precondition(Switch2.GameCubeRumblePreset.forTest(intensity: intensity) == nil)
            }
            precondition(Switch2.buildCommand(0x0a, 2, data: Switch2.GameCubeRumblePreset.soft.payload)
                         == Data([0x0a, 0x91, 1, 2, 0, 4, 0, 0, 3, 0, 0, 0]))
        }
        test("GameCube test sends command only, with ACK correlation and no HD writes") {
            let q = DispatchQueue(label: "rumble-gc")
            let (s, p, d) = fixture(.nsoGameCube, queue: q)
            defer { q.sync { s.teardown() }; _ = d }
            for (level, preset): (Double, UInt8) in [(0.25, 3), (1, 2)] {
                q.sync { resetTest(s, p) }
                s.testRumble(intensity: level); drain(q)
                q.sync {
                    precondition(p.writes.count == 1)
                    precondition(p.writes[0].1.uuid.uuidString == Switch2.GATT.commandWrite.uuidString)
                    precondition(p.writes[0].0 == Data([0x0a, 0x91, 1, 2, 0, 4, 0, 0, preset, 0, 0, 0]))
                    precondition(motorWrites(p, model: .nsoGameCube).isEmpty)
                    // An unrelated reply must not finish the preset command.
                    s.handleCommandResponse(Data([9, 1, 1, 7, 0, 0, 0, 0]))
                    precondition(s.pendingCommand != nil)
                    reply(s)
                    precondition(s.pendingCommand == nil && d.failures == 0)
                }
            }
        }
        test("GameCube mute/non-finite levels, rejected preset, and bounded rapid clicks") {
            let q = DispatchQueue(label: "rumble-gc-limits")
            let (s, p, d) = fixture(.nsoGameCube, queue: q)
            defer { q.sync { s.teardown() }; _ = d }
            for level in [0, -1, Double.nan, .infinity] { s.testRumble(intensity: level) }
            drain(q); q.sync { precondition(p.writes.isEmpty) }
            s.testRumble(intensity: 1); drain(q)
            q.sync {
                reply(s, success: false)
                precondition(!s.ended && d.failures == 0)
            }
            for _ in 0..<100 { s.testRumble(intensity: 1) }
            drain(q)
            q.sync {
                precondition(p.writes.count == 1 && s.queuedCommands.isEmpty)
                s.lastRumbleTestAt -= 1 // advance the test admission deadline, no wall-clock wait
            }
            s.testRumble(intensity: 0.1); drain(q)
            q.sync { precondition(p.writes.count == 2); reply(s) }
        }
        test("busy command and blocked radio never defer a GameCube buzz") {
            let q = DispatchQueue(label: "rumble-gc-busy")
            let (s, p, d) = fixture(.nsoGameCube, queue: q)
            defer { q.sync { s.teardown() }; _ = d }
            q.sync { p.canSendWriteWithoutResponse = false }
            s.testRumble(intensity: 1); drain(q)
            q.sync {
                precondition(p.writes.isEmpty && s.pendingCommand == nil && s.queuedCommands.isEmpty)
                p.canSendWriteWithoutResponse = true
                s.peripheralIsReady(toSendWriteWithoutResponse: p)
                precondition(p.writes.isEmpty)
                s.setPlayerLEDs()
            }
            for _ in 0..<20 { s.testRumble(intensity: 1) }
            drain(q)
            q.sync {
                precondition(p.writes.count == 1 && p.writes[0].0[0] == Switch2.Command.leds)
                precondition(s.queuedCommands.isEmpty)
                reply(s)
                precondition(p.writes.count == 1)
            }
            // An explicit retry after capacity returns is accepted.
            s.testRumble(intensity: 1); drain(q)
            q.sync { precondition(p.writes.count == 2); reply(s) }
        }
        test("missing command characteristic or short MTU fails without a motor fallback") {
            for missingCharacteristic in [false, true] {
                let q = DispatchQueue(label: "rumble-gc-unavailable")
                let (s, p, d) = fixture(.nsoGameCube, queue: q)
                defer { q.sync { s.teardown() }; _ = d }
                q.sync {
                    if missingCharacteristic { s.chars.removeValue(forKey: Switch2.GATT.commandWrite) }
                    else { p.writeLimit = 11 }
                }
                s.testRumble(intensity: 1); drain(q)
                q.sync { precondition(p.writes.isEmpty && s.pendingCommand == nil && !s.ended) }
            }
        }
        test("Pro test exercises both independent motors; Joy-Con gain is not doubled") {
            for model in [Switch2.Model.proController2, .joyCon2Left, .joyCon2Right] {
                let q = DispatchQueue(label: "rumble-hd")
                let (s, p, d) = fixture(model, queue: q)
                defer { q.sync { s.teardown() }; _ = d }
                s.testRumble(intensity: 0.4); drain(q)
                q.sync {
                    let expected = Switch2.MotorVibration.waveform(strong: 0.4,
                        weak: model == .proController2 ? 0.4 : 0, model: model)
                    precondition(motorWrites(p, model: model) == [Switch2.motorPacket(expected, packetID: 0, model: model)])
                    precondition(s.rumbleTarget.strong == 0.4)
                    precondition(s.rumbleTarget.weak == (model == .proController2 ? 0.4 : 0))
                    precondition(s.pendingCommand == nil)
                }
            }
        }
        test("Pro pulse stops, but an older pulse cannot stop a newer game effect") {
            for superseded in [false, true] {
                let q = DispatchQueue(label: "rumble-hd-stop")
                let (s, p, d) = fixture(.proController2, queue: q)
                defer { q.sync { s.teardown() }; _ = d }
                s.testRumble(intensity: 1); drain(q)
                if superseded { s.setRumble(strong: 0.2, weak: 0.3); drain(q) }
                let done = DispatchSemaphore(value: 0)
                q.asyncAfter(deadline: .now() + 0.45) { done.signal() }
                precondition(done.wait(timeout: .now() + 3) == .success)
                q.sync {
                    let expected = superseded
                        ? Switch2.MotorVibration.waveform(strong: 0.2, weak: 0.3, model: .proController2)
                        : .stopped
                    let writes = motorWrites(p, model: .proController2)
                    precondition(writes.last == Switch2.motorPacket(expected, packetID: UInt8(writes.count - 1), model: .proController2))
                }
            }
        }
        test("a later queued game request supersedes the direct test in FIFO order") {
            let q = DispatchQueue(label: "rumble-order")
            let (s, p, d) = fixture(.proController2, queue: q)
            defer { q.sync { s.teardown() }; _ = d }
            // Enqueue both while the queue is occupied to expose an extra
            // async hop from testRumble to pulseRumble deterministically.
            q.sync {
                s.testRumble(intensity: 1)
                s.setRumble(strong: 0.2, weak: 0.3)
            }
            drain(q)
            q.sync {
                precondition(s.rumbleTarget.strong == 0.2 && s.rumbleTarget.weak == 0.3)
                let expected = Switch2.MotorVibration.waveform(strong: 0.2, weak: 0.3, model: .proController2)
                precondition(motorWrites(p, model: .proController2).last
                             == Switch2.motorPacket(expected, packetID: 1, model: .proController2))
            }
        }
        test("not-ready and retired sessions cannot be tested") {
            for model in Switch2.Model.allCases {
                let q = DispatchQueue(label: "rumble-ended")
                let (s, p, d) = fixture(model, queue: q)
                defer { _ = d }
                q.sync { s.readyReported = false }
                s.testRumble(intensity: 1); drain(q)
                q.sync { precondition(p.writes.isEmpty); s.readyReported = true; s.teardown() }
                s.testRumble(intensity: 1); drain(q)
                q.sync { precondition(p.writes.isEmpty) }
            }
        }
        test("engine addresses unassigned hardware and reads the current mute setting") {
            let q = DispatchQueue(label: "rumble-unassigned")
            // Engine and session share the same queue in production.
            let live = RumbleTestEngine(queue: q)
            let (s, p, d) = fixture(.proController2, slot: 7, queue: q)
            defer { q.sync { s.teardown() }; _ = d }
            q.sync { live.sessions[7] = s }
            settings(s.serialNumber, intensity: 0)
            live.testRumble(serial: s.serialNumber); drain(q)
            q.sync { precondition(p.writes.isEmpty && live.players.isEmpty) }
            settings(s.serialNumber, intensity: 0.35)
            live.testRumble(serial: s.serialNumber); drain(q)
            q.sync {
                precondition(motorWrites(p, model: .proController2).count == 1)
                precondition(s.rumbleTarget.strong == 0.35 && s.rumbleTarget.weak == 0.35)
            }
        }
        test("logical pair targets both sessions using the pair intensity") {
            let q = DispatchQueue(label: "rumble-pair")
            let live = RumbleTestEngine(queue: q)
            let (l, lp, ld) = fixture(.joyCon2Left, slot: 0, queue: q)
            let (r, rp, rd) = fixture(.joyCon2Right, slot: 1, queue: q)
            let pairID = l.serialNumber + "+" + r.serialNumber
            defer { q.sync { l.teardown(); r.teardown() }; _ = ld; _ = rd }
            q.sync {
                live.sessions = [0: l, 1: r]
                live.players[2] = .init(id: pairID, slots: [0, 1], model: .proController2, isPair: true)
            }
            settings(pairID, intensity: 0.3)
            live.testRumble(serial: pairID); drain(q)
            q.sync {
                precondition(motorWrites(lp, model: .joyCon2Left).count == 1)
                precondition(motorWrites(rp, model: .joyCon2Right).count == 1)
                precondition(l.rumbleTarget.strong == 0.3 && r.rumbleTarget.strong == 0.3)
            }
        }
        test("stale controller identity cannot rumble a reused player or physical slot") {
            let q = DispatchQueue(label: "rumble-reused")
            let engine = RumbleTestEngine(queue: q)
            let (old, oldP, oldD) = fixture(.proController2, queue: q)
            let (new, newP, newD) = fixture(.proController2, queue: q)
            defer { q.sync { old.teardown(); new.teardown() }; _ = oldD; _ = newD }
            q.sync {
                old.teardown()
                engine.sessions[0] = new
                engine.players[0] = .init(id: new.serialNumber, slots: [0], model: .proController2, isPair: false)
            }
            engine.testRumble(serial: old.serialNumber); drain(q)
            q.sync { precondition(oldP.writes.isEmpty && newP.writes.isEmpty) }
        }
        test("GameCube game requests remain guarded and keep-alives remain intact") {
            let q = DispatchQueue(label: "rumble-gc-game")
            let (s, p, d) = fixture(.nsoGameCube, queue: q)
            defer { q.sync { s.teardown() }; _ = d }
            q.sync { s.lastWriteAt = 0 }
            s.setRumble(strong: 1, weak: 1); drain(q)
            q.sync {
                precondition(p.writes.count == 1 && p.writes[0].0[0] == Switch2.Command.leds)
                precondition(motorWrites(p, model: .nsoGameCube).isEmpty)
                reply(s)
            }
        }
    }
}
