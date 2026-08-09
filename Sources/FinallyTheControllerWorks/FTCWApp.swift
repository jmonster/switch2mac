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

        Window("Reaction Draft", id: "reaction-game") {
            ReactionGameView(game: appDelegate.game, engine: appDelegate.engine)
        }
        .defaultSize(width: 480, height: 460)

        Window("Sensor Challenges", id: "challenges") {
            ChallengeView(coordinator: appDelegate.challenges, engine: appDelegate.engine)
        }
        .defaultSize(width: 500, height: 480)

        Window("About", id: "about") { AboutView() }
            .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let engine = BridgeEngine()
    let game = ReactionGame()
    let challenges = ChallengeCoordinator()
    private let notifications = NotificationManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        bridgeLog(.info, "app", "Finally the Controller Works — starting bridge")
        engine.addSink(UDPHub())
        engine.addSink(VirtualHIDSink())
        notifications.attach(to: engine)

        // First-run onboarding.
        if !UserDefaults.standard.bool(forKey: "onboardingSeen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    private var onboardingWindow: NSWindow?

    func showOnboarding() {
        if let w = onboardingWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let hosting = NSHostingController(rootView: OnboardingView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        Button("Reaction Draft (party game)") {
            openWindow(id: "reaction-game")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Sensor Challenges") {
            openWindow(id: "challenges")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("About") {
            openWindow(id: "about")
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
