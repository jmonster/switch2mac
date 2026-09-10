// UDPHub.swift
// Compatibility sink: re-broadcasts controller state on localhost UDP, one
// port per slot (24800 + slot), exactly like the original Python bridge —
// so the patched-SDL path (Gopher64-Both et al.) keeps working unchanged.
//
// Wire protocol (little-endian, must match SDL_s2udpjoystick.c):
//   State  out (44 bytes): "S2B1" | u32 seq | u32 buttons
//          | f32 lx,ly,rx,ry | u8 lt,rt | u16 battery_mv
//          | i16 gyro[3] | i16 accel[3]
//   Rumble in  (6 bytes):  "S2R1" | u8 strong | u8 weak
//   An empty hello or valid rumble registers its sender (30 s TTL).

import Foundation
import Darwin

final class UDPHub: ControllerOutputSink, @unchecked Sendable {

    private static let basePort: UInt16 = 24800
    private static let peerTTL: TimeInterval = 30
    private static let maxPeers = 64

    var onRumble: ((Int, Double, Double) -> Void)?

    private final class SlotSocket {
        let fd: Int32
        var peers: [SockAddr: TimeInterval] = [:]
        var seq: UInt32 = 0
        var name: String = ""
        var readSource: DispatchSourceRead?
        init(fd: Int32) { self.fd = fd }
    }

    /// Hashable wrapper for a peer sockaddr_in.
    private struct SockAddr: Hashable {
        let addr: UInt32   // network byte order
        let port: UInt16   // network byte order
    }

    private var slots: [Int: SlotSocket] = [:]
    private let queue = DispatchQueue(label: "com.petersharma.ftcw.udphub")
    private let stateMailbox = BoundedStateMailbox<ControllerState>(
        perSlotCapacity: 64, maxAge: 0.25, batchLimit: 32)

    init() {
        queue.async { [weak self] in self?.openSockets() }
    }

