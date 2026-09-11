import Foundation
#if os(Linux)
import Glibc
let datagram = Int32(SOCK_DGRAM.rawValue)
#else
import Darwin
let datagram = SOCK_DGRAM
#endif

enum BridgeEngine { static let maxPlayers = 4 }
enum AppConfig {
    static var networkGamepadEnabled = true
    static var networkGamepadBasePort = 55400
}
enum LogLevel { case info, warning, error, debug }
var logged: [String] = []
func bridgeLog(_ level: LogLevel, _ category: String, _ message: String) { logged.append(message) }
protocol ControllerOutputSink: AnyObject {
    var onRumble: ((Int, Double, Double) -> Void)? { get set }
    func controllerConnected(slot: Int, model: Switch2.Model)
    func controllerDisconnected(slot: Int)
    func controllerName(slot: Int, name: String)
    func controllerState(slot: Int, state: ControllerState)
}

@main
enum NetworkTests {
    static func receiver(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, datagram, 0); precondition(fd >= 0)
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian; addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        precondition(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK); return fd
    }
    static func packets(_ fd: Int32) -> [Data] {
        var result: [Data] = [], bytes = [UInt8](repeating: 0, count: 64)
        var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while poll(&ready, 1, 20) == 1 {
            let n = recv(fd, &bytes, bytes.count, 0); precondition(n == 20)
            result.append(Data(bytes.prefix(n)))
        }
        return result
    }
    static func tick(_ sink: NetworkGamepadSink, count: Int = 1) {
        sink.queue.sync {
            sink.timer?.cancel(); sink.timer = nil; sink.nextPumpAt = nil
            for _ in 0..<count {
                for p in sink.players { p.nextSendAt = 0 }
                sink.pump()
                // The production pump now rearms a one-shot timer. Manual-time
                // tests must cancel it after each tick, not allow wall time to
                // finish the destination transition while collecting packets.
                sink.timer?.cancel(); sink.timer = nil; sink.nextPumpAt = nil
            }
        }
    }
    static func state(_ down: Bool) -> ControllerState { var s = ControllerState(); if down { s.buttons = [.a] }; return s }
    static func aValues(_ packets: [Data]) -> [UInt16] { packets.filter { Switch2.u32($0, 4) == 1 && Switch2.u32($0, 12) == 8 }.map { Switch2.u16($0, 16) } }
    static func main() {
        let selected = CommandLine.arguments.last!
        for name in ["wire", "tap", "refresh-release", "destination", "disable", "overflow", "mailbox-overload", "send-failure", "finite-axis", "axis-endpoints", "cancel-destination", "deadlines", "settings-wake", "paced-failure"] {
            if selected != "all" && selected != name { continue }
            AppConfig.networkGamepadEnabled = true; AppConfig.networkGamepadBasePort = 55400
            let a = receiver(55400), b = receiver(55410), sink = NetworkGamepadSink()
            defer { sink.queue.sync { sink.timer?.cancel(); sink.timer = nil }; close(a); close(b) }
            sink.queue.sync { logged.removeAll() }
            sink.controllerConnected(slot: 0, model: .nsoGameCube)
            switch name {
            case "wire":
                let m = NetworkGamepadSink.message(slot: 0, device: 1, index: 0, id: 8, state: 1)
                precondition(m == [0,0,0,0,1,0,0,0,0,0,0,0,8,0,0,0,1,0,0,0])
            case "tap":
                sink.queue.sync { sink.controllerState(slot: 0, state: state(true)); sink.controllerState(slot: 0, state: state(false)) }
                tick(sink, count: 2); precondition(Array(aValues(packets(a)).prefix(2)) == [1,0])
            case "refresh-release":
                sink.controllerState(slot: 0, state: state(true)); tick(sink); _ = packets(a)
                sink.controllerState(slot: 0, state: state(false)); tick(sink); _ = packets(a)
                sink.queue.sync { sink.players[0].lastRefreshAt = -100 }; tick(sink, count: 25)
                precondition(aValues(packets(a)).contains(0))
            case "destination":
                sink.controllerState(slot: 0, state: state(true)); tick(sink); _ = packets(a)
                AppConfig.networkGamepadBasePort = 55410; tick(sink, count: 21)
                precondition(aValues(packets(a)).contains(0)); precondition(aValues(packets(b)).first == 1)
            case "disable":
                sink.controllerState(slot: 0, state: state(true)); tick(sink); _ = packets(a)
                AppConfig.networkGamepadEnabled = false; tick(sink, count: 20); precondition(aValues(packets(a)).contains(0))
            case "overflow":
                sink.queue.sync { for i in 0..<600 { sink.acceptState(slot: 0, state: state(i % 2 == 0)) } }
                tick(sink, count: 20)
                precondition(sink.queue.sync { logged.contains { $0.contains("edge queue exhausted") } })
                precondition(aValues(packets(a)).allSatisfy { $0 == 0 })
                AppConfig.networkGamepadEnabled = false; tick(sink); AppConfig.networkGamepadEnabled = true
                sink.controllerState(slot: 0, state: state(true)); tick(sink); precondition(aValues(packets(a)).contains(1))
            case "mailbox-overload":
                let gate = DispatchSemaphore(value: 0); sink.queue.async { gate.wait() }
                for i in 0..<200 { sink.controllerState(slot: 0, state: state(i % 2 == 0)) }
                gate.signal(); sink.queue.sync {}; tick(sink, count: 25)
                precondition(sink.queue.sync { logged.contains { $0.contains("input backlog exceeded") } })
                precondition(aValues(packets(a)).allSatisfy { $0 == 0 })
            case "send-failure":
                sink.queue.sync { close(sink.fd); sink.fd = -1 }
                sink.controllerState(slot: 0, state: state(true)); tick(sink)
                precondition(sink.queue.sync { sink.players[0].sentButtons == 0 })
            case "cancel-destination":
                sink.controllerState(slot: 0, state: state(true)); tick(sink); _ = packets(a)
                AppConfig.networkGamepadBasePort = 55410; tick(sink, count: 10); precondition(aValues(packets(a)).contains(0))
                AppConfig.networkGamepadBasePort = 55400; tick(sink, count: 40); precondition(aValues(packets(a)).contains(1))
                sink.queue.sync { sink.controllerState(slot: 0, state: state(false)); sink.controllerState(slot: 0, state: state(true)); sink.controllerState(slot: 0, state: state(false)) }
                tick(sink, count: 3); precondition(Array(aValues(packets(a)).prefix(3)) == [0,1,0]); precondition(packets(b).isEmpty)
            case "deadlines":
                sink.queue.sync {
                    let p = sink.players[0]
                    sink.wasEnabled = true; p.port = 55400
                    p.refreshIndex = 20; p.lastRefreshAt = 100; p.nextSendAt = 0
                    p.edges = []; p.wantButtons = 0; p.sentButtons = 0
                    precondition(sink.nextPumpDeadline(now: 100.5) == 102,
                                 "Quiescent output should sleep until refresh, not poll at 60 Hz")
                    p.edges = [(8, 1)]; p.nextSendAt = 101
                    precondition(sink.nextPumpDeadline(now: 100.5) == 101)
                    p.edges = []; p.connected = false; p.neutralPasses = 0
                    precondition(sink.nextPumpDeadline(now: 100.5) == nil)
                    p.neutralPasses = 1
                    precondition(sink.nextPumpDeadline(now: 100.5) == 102)
                    p.neutralPasses = 0; AppConfig.networkGamepadEnabled = false
                    precondition(sink.nextPumpDeadline(now: 100.5) == 100.5,
                                 "Configuration transitions must wake immediately")
                }
            case "settings-wake":
                sink.controllerState(slot: 0, state: state(true)); tick(sink, count: 25); _ = packets(a)
                sink.queue.sync {
                    sink.timer?.cancel(); sink.timer = nil; sink.nextPumpAt = nil
                    AppConfig.networkGamepadEnabled = false
                }
                NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
                sink.queue.sync {
                    precondition(sink.nextPumpAt != nil || !sink.wasEnabled,
                                 "Preferences must wake output without a controller report")
                }
                tick(sink, count: 20)
                precondition(aValues(packets(a)).contains(0))
            case "paced-failure":
                sink.queue.sync {
                    let p = sink.players[0]
                    p.port = 0 // sendto rejects destination port zero on loopback
                    p.edges = [(8, 1)]; p.nextSendAt = 0
                    sink.wasEnabled = true
                    let before = ProcessInfo.processInfo.systemUptime
                    sink.pump()
                    precondition(p.nextSendAt >= before + NetworkGamepadSink.sendInterval)
                    precondition((sink.nextPumpDeadline(now: before) ?? 0) > before,
                                 "A failed send must not create a zero-delay retry loop")
                }
            case "finite-axis": precondition(NetworkGamepadSink.axis(.nan) == 0); precondition(NetworkGamepadSink.axis(.infinity) == 0)
            case "axis-endpoints":
                precondition(NetworkGamepadSink.axis(1) == 32767); precondition(NetworkGamepadSink.axis(-1) == -32767)
                precondition(NetworkGamepadSink.axis(2) == 32767); precondition(NetworkGamepadSink.axis(-2) == -32767)
            default: fatalError()
            }
            print("PASS \(name)")
        }
    }
}
