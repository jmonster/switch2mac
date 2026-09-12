import Foundation

@main enum CooldownRegression {
    static func main() {
        let engine = BridgeEngine(), peripheral = CBPeripheral()
        var advertisement = Data(repeating: 0, count: 18)
        advertisement[0] = 0x53; advertisement[1] = 0x05
        advertisement[5] = 0x7e; advertisement[6] = 0x05
        advertisement[7] = 0x69; advertisement[8] = 0x20
        engine.btQueue.sync {
            engine.updateScanning()
            engine.centralManager(engine.central, didDiscover: peripheral,
                advertisementData: [CBAdvertisementDataManufacturerDataKey: advertisement], rssi: -40)
            precondition(engine.central.connections == [peripheral.identifier])
            engine.centralManager(engine.central, didFailToConnect: peripheral, error: nil)
            // Shorten the test's recorded deadline; production still uses 2 s.
            engine.retryAfter[peripheral.identifier] = ProcessInfo.processInfo.systemUptime + 0.05
            engine.centralManager(engine.central, didDiscover: peripheral,
                advertisementData: [CBAdvertisementDataManufacturerDataKey: advertisement], rssi: -40)
            precondition(engine.central.connections.count == 1, "must not reconnect before the deadline")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while engine.btQueue.sync(execute: { engine.central.connections.count }) < 2,
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        engine.btQueue.sync {
            precondition(engine.central.connections == [peripheral.identifier, peripheral.identifier],
                         "the only advertisement arrived during cooldown: retry must not require another callback")
            precondition(engine.connecting[peripheral.identifier] != nil)
            engine.running = false; engine.resetConnections(cancel: true)
        }
        print("PASS real failure + one cooldown advertisement triggers a scheduled reconnect")
    }
}
