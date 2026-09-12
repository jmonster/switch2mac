// VirtualHID.swift
// The system-wide sink: one CoreHID virtual gamepad per connected controller.
// Publishes a generic gamepad for compatible HID consumers. Requires the
// com.apple.developer.hid.virtual.device entitlement; other output sinks
// remain independent when virtual-device creation fails.
//
// Report layout (14 bytes, must match `gamepadDescriptor`):
//   bytes 0-2: 19 buttons (bit i = button i in our fixed order) + 5 pad bits
//   bytes 3-10: X, Y, Z, Rz as signed 16-bit LE (sticks)
//   bytes 11-12: Rx, Ry as unsigned 8-bit (triggers)
//   byte 13: hat switch in low nibble (0-7 clockwise from north, 8 = null)
//
// Button order matches the SDL driver for consistency:
//   0=B 1=A 2=Y 3=X 4=MINUS 5=HOME 6=PLUS 7=LSTICK 8=RSTICK 9=L 10=R
//   11..14 unused here (d-pad goes to the hat) 15=CAPTURE 16=GR 17=GL 18=C
//
// Rumble: generic HID gamepads have no standardized output-report rumble on
// macOS, so this sink does not carry rumble; the UDP/SDL path does.

import Foundation
import CoreHID

final class VirtualHIDSink: ControllerOutputSink, OutputHealthProviding {

    // This descriptor has no rumble output report.
    var onRumble: ((Int, Double, Double) -> Void)? { get { nil } set {} }
    private let slots = (0..<4).map { Slot(index: $0) }

    var outputBackend: OutputBackend { .hid }
    func requestHealth(_ reply: @escaping @Sendable (OutputHealth) -> Void) {
        let snapshots = slots.map { $0.healthSnapshot() }
        let active = snapshots.filter { $0.active }.count
        let failures = slots.indices.filter { snapshots[$0].failed }
        let state: OutputHealth.State
        if !failures.isEmpty { state = active > 0 ? .degraded : .unavailable }
        else if snapshots.contains(where: { $0.pending }) { state = .starting }
        else { state = active > 0 ? .deviceActive : .idle }
        reply(OutputHealth(backend: .hid, state: state, activeCount: active, affectedSlots: failures))
    }

    deinit { for slot in slots { slot.finish() } }

    /// Generic gamepad: 19 buttons, two 16-bit stick pairs, two 8-bit
    /// triggers, one hat. Mirrors the probe descriptor that validated the
    /// entitlement path, extended to 19 buttons.
    private static let gamepadDescriptor = Data([
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x05,        // Usage (Game Pad)
        0xA1, 0x01,        // Collection (Application)
        0x05, 0x09,        //   Usage Page (Button)
        0x19, 0x01,        //   Usage Minimum (1)
        0x29, 0x13,        //   Usage Maximum (19)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x01,        //   Logical Maximum (1)
        0x75, 0x01,        //   Report Size (1)
        0x95, 0x13,        //   Report Count (19)
        0x81, 0x02,        //   Input (Data,Var,Abs)
        0x75, 0x01,        //   Report Size (1) — pad to 24 bits
        0x95, 0x05,        //   Report Count (5)
        0x81, 0x03,        //   Input (Const)
        0x05, 0x01,        //   Usage Page (Generic Desktop)
        0x09, 0x30,        //   Usage (X)
        0x09, 0x31,        //   Usage (Y)
        0x09, 0x32,        //   Usage (Z)
        0x09, 0x35,        //   Usage (Rz)
        0x16, 0x00, 0x80,  //   Logical Minimum (-32768)
        0x26, 0xFF, 0x7F,  //   Logical Maximum (32767)
        0x75, 0x10,        //   Report Size (16)
        0x95, 0x04,        //   Report Count (4)
        0x81, 0x02,        //   Input (Data,Var,Abs)
        0x09, 0x33,        //   Usage (Rx)
        0x09, 0x34,        //   Usage (Ry)
        0x15, 0x00,        //   Logical Minimum (0)
        0x26, 0xFF, 0x00,  //   Logical Maximum (255)
        0x75, 0x08,        //   Report Size (8)
        0x95, 0x02,        //   Report Count (2)
        0x81, 0x02,        //   Input (Data,Var,Abs)
        0x09, 0x39,        //   Usage (Hat switch)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x07,        //   Logical Maximum (7)
        0x35, 0x00,        //   Physical Minimum (0)
        0x46, 0x3B, 0x01,  //   Physical Maximum (315)
        0x65, 0x14,        //   Unit (Eng Rot: degrees)
        0x75, 0x04,        //   Report Size (4)
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x42,        //   Input (Data,Var,Abs,Null)
        0x75, 0x04,        //   Report Size (4) — pad nibble
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x03,        //   Input (Const)
        0xC0               // End Collection
    ])

