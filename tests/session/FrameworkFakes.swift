// Test-only stand-ins. The actual macOS app is separately built with Apple SDKs.
import Foundation

struct CBCharacteristicProperties: OptionSet {
    let rawValue: Int
    static let notify = Self(rawValue: 1)
}
final class CBUUID {
    let uuidString: String
    init(_ uuid: UUID) { uuidString = uuid.uuidString }
}
final class CBCharacteristic {
    let uuid: CBUUID
    var properties: CBCharacteristicProperties = [.notify]
    var value: Data?
    var isNotifying = false
    init(_ uuid: UUID) { self.uuid = CBUUID(uuid) }
}
final class CBService { var characteristics: [CBCharacteristic]? }
protocol CBPeripheralDelegate: AnyObject {}
enum CBCharacteristicWriteType { case withoutResponse }
final class CBPeripheral {
    weak var delegate: CBPeripheralDelegate?
    var services: [CBService]?
    var canSendWriteWithoutResponse = true
    var writeLimit = 180
    var writes: [(Data, CBCharacteristic)] = []
    var identifier = UUID()
    func discoverServices(_ uuids: [CBUUID]?) {}
    func discoverCharacteristics(_ uuids: [CBUUID]?, for service: CBService) {}
    func setNotifyValue(_ enabled: Bool, for ch: CBCharacteristic) { ch.isNotifying = enabled }
    func writeValue(_ data: Data, for ch: CBCharacteristic, type: CBCharacteristicWriteType) {
        writes.append((data, ch))
    }
    func readRSSI() {}
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { writeLimit }
}
final class IOBluetoothHostController {
    static var testAddress: String?
    static func `default`() -> IOBluetoothHostController? { IOBluetoothHostController() }
    func addressAsString() -> String? { Self.testAddress }
}
enum LogLevel { case debug, info, warning, error }
func bridgeLog(_ level: LogLevel, _ category: String, _ message: String) {}
