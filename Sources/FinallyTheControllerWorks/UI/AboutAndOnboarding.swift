// AboutAndOnboarding.swift
// The About window (version + credit), first-run onboarding, and the
// settings import/export helpers.

import SwiftUI
import UniformTypeIdentifiers

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Finally the Controller Works")
                .font(.title2.bold())
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .foregroundStyle(.secondary)
            Text("Nintendo Switch 2 controllers on macOS —\nover Bluetooth, at last.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Divider().frame(width: 240)
            Text("© 2026 Peter Sharma")
                .font(.callout)
            Text("Switch 2 BLE protocol research thanks to the\nopen-source controller community.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 380)
    }
}

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboardingSeen") private var seen = false
    @State private var page = 0

    private let pages: [(icon: String, title: String, body: String)] = [
        ("gamecontroller.fill", "Welcome",
         "This app connects your Nintendo Switch 2 controllers to your Mac over Bluetooth — Pro Controller 2, Joy-Con 2, and the NSO GameCube pad."),
        ("dot.radiowaves.left.and.right", "Pairing a controller",
         "Hold the Sync button (next to the USB-C port) until the player LEDs sweep. The controller connects automatically and remembers your Mac — after that, just press any button to wake it."),
        ("slider.horizontal.3", "Make it yours",
         "Open the Dashboard to rename controllers, remap buttons, tune sticks and rumble, combine Joy-Cons into a grip, and more — each controller remembers its own settings."),
        ("sparkles", "Beyond gaming",
         "Use a Joy-Con as a mouse, feel the motion sensors, run party games, and find a lost controller. Explore the menus — there's a lot in here."),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: pages[page].icon)
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(pages[page].title).font(.title.bold())
            Text(pages[page].body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Spacer()
            HStack {
                ForEach(0..<pages.count, id: \.self) { i in
                    Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            HStack {
                Button("Skip") { finish() }
                Spacer()
                Button(page == pages.count - 1 ? "Get started" : "Next") {
                    if page == pages.count - 1 { finish() }
                    else { withAnimation { page += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460, height: 380)
    }

    private func finish() {
        seen = true
        dismiss()
    }
}

/// Whole-app settings backup: exports/imports the two UserDefaults blobs the
/// app relies on (per-controller settings + Joy-Con links).
enum SettingsTransfer {
    struct Bundle: Codable {
        var controllerSettings: Data
        var joyConLinks: [String: String]
        var version: Int = 1
    }

    static func export() -> Data? {
        let d = UserDefaults.standard
        let controller = (try? JSONSerialization.data(
            withJSONObject: d.dictionary(forKey: "controllerSettings") ?? [:])) ?? Data()
        let links = d.dictionary(forKey: "joyConLinks") as? [String: String] ?? [:]
        return try? JSONEncoder().encode(Bundle(controllerSettings: controller, joyConLinks: links))
    }

    static func `import`(_ data: Data) -> Bool {
        guard let bundle = try? JSONDecoder().decode(Bundle.self, from: data) else { return false }
        let d = UserDefaults.standard
        if let dict = try? JSONSerialization.jsonObject(with: bundle.controllerSettings)
            as? [String: [String: Any]] {
            d.set(dict, forKey: "controllerSettings")
        }
        d.set(bundle.joyConLinks, forKey: "joyConLinks")
        ControllerSettings.shared.reload()
        NotificationCenter.default.post(name: ControllerSettings.namesChangedNotification, object: nil)
        return true
    }
}
