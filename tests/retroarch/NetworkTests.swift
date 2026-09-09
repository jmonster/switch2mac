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
var logged: [String] = [] // examined only with the sink queue quiescent
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
        precondition(withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return fd
    }
    static func packets(_ fd: Int32) -> [Data] {
        var result: [Data] = [], bytes = [UInt8](repeating: 0, count: 64)
        var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while poll(&ready, 1, 20) == 1 {
            let n = recv(fd, &bytes, bytes.count, 0)
            precondition(n == 20, "Expected exactly one 20-byte remote_message")
            result.append(Data(bytes.prefix(n)))
        }
        return result
    }
    static func tick(_ sink: NetworkGamepadSink, count: Int = 1) {
        sink.queue.sync {
            sink.timer?.cancel(); sink.timer = nil
            for _ in 0..<count {
                for p in sink.players { p.nextSendAt = 0 }
                sink.pump()
            }
        }
    }
    static func state(_ down: Bool) -> ControllerState {
        var s = ControllerState(); if down { s.buttons = [.a] }; return s
    }
    static func aValues(_ packets: [Data]) -> [UInt16] {
        packets.filter { Switch2.u32($0, 4) == 1 && Switch2.u32($0, 12) == 8 }.map { Switch2.u16($0, 16) }
    }
    static func main() {
        let selected = CommandLine.arguments.last!
        for name in ["wire", "tap", "refresh-release", "destination", "disable", "overflow", "send-failure", "finite-axis"] {
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
                tick(sink, count: 2)
                precondition(Array(aValues(packets(a)).prefix(2)) == [1,0], "Complete tap disappeared before the send timer")
            case "refresh-release":
                sink.controllerState(slot: 0, state: state(true)); tick(sink); _ = packets(a)
                sink.controllerState(slot: 0, state: state(false)); tick(sink); _ = packets(a) // simulate loss of release
                sink.queue.sync { sink.players[0].lastRefreshAt = -100 }
                tick(sink, count: 25)
                precondition(aValues(packets(a)).contains(0), "Periodic refresh omitted released buttons")
            case "destination":
                sink.controllerState(slot: 0, state: state(true)); tick(sink); _ = packets(a)
                AppConfig.networkGamepadBasePort = 55410
                tick(sink, count: 21)
                precondition(aValues(packets(a)).contains(0), "Old destination never received neutralization")
                precondition(aValues(packets(b)).first == 1, "New destination did not receive current state")
            case "disable":
                sink.controllerState(slot: 0, state: state(true)); tick(sink); _ = packets(a)
                AppConfig.networkGamepadEnabled = false; tick(sink, count: 20)
                precondition(aValues(packets(a)).contains(0))
            case "overflow":
                sink.queue.sync {
                    for i in 0..<600 { sink.controllerState(slot: 0, state: state(i % 2 == 0)) }
                }
                tick(sink, count: 20)
                precondition(sink.queue.sync { logged.contains { $0.contains("edge queue exhausted") } }, "Overflow silently lost input")
                precondition(aValues(packets(a)).allSatisfy { $0 == 0 })
                AppConfig.networkGamepadEnabled = false; tick(sink)
                AppConfig.networkGamepadEnabled = true
                sink.controllerState(slot: 0, state: state(true)); tick(sink)
                precondition(aValues(packets(a)).contains(1), "Explicit disable/re-enable did not recover")
            case "send-failure":
                sink.queue.sync { close(sink.fd); sink.fd = -1 }
                sink.controllerState(slot: 0, state: state(true)); tick(sink)
                precondition(sink.queue.sync { sink.players[0].sentButtons == 0 })
            case "finite-axis":
                precondition(NetworkGamepadSink.axis(.nan) == 0)
                precondition(NetworkGamepadSink.axis(.infinity) == 0)
            default: fatalError()
            }
            print("PASS \(name)")
        }
    }
}