    /// Bind whatever ports are free; retry the rest every 5 s (another bridge
    /// instance may be shutting down, e.g. the old Python one).
    private func openSockets() {
        openMissingSockets()
        if slots.count < BridgeEngine.maxPlayers {
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.openSockets()
            }
        } else {
            bridgeLog(.info, "udphub",
                      "SDL-compat hub on udp://127.0.0.1:\(Self.basePort)-\(Self.basePort + UInt16(BridgeEngine.maxPlayers - 1))")
        }
    }

    private func openMissingSockets() {
        for slot in 0..<BridgeEngine.maxPlayers where slots[slot] == nil {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { continue }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = (Self.basePort + UInt16(slot)).bigEndian
            addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian  // 127.0.0.1
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                bridgeLog(.warning, "udphub",
                          "port \(Self.basePort + UInt16(slot)) busy (another bridge running?) — will retry")
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)

            let slotSocket = SlotSocket(fd: fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.drainSocket(slot: slot)
            }
            source.resume()
            slotSocket.readSource = source
            slots[slot] = slotSocket
        }
    }

    private func drainSocket(slot: Int) {
        guard let s = slots[slot] else { return }
        var buf = [UInt8](repeating: 0, count: 64)
        // Bound each read dispatch so a noisy local peer cannot starve output.
        for _ in 0..<256 {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { fromPtr in
                    recvfrom(s.fd, &buf, buf.count, 0, fromPtr, &fromLen)
                }
            }
            if n < 0 { break }  // EWOULDBLOCK: drained
            let isRumble = n == 6 && buf[0...3].elementsEqual([0x53, 0x32, 0x52, 0x31])
            guard n == 0 || isRumble else { continue }
            let now = ProcessInfo.processInfo.systemUptime
            s.peers = s.peers.filter { now - $0.value <= Self.peerTTL }
            let peer = SockAddr(addr: from.sin_addr.s_addr, port: from.sin_port)
            let isNewPeer = s.peers[peer] == nil
            guard !isNewPeer || s.peers.count < Self.maxPeers else { continue }
            s.peers[peer] = now
            if isNewPeer, !s.name.isEmpty {
                // Late joiners get the name before their first state packet.
                send(Self.namePacket(s.name), to: peer, via: s.fd)
            }
            if isRumble {
                onRumble?(slot, Double(buf[4]) / 255.0, Double(buf[5]) / 255.0)
            }
        }
    }

    // MARK: ControllerOutputSink (called on the Bluetooth queue)

    func controllerConnected(slot: Int, model: Switch2.Model) {
        stateMailbox.clear(slot: slot)
    }

    func controllerName(slot: Int, name: String) {
        queue.async { [weak self] in
            guard let self, let s = self.slots[slot], s.name != name else { return }
            s.name = name
            let packet = Self.namePacket(name)
            for peer in s.peers.keys {
                self.send(packet, to: peer, via: s.fd)
            }
        }
    }

    /// "S2N1" + UTF-8 name (truncated to 59 bytes).
    private static func namePacket(_ name: String) -> Data {
        var d = Data([0x53, 0x32, 0x4E, 0x31])  // "S2N1"
        d.append(Data(name.utf8).prefix(59))
        return d
    }

    private func send(_ packet: Data, to peer: SockAddr, via fd: Int32) {
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = peer.port
        dest.sin_addr.s_addr = peer.addr
        _ = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { destPtr in
                    sendto(fd, bytes.baseAddress, bytes.count, 0,
                           destPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func controllerDisconnected(slot: Int) {
        // Drop reports that have not reached this sink before ordering the
        // neutral state on its serial queue.
        stateMailbox.clear(slot: slot)
        queue.async { [weak self] in
            guard let self, let s = self.slots[slot] else { return }
            self.sendState(slot: slot, state: ControllerState(), socket: s)
            s.name = ""
        }
    }

    func controllerState(slot: Int, state: ControllerState) {
        if stateMailbox.submit(slot: slot, state: state) {
            queue.async { [weak self] in self?.drainStates() }
        }
    }

    private func drainStates() {
        let batch = stateMailbox.take()
        // Overflow/staleness means an edge may no longer be provable. Send a
        // neutral snapshot before the newest state rather than silently losing
        // a release and leaving the consumer stuck.
        for recovery in batch.recoveries {
            guard let socket = slots[recovery.slot] else { continue }
            sendState(slot: recovery.slot, state: ControllerState(), socket: socket)
            sendState(slot: recovery.slot, state: recovery.latest, socket: socket)
            bridgeLog(.warning, "udphub",
                      "slot \(recovery.slot + 1): output backlog recovered with neutral state")
        }
        for item in batch.items {
            guard let socket = slots[item.slot] else { continue }
            sendState(slot: item.slot, state: item.state, socket: socket)
        }
        if stateMailbox.completeDrain() {
            queue.async { [weak self] in self?.drainStates() }
        }
    }

    private func sendState(slot: Int, state: ControllerState, socket s: SlotSocket) {
        guard !s.peers.isEmpty else { return }
        s.seq &+= 1
        let packet = Self.statePacket(seq: s.seq, state: state)
        let now = ProcessInfo.processInfo.systemUptime
        for (peer, seen) in s.peers {
            if now - seen > Self.peerTTL {
                s.peers.removeValue(forKey: peer)
                continue
            }
            send(packet, to: peer, via: s.fd)
        }
    }

    private static func statePacket(seq: UInt32, state: ControllerState) -> Data {
        var d = Data(capacity: 44)
        d.append(contentsOf: [0x53, 0x32, 0x42, 0x31])  // "S2B1"
        append(&d, seq.littleEndian)
        append(&d, state.buttons.rawValue.littleEndian)
        func axis(_ value: Double) -> Float {
            guard value.isFinite else { return 0 }
            return Float(max(-1, min(1, value)))
        }
        append(&d, axis(state.leftStick.x).bitPattern.littleEndian)
        append(&d, axis(state.leftStick.y).bitPattern.littleEndian)
        append(&d, axis(state.rightStick.x).bitPattern.littleEndian)
        append(&d, axis(state.rightStick.y).bitPattern.littleEndian)
        d.append(state.leftTrigger)
        d.append(state.rightTrigger)
        append(&d, state.batteryMillivolts.littleEndian)
        append(&d, UInt16(bitPattern: state.gyro.0).littleEndian)
        append(&d, UInt16(bitPattern: state.gyro.1).littleEndian)
        append(&d, UInt16(bitPattern: state.gyro.2).littleEndian)
        append(&d, UInt16(bitPattern: state.accel.0).littleEndian)
        append(&d, UInt16(bitPattern: state.accel.1).littleEndian)
        append(&d, UInt16(bitPattern: state.accel.2).littleEndian)
        return d
    }

    private static func append<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
}
