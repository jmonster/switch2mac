import AppKit
import SwiftUI
import Switch2Kit

@main
struct Switch2KitDemoApp: App {
    @StateObject private var manager = Switch2ControllerManager()
    var body: some Scene {
        WindowGroup("Switch2Kit — In-process Controller Demo") {
            DemoView(manager: manager)
                .frame(minWidth: 680, minHeight: 440)
                .onAppear { manager.start() }
        }
    }
}

private struct DemoView: View {
    @ObservedObject var manager: Switch2ControllerManager
    @State private var errorMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Switch2Kit").font(.largeTitle)
            Text("Bluetooth: \(manager.bluetoothState.rawValue)")
            Text("Discovery: \(String(describing: manager.discoveryState))")
            HStack {
                Button("Find Controllers for 60 Seconds") {
                    manager.start()
                    do { try manager.discover(for: 60) } catch { errorMessage = String(describing: error) }
                }
                Button("Stop Support") { Task { await manager.stop() } }
            }
            Text("Hold Sync for first connection. This demo controls its own UI; it does not post global keys or create virtual gamepads.")
                .font(.callout)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            List(manager.controllers) { controller in
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.name).font(.headline)
                    Text("Buttons: 0x\(String(controller.state.buttons.rawValue, radix: 16))")
                    Text("Left: \(stick(controller.state.leftStick))   Right: \(stick(controller.state.rightStick))")
                    Text("L: \(trigger(controller.state.leftTrigger))   R: \(trigger(controller.state.rightTrigger))")
                    Text("Battery: \(controller.state.battery.millivolts.map { String($0) + " mV" } ?? "unavailable")")
                    HStack {
                        Button("Short Rumble") {
                            do { try manager.pulseRumble(for: controller.id, strong: 0.4, weak: 0.4, duration: 0.15) }
                            catch { errorMessage = String(describing: error) }
                        }.disabled(!controller.capabilities.contains(.rumble))
                        Button("Disconnect") { manager.disconnect(controller.id) }
                    }
                }.padding(.vertical, 6)
            }
        }.padding(20)
    }
    private func stick(_ value: Switch2Stick?) -> String {
        value.map { String(format: "(%+.2f, %+.2f)", $0.x, $0.y) } ?? "not present"
    }
    private func trigger(_ value: Switch2Trigger) -> String {
        (value.travel.map { String(format: "%.2f travel, ", $0) } ?? "") + (value.isPressed ? "pressed" : "released")
    }
}