    // MARK: ControllerOutputSink (called on the Bluetooth queue)

    func controllerConnected(slot: Int, model: Switch2.Model) {
        guard slots.indices.contains(slot) else { return }
        slots[slot].connect(model)
    }

    func controllerDisconnected(slot: Int) {
        guard slots.indices.contains(slot) else { return }
        slots[slot].disconnect()
    }

    /// Virtual devices are named at creation; renames apply on next connect.
    func controllerName(slot: Int, name: String) {}

    func controllerState(slot: Int, state: ControllerState) {
        guard slots.indices.contains(slot) else { return }
        slots[slot].submit(Self.report(from: state))
    }

    /// One consumer per logical slot, including while an older device retires.
    /// The lock protects admission/state only; no CoreHID call or await holds it.
    private final class Slot: @unchecked Sendable {
        private struct Report: Sendable {
            let data: Data
            let timestamp = SuspendingClock.now
            let admitted = ContinuousClock.now
        }
        private enum Action: Sendable {
            case activate(UInt64, Switch2.Model)
            case report(Report)
            case retire
            case stop
        }
        private let index: Int
        private let lock = NSLock()
        private var requested: (generation: UInt64, model: Switch2.Model)?
        private var generation: UInt64 = 0
        private var reports: [Report] = []
        private var activeGeneration: UInt64?
        private var healthFailed = false
        private var ended = false
        private var worker: Task<Void, Never>?
        private var waiting: (generation: UInt64?, reply: CheckedContinuation<Action, Never>)?

        init(index: Int) { self.index = index }

        func healthSnapshot() -> (active: Bool, pending: Bool, failed: Bool) {
            lock.withLock {
                let active = requested != nil && activeGeneration == requested?.generation && !ended
                return (active, requested != nil && !active && !ended, healthFailed)
            }
        }

        func connect(_ model: Switch2.Model) {
            lock.withLock {
                guard !ended else { return }
                generation &+= 1
                healthFailed = false
                requested = (generation, model)
                reports.removeAll(keepingCapacity: true)
                if worker == nil { worker = Task { await self.run() } }
                wakeLocked()
            }
        }

        func disconnect() {
            lock.withLock {
                healthFailed = false
                requested = nil
                reports.removeAll(keepingCapacity: true)
                wakeLocked()
            }
        }

        func finish() {
            lock.withLock {
                ended = true
                healthFailed = false
                requested = nil
                reports.removeAll()
                wakeLocked()
            }
        }

        func submit(_ data: Data) {
            let overflow = lock.withLock {
                guard !ended, requested != nil else { return false }
                // Bound admission BEFORE scheduling work, not inside a queued closure.
                guard reports.count < 128 else {
                    healthFailed = true
                    requested = nil
                    reports.removeAll(keepingCapacity: true)
                    wakeLocked()
                    return true
                }
                reports.append(Report(data: data))
                wakeLocked()
                return false
            }
            if overflow { logFailure("report queue full; reconnect to retry") }
        }

        private func actionLocked(for current: UInt64?) -> Action? {
            if ended { return .stop }
            guard let current else {
                return requested.map { .activate($0.generation, $0.model) }
            }
            guard requested?.generation == current else { return .retire }
            return reports.isEmpty ? nil : .report(reports.removeFirst())
        }

        private func wakeLocked() {
            guard let waiter = waiting, let action = actionLocked(for: waiter.generation) else { return }
            waiting = nil
            waiter.reply.resume(returning: action)
        }

        private func next(for current: UInt64?) async -> Action {
            await withCheckedContinuation { reply in
                lock.withLock {
                    if let action = actionLocked(for: current) { reply.resume(returning: action) }
                    else { waiting = (current, reply) }
                }
            }
        }

        private func isCurrent(_ current: UInt64) -> Bool {
            lock.withLock { !ended && requested?.generation == current }
        }

        private func fail(_ current: UInt64, _ reason: String) {
            lock.withLock {
                // An old operation's error must not discard its replacement's input.
                if requested?.generation == current {
                    healthFailed = true
                    requested = nil
                    reports.removeAll(keepingCapacity: true)
                }
            }
            logFailure(reason)
        }

        private func logFailure(_ reason: String) {
            bridgeLog(.warning, "virtualhid", "slot \(index + 1): \(reason)")
        }

        private func neutralize(_ device: HIDVirtualDevice?) async {
            guard let device else { return }
            do {
                try await device.dispatchInputReport(data: VirtualHIDSink.report(from: ControllerState()),
                                                     timestamp: SuspendingClock.now)
            } catch { logFailure("neutral report failed: \(error)") }
        }

