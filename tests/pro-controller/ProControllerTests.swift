import Foundation

private final class ProDelegate: ControllerSessionDelegate {
    var ready = 0, failures = 0
    func sessionReady(_ session: ControllerSession) { ready += 1 }
    func sessionFailed(_ session: ControllerSession, reason: String) { failures += 1 }
    func sessionDidUpdateState(_ session: ControllerSession) {}
}

@main
private enum ProControllerTests {
    static func put16(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    static func put32(_ value: UInt32, into data: inout Data, at offset: Int) {
        for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    static func packed(_ x: UInt16, _ y: UInt16) -> Data {
        let value = UInt32(x) | UInt32(y) << 12
        return Data((0..<3).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }
    static func calibration(_ cx: UInt16, _ cy: UInt16, _ px: UInt16, _ py: UInt16,
                            _ nx: UInt16, _ ny: UInt16) -> Data {
        packed(cx, cy) + packed(px, py) + packed(nx, ny) + Data([0, 0])
    }
    static func report(buttons: Switch2.Buttons = []) -> Data {
        var d = Data(repeating: 0, count: 63)
        put32(buttons.rawValue, into: &d, at: 4)
        d.replaceSubrange(10..<13, with: packed(2048, 2048))
        d.replaceSubrange(13..<16, with: packed(2048, 2048))
        return d
    }
    static func fixture(pairing: Bool = false) -> (ControllerSession, CBPeripheral, DispatchQueue, ProDelegate) {
        let radio = CBPeripheral(), queue = DispatchQueue(label: "pro-tests"), delegate = ProDelegate()
        let session = ControllerSession(peripheral: radio, slot: 0, wasPairingMode: pairing,
                                        queue: queue, delegate: delegate)
        for uuid in [Switch2.GATT.commandWrite, Switch2.GATT.commandResponse,
                     Switch2.GATT.inputReport, Switch2.GATT.vibrationPro] {
            session.chars[uuid] = CBCharacteristic(uuid)
        }
        return (session, radio, queue, delegate)
    }
    static func reply(_ session: ControllerSession, _ payload: Data = Data()) {
        let id = session.pendingCommand!.id
        session.handleCommandResponse(Data([id, 1, 0, 0, 0, 0, 0, 0]) + payload)
    }
    static func memoryReply(_ session: ControllerSession, _ block: Data) {
        let request = session.pendingCommand!.frame
        let length = Int(request[8])
        precondition(block.count == length)
        reply(session, request.subdata(in: 8..<16) + block)
    }
    static func identity(vid: UInt16 = 0x057e, pid: UInt16 = 0x2069) -> Data {
        var block = Data(repeating: 0, count: 64)
        block.replaceSubrange(2..<9, with: Data("PROTEST".utf8))
        put16(vid, into: &block, at: 18); put16(pid, into: &block, at: 20)
        return block
    }
    static func main() {
        func test(_ name: String, _ body: () -> Void) { body(); print("PASS Pro \(name)") }
        test("advertisement, wake host and sliced data") {
            var advertisement = Data(repeating: 0, count: 16)
            put16(0x057e, into: &advertisement, at: 3)
            put16(0x2069, into: &advertisement, at: 5)
            precondition(Switch2.parseAdvertisement(manufacturerData: advertisement)?.isPairing == true)
            advertisement.replaceSubrange(10..<16, with: [0xab, 0x89, 0x67, 0x45, 0x23, 0x01])
            let sliced = (Data([0xff]) + advertisement).dropFirst()
            let info = Switch2.parseAdvertisement(manufacturerData: sliced)!
            precondition(info.model == .proController2 && info.reconnectHost == 0x0123456789ab)
            precondition(!info.isPairing)
            precondition(Switch2.parseAdvertisement(manufacturerData: advertisement.prefix(15)) == nil)
            put16(0x2009, into: &advertisement, at: 5)
            precondition(Switch2.parseAdvertisement(manufacturerData: advertisement) == nil)
            put16(0x2069, into: &advertisement, at: 5); advertisement[3] = 0
            precondition(Switch2.parseAdvertisement(manufacturerData: advertisement) == nil)
        }
        test("complete pairing handshake, separate stick calibration and first-report readiness") {
            let (s, p, q, d) = fixture(pairing: true)
            IOBluetoothHostController.testAddress = "01:23:45:67:89:ab"
            defer { q.sync { s.teardown() }; IOBluetoothHostController.testAddress = nil }
            q.sync {
                let service = CBService(); service.characteristics = Array(s.chars.values)
                p.services = [service]
                s.begin()
                s.peripheral(p, didDiscoverServices: nil)
                s.peripheral(p, didDiscoverCharacteristicsFor: service, error: nil)
                precondition(p.writes.isEmpty)
                let response = s.chars[Switch2.GATT.commandResponse]!
                precondition(response.isNotifying)
                s.peripheral(p, didUpdateNotificationStateFor: response, error: nil)
                precondition(Switch2.u32(s.pendingCommand!.frame, 12) == Switch2.Address.controllerInfo)
                memoryReply(s, identity())
                precondition(s.model == .proController2 && s.serialNumber == "PROTEST")
                precondition(Switch2.u32(s.pendingCommand!.frame, 12) == Switch2.Address.userStick1)
                memoryReply(s, Data(repeating: 0, count: 11)) // invalid user slot -> factory
                precondition(Switch2.u32(s.pendingCommand!.frame, 12) == Switch2.Address.factoryStick1)
                memoryReply(s, calibration(1800, 2200, 900, 800, 700, 1200))
                precondition(Switch2.u32(s.pendingCommand!.frame, 12) == Switch2.Address.userStick2)
                memoryReply(s, calibration(2000, 1900, 1100, 700, 1000, 800))
                precondition(s.pendingCommand!.frame == Switch2.buildCommand(9, 7, data: Data([1, 0, 0, 0])))
                reply(s)
                for sub: UInt8 in [2, 4] {
                    precondition(s.pendingCommand!.frame == Switch2.buildCommand(0x0c, sub, data: Data([0xa7, 0, 0, 0])))
                    reply(s)
                }
                let mac = Data([0xab, 0x89, 0x67, 0x45, 0x23, 0x01])
                precondition(s.pendingCommand!.frame == Switch2.buildCommand(0x15, 1, data: Data([0, 2]) + mac + mac))
                reply(s)
                for (sub, payload): (UInt8, Data) in [(4, Switch2.pairLTK1), (2, Switch2.pairLTK2), (3, Data([0]))] {
                    precondition(s.pendingCommand!.frame == Switch2.buildCommand(0x15, sub, data: payload))
                    reply(s)
                }
                let input = s.chars[Switch2.GATT.inputReport]!
                precondition(input.isNotifying && d.ready == 0)
                s.peripheral(p, didUpdateNotificationStateFor: input, error: nil)
                precondition(s.handshakeComplete && d.ready == 0)
                s.handleInputReport(Data(repeating: 0, count: 59))
                precondition(d.ready == 0)
                var bytes = report(buttons: [.gl, .gr, .c, .zl, .zr])
                bytes.replaceSubrange(10..<13, with: packed(2700, 1000))
                bytes.replaceSubrange(13..<16, with: packed(1000, 2600))
                s.handleInputReport(bytes)
                precondition(d.ready == 1 && d.failures == 0)
                precondition(s.state.leftStick == (1, -1) && s.state.rightStick == (-1, 1))
                precondition(s.state.leftTrigger == 255 && s.state.rightTrigger == 255)
                s.handleInputReport(bytes); precondition(d.ready == 1)
            }
        }
        test("reject unknown product and foreign vendor instead of defaulting to Pro") {
            for block in [identity(pid: 0xffff), identity(vid: 0xffff)] {
                let (s, _, q, d) = fixture(); defer { q.sync { s.teardown() }; _ = d }
                q.sync {
                    var accepted = true
                    s.stepReadInfo { accepted = $0 }
                    memoryReply(s, block)
                    precondition(!accepted && s.info == nil)
                }
            }
        }
        test("all 21 buttons, releases, digital triggers and signed telemetry") {
            let (s, _, q, d) = fixture(); defer { q.sync { s.teardown() }; _ = d }
            let controls: [Switch2.Buttons] = [.a, .b, .x, .y, .dpadUp, .dpadDown, .dpadLeft,
                .dpadRight, .l, .r, .zl, .zr, .minus, .plus, .home, .capture, .c, .lStick, .rStick, .gl, .gr]
            q.sync {
                for button in controls {
                    s.handleInputReport(report(buttons: button))
                    precondition(s.state.buttons == button)
                    precondition(s.state.leftTrigger == (button == .zl ? 255 : 0))
                    precondition(s.state.rightTrigger == (button == .zr ? 255 : 0))
                    s.handleInputReport(report()); precondition(s.state.buttons.isEmpty)
                }
                var bytes = report(buttons: controls.reduce([]) { $0.union($1) })
                for (offset, value): (Int, UInt16) in [(31, 4123), (34, 0xff85), (46, 254),
                    (48, 0x8000), (50, 4096), (52, 32767), (54, 0xffff), (56, 0x8000), (58, 32767)] {
                    put16(value, into: &bytes, at: offset)
                }
                bytes[33] = 1; bytes[60] = 17; bytes[61] = 23
                // Preserve nonzero startIndex through the production decoder.
                s.handleInputReport((Data([0]) + bytes).dropFirst())
                precondition(s.state.buttons == controls.reduce([]) { $0.union($1) })
                precondition(s.state.gyro == (-1, -32768, 32767))
                precondition(s.state.accel == (-32768, 4096, 32767))
                precondition(s.state.batteryMillivolts == 4123 && s.state.batteryCurrent == -123)
                precondition(s.state.chargeState == 1 && s.state.temperatureC == 27)
                precondition(s.state.leftTrigger == 255 && s.state.rightTrigger == 255)
                put32(0, into: &bytes, at: 4); s.handleInputReport(bytes)
                precondition(s.state.leftTrigger == 0 && s.state.rightTrigger == 0)
            }
        }
        test("invalid calibration falls back independently and nominal input never freezes") {
            let valid = calibration(2048, 2048, 2047, 2047, 2048, 2048)
            let invalid = [Data(), valid.prefix(8), Data(repeating: 0xff, count: 11),
                Data(repeating: 0, count: 11), calibration(0, 2048, 1000, 1000, 1000, 1000),
                calibration(2048, 4095, 1000, 1000, 1000, 1000),
                calibration(2048, 2048, 0, 1000, 1000, 1000),
                calibration(2048, 2048, 1000, 1000, 1000, 0)]
            for bytes in invalid { precondition(Switch2.StickCalibration(validatedData: bytes) == nil) }
            let cal = Switch2.StickCalibration(validatedData: (Data([0]) + valid).dropFirst())!
            precondition(cal.apply((4095, 0)) == (1, -1))
            let (s, _, q, d) = fixture(); defer { q.sync { s.teardown() }; _ = d }
            q.sync {
                var completed = false
                s.stepReadCalibration { completed = $0 }
                for _ in 0..<4 { memoryReply(s, Data(repeating: 0xff, count: 11)) }
                precondition(completed && s.leftCal == nil && s.rightCal == nil)
                var bytes = report()
                bytes.replaceSubrange(10..<13, with: packed(4095, 0))
                bytes.replaceSubrange(13..<16, with: packed(0, 4095))
                s.handleInputReport(bytes)
                precondition(s.state.leftStick == (1, -1) && s.state.rightStick == (-1, 1))
            }
        }
        test("independent rumble blocks, sequence wrap, finite inputs and uniform haptics") {
            let idle = Switch2.Vibration().packed(), loud = Switch2.Vibration.waveform(strong: 1, weak: 0).packed()
            for (strong, weak, left, right): (Double, Double, Data, Data) in [(1, 0, loud, idle), (0, 1, idle, loud)] {
                let motors = Switch2.MotorVibration.waveform(strong: strong, weak: weak, model: .proController2)
                for id: UInt8 in [0, 15, 16, 255] {
                    let packet = Switch2.motorPacket(motors, packetID: id, model: .proController2)
                    precondition(packet.count == 33 && packet[0] == 0)
                    precondition(packet[1] == 0x50 + (id & 15) && packet[17] == packet[1])
                    for offset in [2, 7, 12] { precondition(packet.subdata(in: offset..<offset+5) == left) }
                    for offset in [18, 23, 28] { precondition(packet.subdata(in: offset..<offset+5) == right) }
                }
            }
            let invalid = Switch2.MotorVibration.waveform(strong: .nan, weak: .infinity, model: .proController2)
            precondition(invalid.left.packed() == idle && invalid.right.packed() == idle)
            precondition(Switch2.Vibration.tone(freqHz: 225, amp: .nan).packed() == idle)
            let tone = Switch2.Vibration.tone(freqHz: 200, amp: 0.1)
            let packet = Switch2.motorPacket(tone, packetID: 0, model: .proController2)
            precondition(packet.subdata(in: 1..<17) == packet.subdata(in: 17..<33))
            precondition(Switch2.motorPacket(tone, packetID: 0, model: .joyCon2Left).count == 17)
        }
        test("rumble replacement, stop, expiration and per-write sequence under backpressure") {
            let (s, p, q, d) = fixture(); defer { q.sync { s.teardown() }; _ = d }
            q.sync {
                p.canSendWriteWithoutResponse = false
                s.applyRumble(strong: 1, weak: 0)
                s.applyRumble(strong: 0, weak: 1)
                precondition(p.writes.isEmpty && s.vibrationPacketID == 0)
                p.canSendWriteWithoutResponse = true
                s.peripheralIsReady(toSendWriteWithoutResponse: p)
                precondition(p.writes.last!.0 == Switch2.motorPacket(
                    .waveform(strong: 0, weak: 1, model: .proController2), packetID: 0, model: .proController2))
                s.applyRumble(strong: 0, weak: 0)
                precondition(p.writes.last!.0 == Switch2.motorPacket(Switch2.MotorVibration.stopped, packetID: 1, model: .proController2))
                p.canSendWriteWithoutResponse = false
                s.applyRumble(strong: 1, weak: 1)
                s.pendingMotor?.expires = 0
                p.canSendWriteWithoutResponse = true
                s.peripheralIsReady(toSendWriteWithoutResponse: p)
                precondition(p.writes.last!.0 == Switch2.motorPacket(Switch2.MotorVibration.stopped, packetID: 2, model: .proController2))
                s.vibrationPacketID = 15
                s.applyRumble(strong: 1, weak: 0); s.applyRumble(strong: 0, weak: 0)
                precondition(p.writes.suffix(2).map { $0.0[1] } == [0x5f, 0x50])
            }
        }
        test("missing motor characteristic or small MTU preserves LED keep-alive") {
            for missing in [false, true] {
                let (s, p, q, d) = fixture(); defer { q.sync { s.teardown() }; _ = d }
                q.sync {
                    if missing { s.chars.removeValue(forKey: Switch2.GATT.vibrationPro) }
                    else { p.writeLimit = 20 } // commands fit, atomic 33-byte Pro motor frame does not
                    for _ in 0..<3 {
                        s.lastWriteAt = 0
                        s.applyRumble(strong: 1, weak: 1)
                        precondition(s.pendingMotor == nil && !s.rumbleActive)
                        precondition(p.writes.last!.0.first == Switch2.Command.leds)
                        reply(s)
                    }
                    precondition(p.writes.count == 3 && s.vibrationPacketID == 0)
                }
            }
        }
        test("GL/GR/C remapping includes digital trigger output and release") {
            let config = ControllerConfiguration(["buttonMap": ["GL": "ZL", "GR": "ZR", "C": "Capture"]])
            var state = ControllerState(); state.buttons = [.gl, .gr, .c]
            var mapped = config.apply(state, analogTriggers: false)
            precondition(mapped.buttons == [.zl, .zr, .capture])
            precondition(mapped.leftTrigger == 255 && mapped.rightTrigger == 255)
            ControllerConfiguration.suppress([.zl, .zr], in: &mapped, analogTriggers: false)
            precondition(mapped.leftTrigger == 0 && mapped.rightTrigger == 0)
            let released = config.apply(ControllerState(), analogTriggers: false)
            precondition(released.buttons.isEmpty && released.leftTrigger == 0 && released.rightTrigger == 0)
        }
    }
}
