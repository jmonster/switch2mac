import Foundation

enum LogLevel { case info, warning, error, debug }
func bridgeLog(_ level: LogLevel, _ category: String, _ message: String) {
    if message.contains("opt-in browser bridge") {
        FileHandle.standardOutput.write(Data("READY\n".utf8))
    }
}
protocol ControllerOutputSink: AnyObject {
    var onRumble: ((Int, Double, Double) -> Void)? { get set }
    func controllerConnected(slot: Int, model: Switch2.Model)
    func controllerDisconnected(slot: Int)
    func controllerName(slot: Int, name: String)
    func controllerState(slot: Int, state: ControllerState)
}
@main
enum BrowserServer {
    static func main() {
        precondition(WebSocketHub.origins(from: "bad https://example.com *").isEmpty)
        let ids = String(repeating: "a", count: 32)
        let origins = WebSocketHub.origins(from: ids)
        precondition(origins == ["chrome-extension://" + ids])
        let server = WebSocketHub(enabled: true, allowedOrigins: origins)
        server.onRumble = { slot, strong, weak in
            FileHandle.standardOutput.write(Data("RUMBLE \(slot) \(strong) \(weak)\n".utf8))
        }
        server.controllerConnected(slot: 0, model: .proController2)
        server.controllerName(slot: 0, name: "test pad")
        var state = ControllerState(); state.buttons = [.a]; state.leftStick = (0.5, 0)
        server.controllerState(slot: 0, state: state)
        while let command = readLine(), command != "quit" {}
        withExtendedLifetime(server) {}
    }
}
