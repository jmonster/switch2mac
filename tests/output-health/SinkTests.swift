import Foundation
@main enum SinkTests {
    static func main() {
#if HEALTH_UDP
        let first = UDPHub()
        precondition(health(of: first).state == .listening)
        let blocked = UDPHub()
        let result = health(of: blocked)
        precondition(result.state == .unavailable && result.affectedSlots == [0, 1, 2, 3])
        withExtendedLifetime((first, blocked)) {}
#elseif HEALTH_NETPAD
        let sink = NetworkGamepadSink()
        AppConfig.networkGamepadEnabled = false
        precondition(health(of: sink).state == .disabled)
        AppConfig.networkGamepadEnabled = true
        AppConfig.networkGamepadBasePort = 0
        precondition(health(of: sink).state == .needsConfiguration)
        AppConfig.networkGamepadBasePort = 55400
        precondition(health(of: sink).state == .sendingUnconfirmed)
        withExtendedLifetime(sink) {}
#endif
        print("PASS production-sink health and failure diagnosis")
    }
}
