import Foundation
#if os(Linux)
import Glibc
let datagram = Int32(SOCK_DGRAM.rawValue)
#else
import Darwin
let datagram = SOCK_DGRAM
#endif

enum BridgeEngine { static let maxPlayers = 4 }
enum LogLevel { case info, warning, error, debug }
func bridgeLog(_ level: LogLevel, _ category: String, _ message: String) {}
protocol ControllerOutputSink: AnyObject {
    var onRumble: ((Int, Double, Double) -> Void)? { get set }
    func controllerConnected(slot: Int, model: Switch2.Model)
    func controllerDisconnected(slot: Int)
    func controllerName(slot: Int, name: String)
    func controllerState(slot: Int, state: ControllerState)
}

@main
enum UDPTests {
    static func client(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, datagram, 0)
        precondition(fd >= 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(result == 0)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        precondition(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
        return fd
    }
    static func sendBytes(_ fd: Int32, _ data: [UInt8]) {
        let n = data.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        precondition(n == data.count)
    }
    static func receive(_ fd: Int32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 128)
        let n = recv(fd, &bytes, bytes.count, 0)
        precondition(n >= 0, "Expected UDP packet was not delivered")
        return Data(bytes.prefix(n))
    }
    static func sendAndDrain(_ hub: UDPHub, slot: Int, fd: Int32, bytes: [UInt8]) {
        // Hold the hub's serial queue so its dispatch source cannot consume
        // the packet between poll() and the explicit production drain call.
        hub.queue.sync {
            sendBytes(fd, bytes)
            var ready = pollfd(fd: hub.slots[slot]!.fd, events: Int16(POLLIN), revents: 0)
            precondition(poll(&ready, 1, 1000) == 1, "Loopback packet did not arrive")
            hub.drainSocket(slot: slot)
        }
    }
    static func main() {
        let selected = CommandLine.arguments.last!
        let hub = UDPHub()
        hub.queue.sync { precondition(hub.slots.count == 4) }
        let a = client(24800), b = client(24801)
        defer { close(a); close(b) }
        sendBytes(a, []); sendBytes(b, [])
        for _ in 0..<100 {
            if hub.queue.sync(execute: { !hub.slots[0]!.peers.isEmpty && !hub.slots[1]!.peers.isEmpty }) { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        if selected == "all" || selected == "neutral" {
            var held = ControllerState(); held.buttons = [.a]; held.leftTrigger = 255
            hub.controllerState(slot: 0, state: held)
            precondition(Switch2.u32(receive(a), 8) == Switch2.Buttons.a.rawValue)
            hub.controllerDisconnected(slot: 0)
            let packet = receive(a)
            precondition(packet.count == 44 && packet.prefix(4) == Data("S2B1".utf8))
            precondition(packet.dropFirst(8).allSatisfy { $0 == 0 }, "Disconnect must emit neutral state")
            hub.controllerState(slot: 1, state: held)
            precondition(Switch2.u32(receive(b), 8) == Switch2.Buttons.a.rawValue)
            print("PASS orderly neutralization and unrelated slot")
        }
        if selected == "all" || selected == "malformed" {
            let c = client(24802); defer { close(c) }
            sendAndDrain(hub, slot: 2, fd: c, bytes: [1, 2, 3])
            hub.queue.sync {
                precondition(hub.slots[2]!.peers.isEmpty, "Malformed packets must not allocate subscribers")
            }
            print("PASS malformed subscription rejection")
        }
        if selected == "all" || selected == "capacity" {
            hub.queue.sync {
                let s = hub.slots[3]!
                for port in 1...64 {
                    s.peers[UDPHub.SockAddr(addr: 0x0100007f, port: UInt16(port))] = ProcessInfo.processInfo.systemUptime
                }
            }
            let c = client(24803); defer { close(c) }
            sendAndDrain(hub, slot: 3, fd: c, bytes: [])
            hub.queue.sync {
                precondition(hub.slots[3]!.peers.count == 64, "Peer table must stay bounded")
            }
            // Expired peers must not block a new subscriber even without state traffic.
            hub.queue.sync { hub.slots[3]!.peers = hub.slots[3]!.peers.mapValues { _ in -100 } }
            sendAndDrain(hub, slot: 3, fd: c, bytes: [])
            hub.queue.sync {
                precondition(hub.slots[3]!.peers.count == 1)
            }
            print("PASS peer cap and expiry without input")
        }

        if selected == "all" || selected == "backlog" {
            // Stall the sink queue and flood reports. Admission stays bounded;
            // once the consumer catches up it must neutralize before reasserting
            // the newest state rather than replaying stale transitions.
            let gate = DispatchSemaphore(value: 0)
            hub.queue.async { gate.wait() }
            for i in 0..<200 {
                var state = ControllerState()
                if i == 199 { state.buttons = [.a] }
                hub.controllerState(slot: 0, state: state)
            }
            gate.signal()
            let neutral = receive(a), latest = receive(a)
            precondition(Switch2.u32(neutral, 8) == 0)
            precondition(Switch2.u32(latest, 8) == Switch2.Buttons.a.rawValue)
            print("PASS bounded backlog recovery")
        }
        if selected == "all" || selected == "finite" {
            var weird = ControllerState()
            weird.leftStick = (.nan, 2)
            weird.rightStick = (-2, .infinity)
            let packet = UDPHub.statePacket(seq: 1, state: weird)
            func f32(_ offset: Int) -> Float {
                let bits = Switch2.u32(packet, offset)
                return Float(bitPattern: bits)
            }
            precondition(f32(12) == 0 && f32(16) == 1)
            precondition(f32(20) == -1 && f32(24) == 0)
            print("PASS finite clamped axes")
        }
    }
}
