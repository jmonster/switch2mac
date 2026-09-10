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
    static func bindPort(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, datagram, 0)
        precondition(fd >= 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(result == 0, "Test requires free loopback ports")
        return fd
    }

    static func lifecycle() {
        for _ in 0..<20 {
            var hub: UDPHub? = UDPHub()
            weak var retired = hub
            let descriptors = hub!.queue.sync { hub!.slots.values.map(\.fd) }
            precondition(descriptors.count == 4)
            hub = nil
            // Dispatch source cancellation is asynchronous. Wait for the
            // actual production cancel handlers, not a replacement test hook.
            var closed = false
            for _ in 0..<200 {
                closed = retired == nil && descriptors.allSatisfy { fd in
                    fcntl(fd, F_GETFD, 0) == -1 && errno == EBADF
                }
                if closed { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            precondition(closed, "Retired hub leaked a socket or read source")
        }
        print("PASS 20 create/destroy cycles close all socket descriptors")
    }

    static func lateBind() {
        let first = bindPort(24800), second = bindPort(24801)
        let hub = UDPHub()
        hub.queue.sync { precondition(hub.slots[0] == nil && hub.slots[1] == nil) }
        hub.controllerName(slot: 0, name: "waiting controller")
        hub.controllerName(slot: 1, name: "retired controller")
        hub.controllerDisconnected(slot: 1)
        hub.queue.sync {}
        close(first); close(second)
        hub.queue.sync {
            // Exercise the production retry operation without sleeping 5 s.
            hub.openMissingSockets()
            precondition(hub.slots.count == 4)
            precondition(hub.slots[0]!.name == "waiting controller", "Retry lost the live controller name")
            precondition(hub.slots[1]!.name.isEmpty, "Retry resurrected retired controller metadata")
            for socket in hub.slots.values {
                precondition(fcntl(socket.fd, F_GETFL, 0) & O_NONBLOCK != 0)
                precondition(fcntl(socket.fd, F_GETFD, 0) & FD_CLOEXEC != 0)
            }
        }
        let fd = client(24800)
        defer { close(fd) }
        sendAndDrain(hub, slot: 0, fd: fd, bytes: [])
        precondition(receive(fd) == Data("S2N1waiting controller".utf8), "Late subscriber missed cached name")
        print("PASS late-bind name replay and disconnected metadata cleanup")
    }

    static func main() {
        let selected = CommandLine.arguments.last!
        // These own all four ports and run in their own process invocation.
        if selected == "lifecycle" { lifecycle(); return }
        if selected == "late-bind" { lateBind(); return }
        let hub = UDPHub()
        hub.queue.sync { precondition(hub.slots.count == 4) }
        if selected == "all" || selected == "exclusive" {
            let competitor = UDPHub()
            competitor.queue.sync {
                precondition(competitor.slots.isEmpty, "A second hub stole the first hub's ports")
            }
            print("PASS exclusive loopback port ownership")
        }
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