        private func run() async {
            // Only this consumer owns the device, across activation AND report awaits.
            var current: UInt64?
            var device: HIDVirtualDevice?
            while true {
                switch await next(for: current) {
                case let .activate(token, model):
                    guard isCurrent(token) else { continue }
                    current = token
                    let props = HIDVirtualDevice.Properties(
                        descriptor: VirtualHIDSink.gamepadDescriptor,
                        vendorID: UInt32(Switch2.nintendoVendorID), productID: UInt32(model.rawValue),
                        transport: nil, product: "\(model.displayName) (GameCubed)",
                        manufacturer: "GameCubed",
                        serialNumber: "FTCW-slot\(index + 1)", uniqueID: "com.petersharma.ftcw.slot\(index + 1)")
                    guard let created = HIDVirtualDevice(properties: props) else {
                        fail(token, "virtual device creation refused; check HID entitlement and device properties")
                        continue
                    }
                    device = created
                    await created.activate(delegate: NullHIDDelegate.shared)
                    lock.withLock {
                        if requested?.generation == token, !ended { activeGeneration = token }
                    }
                    if isCurrent(token) {
                        bridgeLog(.info, "virtualhid", "slot \(index + 1): virtual gamepad activated")
                    }
                case let .report(report):
                    guard let current, let device, isCurrent(current) else { continue }
                    guard report.admitted.duration(to: .now) < .seconds(1) else {
                        fail(current, "report queue stale; reconnect to retry")
                        continue
                    }
                    do {
                        try await device.dispatchInputReport(data: report.data, timestamp: report.timestamp)
                    } catch { fail(current, "input report failed: \(error)") }
                case .retire:
                    await neutralize(device)
                    device = nil
                    current = nil
                case .stop:
                    await neutralize(device)
                    device = nil
                    return
                }
            }
        }
    }

    // MARK: Report building

    private static func report(from state: ControllerState) -> Data {
        let b = state.buttons
        var bits: UInt32 = 0
        func set(_ index: Int, _ on: Bool) { if on { bits |= 1 << index } }
        set(0, b.contains(.b)); set(1, b.contains(.a))
        set(2, b.contains(.y)); set(3, b.contains(.x))
        set(4, b.contains(.minus)); set(5, b.contains(.home)); set(6, b.contains(.plus))
        set(7, b.contains(.lStick)); set(8, b.contains(.rStick))
        set(9, b.contains(.l)); set(10, b.contains(.r))
        set(15, b.contains(.capture)); set(16, b.contains(.gr))
        set(17, b.contains(.gl)); set(18, b.contains(.c))

        func axis(_ v: Double) -> Int16 {
            guard v.isFinite else { return 0 }
            return Int16(max(-32768, min(32767, v * 32767)))
        }

        var d = Data(capacity: 14)
        d.append(UInt8(bits & 0xFF))
        d.append(UInt8((bits >> 8) & 0xFF))
        d.append(UInt8((bits >> 16) & 0xFF))
        for value in [axis(state.leftStick.x), axis(-state.leftStick.y),
                      axis(state.rightStick.x), axis(-state.rightStick.y)] {
            withUnsafeBytes(of: value.littleEndian) { d.append(contentsOf: $0) }
        }
        d.append(state.leftTrigger)
        d.append(state.rightTrigger)
        d.append(hatValue(b))
        return d
    }

    /// Hat: 0=N 1=NE 2=E 3=SE 4=S 5=SW 6=W 7=NW, 8=released (null state).
    private static func hatValue(_ b: Switch2.Buttons) -> UInt8 {
        let up = b.contains(.dpadUp), down = b.contains(.dpadDown)
        let left = b.contains(.dpadLeft), right = b.contains(.dpadRight)
        switch (up, right, down, left) {
        case (true, false, false, false): return 0
        case (true, true, false, false): return 1
        case (false, true, false, false): return 2
        case (false, true, true, false): return 3
        case (false, false, true, false): return 4
        case (false, false, true, true): return 5
        case (false, false, false, true): return 6
        case (true, false, false, true): return 7
        default: return 8
        }
    }
}

/// The controller has no meaningful get/set report handling on the virtual
/// device (rumble travels the UDP path), but CoreHID requires a delegate.
final class NullHIDDelegate: HIDVirtualDeviceDelegate {
    static let shared = NullHIDDelegate()

    func hidVirtualDevice(_ device: HIDVirtualDevice,
                          receivedSetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, data: Data) async throws {}

    func hidVirtualDevice(_ device: HIDVirtualDevice,
                          receivedGetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, maxSize: Int) async throws -> Data {
        Data()
    }
}
