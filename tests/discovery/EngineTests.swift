import Foundation
@main enum DiscoveryEngineTests {
    static func main() {
        let engine = BridgeEngine()
        engine.btQueue.sync {
            engine.updateScanning()
            precondition(engine.central.isScanning, "continuous discovery must remain the default")
            func connect(_ slot: Int) -> ControllerSession {
                let s = ControllerSession(peripheral: CBPeripheral(), slot: slot, wasPairingMode: false,
                                          queue: engine.btQueue, delegate: engine)
                engine.connecting[s.peripheral.identifier] = (s, slot)
                engine.sessionReady(s)
                return s
            }
            let first = connect(0), second = connect(1)
            precondition(engine.central.isScanning)
            engine.discoveryDefaults.set(true, forKey: DiscoveryPolicy.enabledKey)
            engine.updateScanning()
            precondition(engine.central.isScanning && engine.discovery.windowIsOpen())
            engine.discovery.cancelWindow(); engine.updateScanning()
            precondition(!engine.central.isScanning && engine.lastState == .ready)
            precondition(engine.sessions[0] === first && engine.sessions[1] === second)
            // An advertisement already queued before stopScan must not initiate
            // a new connection while the remembered-ready set is intentionally quiet.
            var advertisement = Data(repeating: 0, count: 18)
            advertisement[0] = 0x53; advertisement[1] = 0x05
            advertisement[5] = 0x7e; advertisement[6] = 0x05
            advertisement[7] = 0x69; advertisement[8] = 0x20
            engine.centralManager(engine.central, didDiscover: CBPeripheral(),
                advertisementData: [CBAdvertisementDataManufacturerDataKey: advertisement], rssi: -40)
            precondition(engine.connecting.isEmpty && engine.central.connections.isEmpty)
            engine.retire(second, cancel: false)
            precondition(engine.central.isScanning, "missing remembered unit must immediately resume discovery")
            precondition(engine.sessions[0] === first)
            engine.discovery.useConnected([first.peripheral.identifier]); engine.updateScanning()
            precondition(!engine.central.isScanning)
        }
        engine.requestDiscoveryWindow()
        engine.btQueue.sync {
            precondition(engine.central.isScanning && engine.discovery.windowIsOpen())
            precondition(engine.sessions.count == 1, "opening discovery must not interrupt active input")
        }
        let done = DispatchSemaphore(value: 0)
        engine.stop { done.signal() }
        precondition(done.wait(timeout: .now() + 2) == .success)
        engine.btQueue.sync {
            precondition(!engine.central.isScanning && !engine.discovery.windowIsOpen())
            precondition(engine.sessions.isEmpty && engine.deadlines.isEmpty)
            engine.discoveryDefaults.set(false, forKey: DiscoveryPolicy.enabledKey)
        }
        engine.resume()
        engine.btQueue.sync { precondition(engine.central.isScanning) }
        print("PASS real engine discovery gating, missing-controller recovery, stale advertisements, manual window and stop/resume")
    }
}
