import Foundation

@main enum RetryTests {
    static func advertisement(pairing: Bool = true) -> Data {
        var data = Data(repeating: 0, count: 18)
        data[0] = 0x53; data[1] = 0x05
        data[5] = 0x7e; data[6] = 0x05
        data[7] = 0x69; data[8] = 0x20
        if !pairing { data[12] = 1 }
        return data
    }
    static func discover(_ engine: BridgeEngine, _ radio: CBPeripheral, data: Data? = nil) {
        engine.centralManager(engine.central, didDiscover: radio,
            advertisementData: [CBAdvertisementDataManufacturerDataKey: data ?? advertisement()], rssi: -40)
    }
    static func ready(_ engine: BridgeEngine, slot: Int) -> ControllerSession {
        let session = ControllerSession(peripheral: CBPeripheral(), slot: slot, wasPairingMode: false,
                                        queue: engine.btQueue, delegate: engine)
        engine.sessions[slot] = session
        return session
    }
    static func failed(_ engine: BridgeEngine) -> CBPeripheral {
        let radio = CBPeripheral()
        engine.updateScanning(); discover(engine, radio)
        precondition(engine.connecting[radio.identifier] != nil)
        engine.centralManager(engine.central, didFailToConnect: radio, error: nil)
        precondition(engine.connecting.isEmpty && engine.retryAfter[radio.identifier] != nil)
        return radio
    }
    static func expire(_ engine: BridgeEngine, _ id: UUID) -> DispatchWorkItem {
        let work = engine.retryWake!
        engine.retryAfter[id] = 0; engine.retryWakeAt = 0
        work.perform()
        return work
    }
    static func main() {
        func test(_ name: String, _ body: (BridgeEngine) -> Void) {
            let engine = BridgeEngine()
            engine.btQueue.sync {
                defer { engine.running = false; engine.resetConnections(cancel: true) }
                body(engine)
            }
            print("PASS retry \(name)")
        }
        test("one-shot-rediscovery-without-advertisement") { engine in
            let radio = failed(engine), scans = engine.central.scans
            let work = expire(engine, radio.identifier)
            precondition(engine.central.scans == scans + 1 && engine.central.connections.count == 1)
            precondition(engine.retryWake == nil && engine.retryAfter.isEmpty)
            work.perform()
            precondition(engine.central.scans == scans + 1, "an already consumed wake must not restart scanning")
        }
        test("bounded-advertisements-preserve-latest-mode-and-one-timer") { engine in
            let radio = failed(engine)
            engine.retryAfter[radio.identifier] = ProcessInfo.processInfo.systemUptime + 30
            engine.updateScanning()
            let generation = engine.retryWakeGeneration
            for _ in 0..<1000 { discover(engine, radio, data: advertisement(pairing: false)) }
            precondition(engine.retryAdvertisements.count == 1 && engine.retryWakeGeneration == generation)
            precondition(engine.retryAdvertisements[radio.identifier]?.wasPairingMode == false)
            var foreign = advertisement(); foreign[5] = 0xff
            discover(engine, radio, data: foreign)
            discover(engine, radio, data: Data([0]))
            precondition(engine.retryAdvertisements[radio.identifier]?.wasPairingMode == false)
            _ = expire(engine, radio.identifier)
            precondition(engine.connecting[radio.identifier]?.session.wasPairingMode == false)
            precondition(engine.retryAdvertisements.isEmpty && engine.retryWake == nil)
        }
        test("cancellation-barrier-and-late-connect") { engine in
            engine.updateScanning()
            let radio = CBPeripheral(); discover(engine, radio)
            let session = engine.connecting[radio.identifier]!.session
            engine.deadlines[radio.identifier]!.perform()
            precondition(session.isRetired && engine.disconnecting.contains(radio.identifier))
            discover(engine, radio)
            let work = expire(engine, radio.identifier)
            precondition(engine.central.connections.count == 1 && engine.connecting.isEmpty)
            precondition(engine.retryWake == nil, "waiting for terminal cancellation must not busy-poll")
            engine.centralManager(engine.central, didConnect: radio)
            precondition(engine.connecting.isEmpty)
            engine.centralManager(engine.central, didDisconnectPeripheral: radio, error: nil)
            precondition(engine.central.connections.count == 2)
            let replacement = engine.connecting[radio.identifier]!.session
            precondition(replacement !== session)
            work.perform(); engine.sessionFailed(session, reason: "obsolete failure")
            precondition(engine.connecting[radio.identifier]?.session === replacement)
        }
        test("expired-observation-after-delayed-cancellation-refreshes-scan") { engine in
            engine.updateScanning(); let radio = CBPeripheral(); discover(engine, radio)
            engine.deadlines[radio.identifier]!.perform(); discover(engine, radio)
            _ = expire(engine, radio.identifier)
            engine.retryAdvertisements[radio.identifier] = BridgeEngine.RetryAdvertisement(
                peripheral: radio, wasPairingMode: true, expiresAt: 0)
            let scans = engine.central.scans
            engine.centralManager(engine.central, didDisconnectPeripheral: radio, error: nil)
            precondition(engine.central.scans == scans + 1 && engine.central.connections.count == 1)
            precondition(engine.retryAdvertisements.isEmpty)
            discover(engine, radio)
            precondition(engine.central.connections.count == 2)
        }
        test("replacement-generation-ignores-old-deadline") { engine in
            let radio = failed(engine), old = engine.retryWake!
            let oldGeneration = engine.retryWakeGeneration
            discover(engine, radio)
            engine.noteConnectionFailure(radio.identifier); engine.updateScanning()
            precondition(engine.retryWakeGeneration != oldGeneration)
            let replacement = engine.retryWake!
            old.perform()
            precondition(engine.retryWake === replacement && engine.retryAdvertisements.isEmpty)
            precondition(engine.central.connections.count == 1)
        }
        test("capacity-and-current-handshake-preserve-active-controllers") { engine in
            let radio = failed(engine); discover(engine, radio)
            var sessions: [ControllerSession] = []
            for slot in 0..<8 { sessions.append(ready(engine, slot: slot)) }
            engine.updateScanning()
            precondition(!engine.central.isScanning && engine.retryWake == nil)
            engine.retryAfter[radio.identifier] = 0
            engine.retire(sessions[7], cancel: false)
            precondition(engine.connecting[radio.identifier]?.slot == 7 && engine.sessions.count == 7)
            let candidate = CBPeripheral()
            engine.noteConnectionFailure(candidate.identifier)
            engine.retryAdvertisements[candidate.identifier] = BridgeEngine.RetryAdvertisement(
                peripheral: candidate, wasPairingMode: false, expiresAt: ProcessInfo.processInfo.systemUptime + 10)
            engine.retryAfter[candidate.identifier] = 0
            engine.updateScanning()
            precondition(engine.connecting.count == 1 && !engine.central.isScanning && engine.retryWake == nil)
            for slot in 0..<7 { precondition(engine.sessions[slot] === sessions[slot] && !sessions[slot].isRetired) }
        }
        test("quiet-policy-revokes-cached-discovery") { engine in
            let radio = failed(engine); discover(engine, radio)
            let active = ready(engine, slot: 0)
            engine.discoveryDefaults.set(true, forKey: DiscoveryPolicy.enabledKey)
            engine.updateScanning(); engine.discovery.useConnected([active.peripheral.identifier]); engine.updateScanning()
            precondition(!engine.central.isScanning && engine.retryWake == nil && engine.retryAdvertisements.isEmpty)
            precondition(engine.sessions[0] === active && !active.isRetired)
        }
        test("cache-saturation-retains-cooldowns-and-bounds-work") { engine in
            engine.updateScanning()
            var radios: [CBPeripheral] = []
            for _ in 0..<64 {
                let radio = CBPeripheral(); radios.append(radio)
                engine.noteConnectionFailure(radio.identifier); discover(engine, radio)
            }
            precondition(engine.retryAfter.count == 64 && engine.retryAdvertisements.count == 64)
            let prior = engine.retryAfter
            let extra = CBPeripheral(); engine.noteConnectionFailure(extra.identifier); discover(engine, extra)
            precondition(engine.retryAfter == prior && engine.retryAdvertisements.count == 64)
            precondition(engine.retryBlockedUntil > ProcessInfo.processInfo.systemUptime && engine.retryWake != nil)
            precondition(engine.central.connections.isEmpty)
        }
        test("bluetooth-off-clears-retry-state") { engine in
            let radio = failed(engine); discover(engine, radio)
            let old = engine.retryWake!
            engine.central.state = .poweredOff; engine.updateScanning(); old.perform()
            precondition(engine.retryAdvertisements.isEmpty && engine.retryAfter.isEmpty && engine.retryWake == nil)
            precondition(engine.central.connections.count == 1)
        }
        // Exercise the public asynchronous stop/suspend/resume methods too.
        for suspend in [false, true] {
            let engine = BridgeEngine()
            var old: DispatchWorkItem!
            engine.btQueue.sync { let radio = failed(engine); discover(engine, radio); old = engine.retryWake }
            if suspend { engine.setSuspended(true) } else { engine.stop() }
            engine.btQueue.sync {
                old.perform()
                precondition(engine.retryWake == nil && engine.retryAdvertisements.isEmpty && engine.retryAfter.isEmpty)
                precondition(engine.central.connections.count == 1)
            }
            if suspend { engine.setSuspended(false) } else { engine.resume() }
            engine.btQueue.sync {
                precondition(engine.central.isScanning)
                old.perform()
                precondition(engine.central.connections.count == 1)
                engine.running = false; engine.resetConnections(cancel: true)
            }
        }
        print("PASS retry public stop/sleep cancel work and resume without stale attempts")
    }
}
