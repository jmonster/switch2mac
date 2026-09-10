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

    static var sourceRevision: String {
        let revision = Bundle.main.infoDictionary?["FTCWSourceRevision"] as? String ?? "unrecorded"
        let dirty = Bundle.main.infoDictionary?["FTCWSourceDirty"] as? Bool ?? false
        return String(revision.prefix(12)) + (dirty ? " (modified)" : "")
    }

    /// This fork has no approved update signing identity/feed. Never consume
    /// the upstream feed or a persisted override until that trust path exists.
    static let updatesEnabled = false
    static let defaultUpdateFeedURL = ""

    /// Pre-release features hidden from the beta UI: the party-game and
    /// gesture menu items, keyboard mapping, and the Experiments cluster.
    /// Deliberately a runtime flag rather than a build flag so a beta build
    /// can be un-hidden for development without recompiling:
    ///   defaults write io.github.jmonster.switch2mac showPreReleaseFeatures -bool YES
    /// (then relaunch; delete the key to hide again).
    static var showPreReleaseFeatures: Bool {
        UserDefaults.standard.bool(forKey: "showPreReleaseFeatures")
    }

    /// Deep links into System Settings panes.
    static func openBluetoothSettings() {
        open(settingsURL: "x-apple.systempreferences:com.apple.BluetoothSettings")
    }
    static func openPrivacySettings(anchor: String) {
        open(settingsURL: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
    private static func open(settingsURL: String) {
        guard let url = URL(string: settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Buy Me a Coffee page. Opened in Safari so supporters get the web
    /// Apple Pay option (Apple Pay on the web is Safari-only).
    static let buyMeACoffeeURL = "https://buymeacoffee.com/peterksharma"

    static func openBuyMeACoffee() {
        guard let url = URL(string: buyMeACoffeeURL) else { return }
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: cfg) { _, err in
            if err != nil { NSWorkspace.shared.open(url) }   // fallback: default browser
        }
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
            Text("Source: \(AppInfo.sourceRevision)")
                .font(.caption.monospaced()).textSelection(.enabled)
            Text("Nintendo Switch 2 controllers on macOS —\nover Bluetooth, at last.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                AppInfo.openBuyMeACoffee()
            } label: {
                Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .help("Opens in Safari — supports Apple Pay")

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
        .onAppear { NSApp.activate() }
        // Closing the window by ANY means counts as having seen the tour —
        // otherwise a red-button close would re-present it every launch.
        .onDisappear { seen = true }
    }

    private func finish() {
        seen = true
        dismiss()
    }
}

/// Whole-app settings backup. Validation and rollback live outside the UI so
/// imported data cannot partially mutate live preferences.
@MainActor
enum SettingsTransfer {
    typealias Bundle = SettingsArchive.Payload

    static func export() -> Data? {
        let d = UserDefaults.standard
        let settings = d.dictionary(forKey: "controllerSettings") as? [String: [String: Any]] ?? [:]
        let links = d.dictionary(forKey: "joyConLinks") as? [String: String] ?? [:]
        return SettingsArchive.encode(settings: settings, links: links)
    }

    static func `import`(_ data: Data) -> Bool {
        guard let validated = SettingsArchive.decode(data),
              SettingsArchive.apply(validated) else { return false }
        ControllerSettings.shared.reload()
        NotificationCenter.default.post(name: ControllerSettings.namesChangedNotification, object: nil)
        return true
    }
}
