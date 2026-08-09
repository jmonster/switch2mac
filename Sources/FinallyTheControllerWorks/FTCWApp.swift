// FTCWApp.swift
// "Finally the Controller Works" — app entry point.
//
// Menu-bar resident: launching the app starts the bridge; closing the
// dashboard window leaves it running; quitting from the menu stops
// everything (controllers drop within seconds once keep-alives cease).

import SwiftUI
import ServiceManagement

@main
struct FTCWApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(engine: appDelegate.engine)
        } label: {
            Image(systemName: appDelegate.engine.controllers.isEmpty
                  ? "gamecontroller" : "gamecontroller.fill")
        }

        Window("Finally the Controller Works", id: "dashboard") {
            DashboardView(engine: appDelegate.engine)
                .frame(minWidth: 560, minHeight: 480)
        }
        .defaultSize(width: 680, height: 620)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let engine = BridgeEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        bridgeLog(.info, "app", "Finally the Controller Works — starting bridge")
        engine.addSink(UDPHub())
        engine.addSink(VirtualHIDSink())
    }
}

struct MenuContent: View {
    @ObservedObject var engine: BridgeEngine
    @ObservedObject private var settings = ControllerSettings.shared
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Text(engine.engineState.rawValue)

        if engine.controllers.isEmpty {
            Text("Press any button on a paired controller,")
            Text("or hold Sync (next to USB-C) to pair a new one.")
        } else {
            ForEach(engine.controllers) { c in
                Text("\(c.player >= 0 ? "P\(c.player + 1)" : "—")  \(settings.displayName(forSerial: c.serial, modelName: c.name)) — \(c.batteryPercent)%")
            }
        }

        Divider()

        Button("Open Dashboard") {
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }

        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, enable in
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    bridgeLog(.error, "app", "launch-at-login change failed: \(error.localizedDescription)")
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }

        Divider()

        Button("Quit") {
            bridgeLog(.info, "app", "quitting — controllers will disconnect")
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
