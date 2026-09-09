// Optional RetroArch network-gamepad output, adapted from vialoh/switch2mac
// 2c7a396336f5a657a16a772b8c056d96ec6ff7f1. Disabled by default.
// Native little-endian remote_message: i32 port/device/index/id, u16 state,
// two padding bytes. One paced datagram per player per tick; no rumble ACKs.
import Foundation
import Darwin

final class NetworkGamepadSink: ControllerOutputSink, @unchecked Sendable {
    private static let sendInterval: TimeInterval = 1.0 / 60.0
    private static let refreshInterval: TimeInterval = 2.0
    private static let analogQuantum: Int32 = 512
    private static let maxEdges = 256
    private static let buttonMap: [(Switch2.Buttons, Int)] = [
        (.b, 0), (.y, 1), (.minus, 2), (.plus, 3),
        (.dpadUp, 4), (.dpadDown, 5), (.dpadLeft, 6), (.dpadRight, 7),
        (.a, 8), (.x, 9), (.l, 10), (.r, 11), (.zl, 12), (.zr, 13),
        (.lStick, 14), (.rStick, 15),
    ]
    var onRumble: ((Int, Double, Double) -> Void)?

    private final class Player {
        var wantButtons: UInt16 = 0
        var sentButtons: UInt16 = 0
        var wantAxes = [Int16](repeating: 0, count: 4)
        var sentAxes = [Int16](repeating: 0, count: 4)
        var edges: [(id: Int, state: UInt16)] = []
        var connected = false
        var failed = false
        var port: UInt16?
        var switchIndex: Int?
        var nextSendAt: TimeInterval = 0
        var lastRefreshAt: TimeInterval = 0
        var refreshIndex = 20
        var neutralPasses = 0

        func neutralize() {
            wantButtons = 0; wantAxes = [0, 0, 0, 0]
            edges = (0..<16).filter { sentButtons & (1 << $0) != 0 }.map { ($0, 0) }
            switchIndex = nil
            refreshIndex = 0
            neutralPasses = 2 // best-effort repeat; UDP acceptance is not receipt
        }
        var pending: Bool { !edges.isEmpty || wantAxes != sentAxes || refreshIndex < 20 }
    }

    private let queue = DispatchQueue(label: "com.petersharma.ftcw.netpad")
    private let players = (0..<BridgeEngine.maxPlayers).map { _ in Player() }
    private var fd: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var lastSendErrorAt: TimeInterval = 0
    private var wasEnabled = false

    init() { queue.async { [weak self] in self?.openSocket() } }
    deinit { timer?.cancel(); if fd >= 0 { close(fd) } }
    private func openSocket() {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            bridgeLog(.error, "netpad", "socket() failed: \(String(cString: strerror(errno)))"); return
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    }

    func controllerConnected(slot: Int, model: Switch2.Model) {
        queue.async { [weak self] in
            guard let self, self.players.indices.contains(slot) else { return }
            self.players[slot].connected = true
        }
    }
    func controllerName(slot: Int, name: String) {}
    func controllerDisconnected(slot: Int) {
        queue.async { [weak self] in
            guard let self, self.players.indices.contains(slot) else { return }
            let p = self.players[slot]
            p.connected = false; p.neutralize()
            self.ensurePumping()
        }
    }

    func controllerState(slot: Int, state: ControllerState) {
        guard AppConfig.networkGamepadEnabled else { return }
        queue.async { [weak self] in
            guard let self, self.players.indices.contains(slot), AppConfig.networkGamepadEnabled else { return }
            let p = self.players[slot]
            guard !p.failed else { return }
            p.connected = true
            var buttons: UInt16 = 0
            for (button, id) in Self.buttonMap where state.buttons.contains(button) { buttons |= 1 << id }
            if state.leftTrigger >= 128 { buttons |= 1 << 12 }
            if state.rightTrigger >= 128 { buttons |= 1 << 13 }
            let changed = p.wantButtons ^ buttons
            let edges = (0..<16).filter { changed & (1 << $0) != 0 }.map { ($0, (buttons >> $0) & 1) }
            if p.switchIndex == nil {
                guard p.edges.count + edges.count <= Self.maxEdges else {
                    p.failed = true; p.neutralize(); self.ensurePumping()
                    bridgeLog(.error, "netpad", "player \(slot + 1) edge queue exhausted; neutralizing. Disable/re-enable network output to retry.")
                    return
                }
                p.edges.append(contentsOf: edges)
            }
            p.wantButtons = buttons
            p.wantAxes = [Self.axis(state.leftStick.x), Self.axis(-state.leftStick.y),
                          Self.axis(state.rightStick.x), Self.axis(-state.rightStick.y)]
            self.ensurePumping()
        }
    }

