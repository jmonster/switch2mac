import Foundation

// Only the radio is fake. tests/support/prepare-sources.py compiles the complete
// production ControllerTransport, retaining every lifecycle/retry method body.
let CBCentralManagerScanOptionAllowDuplicatesKey = "duplicates"
let CBAdvertisementDataManufacturerDataKey = "manufacturer"
protocol CBCentralManagerDelegate: AnyObject {}
final class CBCentralManager {
    enum State { case unknown, resetting, unsupported, unauthorized, poweredOn, poweredOff }
    weak var delegate: (any CBCentralManagerDelegate)?
    var state = State.poweredOn
    var isScanning = false
    var scans = 0, stops = 0
    var connections: [UUID] = []
    var cancelled: [UUID] = []
    init(delegate: (any CBCentralManagerDelegate)?, queue: DispatchQueue?) { self.delegate = delegate }
    func scanForPeripherals(withServices: [String]?, options: [String: Any]?) {
        precondition(options?[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool == false)
        isScanning = true; scans += 1
    }
    func connect(_ peripheral: CBPeripheral, options: [String: Any]?) { connections.append(peripheral.identifier) }
    func stopScan() { isScanning = false; stops += 1 }
    func cancelPeripheralConnection(_ peripheral: CBPeripheral) { cancelled.append(peripheral.identifier) }
}

// The dashboard's automatic/eight-device policy is explicit, not the kit default.
typealias BridgeEngine = ControllerTransport
extension ControllerTransport {
    static func fixture() -> ControllerTransport {
        let transport = ControllerTransport(configuration: .init(discoveryMode: .automatic, maximumControllers: 8),
                                            hub: ControllerEventHub(), diagnostics: Switch2Diagnostics())
        transport.start()
        transport.btQueue.sync { transport.centralManagerDidUpdateState(transport.central) }
        return transport
    }
}
