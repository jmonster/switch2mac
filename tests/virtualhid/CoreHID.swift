// Test-only framework double. Gates emulate actor suspension without an HID entitlement.
import Foundation

public enum HIDReportType: Sendable { case input, output, feature }
public typealias HIDReportID = UInt8
public protocol HIDVirtualDeviceDelegate: AnyObject, Sendable {
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, data: Data) async throws
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, maxSize: Int) async throws -> Data
}

public actor Gate {
    private var open: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init(open: Bool) { self.open = open }
    public func wait() async {
        if !open { await withCheckedContinuation { waiters.append($0) } }
    }
    public func release() {
        open = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

public struct Event: Sendable {
    public let id: Int
    public let kind: String
    public let data: Data
    public let timestamp: SuspendingClock.Instant?
}
public final class DeviceControl: Sendable {
    public let id: Int
    public let properties: HIDVirtualDevice.Properties
    public let activation: Gate
    public let writes: Gate
    init(id: Int, properties: HIDVirtualDevice.Properties, activation: Bool, writes: Bool) {
        self.id = id; self.properties = properties
        self.activation = Gate(open: !activation); self.writes = Gate(open: !writes)
    }
}

public final class Probe: @unchecked Sendable {
    public static let shared = Probe()
    private let lock = NSLock()
    private var records: [Event] = []
    private var controls: [DeviceControl] = [] // Does not retain a device.
    private var attempts = 0
    private var configuration = (activation: false, writes: false, refused: false)
    private var failing: Set<Int> = []
    public func configure(activation: Bool = false, writes: Bool = false, refused: Bool = false) {
        lock.withLock { configuration = (activation, writes, refused) }
    }
    public func failNext(_ id: Int) { lock.withLock { _ = failing.insert(id) } }
    fileprivate func shouldFail(_ id: Int) -> Bool { lock.withLock { failing.remove(id) != nil } }
    public var events: [Event] { lock.withLock { records } }
    public var devices: [DeviceControl] { lock.withLock { controls } }
    public var creationAttempts: Int { lock.withLock { attempts } }
    fileprivate func create(_ properties: HIDVirtualDevice.Properties) -> DeviceControl? {
        lock.withLock {
            attempts += 1
            guard !configuration.refused else { return nil }
            let control = DeviceControl(id: controls.count, properties: properties,
                                        activation: configuration.activation, writes: configuration.writes)
            controls.append(control)
            records.append(Event(id: control.id, kind: "created", data: Data(), timestamp: nil))
            return control
        }
    }
    fileprivate func record(_ id: Int, _ kind: String, _ data: Data = Data(),
                            _ timestamp: SuspendingClock.Instant? = nil) {
        lock.withLock { records.append(Event(id: id, kind: kind, data: data, timestamp: timestamp)) }
    }
}

public actor HIDVirtualDevice {
    public struct Properties: Sendable {
        public let descriptor: Data
        public let vendorID: UInt32
        public let productID: UInt32
        public init(descriptor: Data, vendorID: UInt32, productID: UInt32, transport: String?,
                    product: String, manufacturer: String, serialNumber: String, uniqueID: String) {
            self.descriptor = descriptor; self.vendorID = vendorID; self.productID = productID
        }
    }
    private let control: DeviceControl
    public init?(properties: Properties) {
        guard let control = Probe.shared.create(properties) else { return nil }
        self.control = control
    }
    deinit { Probe.shared.record(control.id, "destroyed") }
    public func activate(delegate: any HIDVirtualDeviceDelegate) async {
        Probe.shared.record(control.id, "activating")
        await control.activation.wait()
        Probe.shared.record(control.id, "activated")
    }
    public func dispatchInputReport(data: Data, timestamp: SuspendingClock.Instant) async throws {
        Probe.shared.record(control.id, "writing", data, timestamp)
        await control.writes.wait()
        if Probe.shared.shouldFail(control.id) {
            Probe.shared.record(control.id, "failed", data, timestamp)
            throw CocoaError(.fileWriteUnknown)
        }
        Probe.shared.record(control.id, "sent", data, timestamp)
    }
}