    private static func axis(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        let raw = Int32(max(-1, min(1, value)) * 32767)
        return Int16(raw / analogQuantum * analogQuantum)
    }
    private func ensurePumping() {
        guard timer == nil, fd >= 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.sendInterval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume(); timer = t
    }

    private func pump() {
        let basePort = AppConfig.networkGamepadBasePort
        let enabled = AppConfig.networkGamepadEnabled && (1...65532).contains(basePort)
        let now = ProcessInfo.processInfo.systemUptime
        if !enabled && wasEnabled {
            for p in players { p.neutralize(); p.failed = false }
        }
        wasEnabled = enabled
        var busy = false
        for (slot, p) in players.enumerated() {
            let target: UInt16? = enabled ? UInt16(basePort + slot) : nil
            if p.port == nil { p.port = target }
            guard let port = p.port else { continue }
            let refreshing = (enabled && p.connected) || p.neutralPasses > 0
            if refreshing && now - p.lastRefreshAt >= Self.refreshInterval && p.refreshIndex >= 20 {
                p.lastRefreshAt = now; p.refreshIndex = 0
            }
            busy = busy || p.pending || refreshing || (target != nil && target != port)
            guard now >= p.nextSendAt else { continue }

            // Configuration changes retire the old destination before any new
            // state is sent. Reports during this reset establish the new state.
            if let target, target != port {
                if p.switchIndex == nil { p.switchIndex = 0; p.edges.removeAll() }
                let index = p.switchIndex!
                guard send(Self.refreshMessage(slot, index, buttons: 0, axes: [0, 0, 0, 0]), port: port, now: now) else { continue }
                p.switchIndex = index + 1
                if p.switchIndex == 20 {
                    p.port = target; p.switchIndex = nil
                    p.sentButtons = 0; p.sentAxes = [0, 0, 0, 0]
                    p.edges = (0..<16).filter { p.wantButtons & (1 << $0) != 0 }.map { ($0, 1) }
                    p.refreshIndex = 0
                }
                p.nextSendAt = now + Self.sendInterval
                continue
            }
            if let edge = p.edges.first {
                guard send(Self.message(slot: slot, device: 1, index: 0, id: Int32(edge.id), state: edge.state), port: port, now: now) else { continue }
                p.edges.removeFirst()
                let mask = UInt16(1) << edge.id
                if edge.state == 0 { p.sentButtons &= ~mask } else { p.sentButtons |= mask }
            } else if let axis = (0..<4).first(where: { p.wantAxes[$0] != p.sentAxes[$0] }) {
                guard send(Self.message(slot: slot, device: 5, index: Int32(axis / 2), id: Int32(axis % 2), state: UInt16(bitPattern: p.wantAxes[axis])), port: port, now: now) else { continue }
                p.sentAxes[axis] = p.wantAxes[axis]
            } else if p.refreshIndex < 20 {
                guard send(Self.refreshMessage(slot, p.refreshIndex, buttons: p.wantButtons, axes: p.wantAxes), port: port, now: now) else { continue }
                p.refreshIndex += 1
                if p.refreshIndex == 20 && p.neutralPasses > 0 { p.neutralPasses -= 1 }
            } else { continue }
            p.nextSendAt = now + Self.sendInterval
        }
        if !busy { timer?.cancel(); timer = nil }
    }

    private static func refreshMessage(_ slot: Int, _ index: Int, buttons: UInt16, axes: [Int16]) -> [UInt8] {
        if index < 16 {
            return message(slot: slot, device: 1, index: 0, id: Int32(index), state: (buttons >> index) & 1)
        }
        let axis = index - 16
        return message(slot: slot, device: 5, index: Int32(axis / 2), id: Int32(axis % 2), state: UInt16(bitPattern: axes[axis]))
    }
    private static func message(slot: Int, device: Int32, index: Int32, id: Int32, state: UInt16) -> [UInt8] {
        var d = [UInt8](); d.reserveCapacity(20)
        for v in [Int32(slot), device, index, id] {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: state.littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: [0, 0]); return d
    }
    // sendto acceptance is NOT acknowledgement by RetroArch. Full refreshes
    // include released/zero values so a lost release can converge later.
    private func send(_ bytes: [UInt8], port: UInt16, now: TimeInterval) -> Bool {
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        dest.sin_addr.s_addr = UInt32(0x7F000001).bigEndian
        let sent = bytes.withUnsafeBytes { buf in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent == bytes.count { return true }
        if now - lastSendErrorAt >= 1 {
            lastSendErrorAt = now
            bridgeLog(.warning, "netpad", "sendto 127.0.0.1:\(port) failed, retrying: \(String(cString: strerror(errno)))")
        }
        return false
    }
}
