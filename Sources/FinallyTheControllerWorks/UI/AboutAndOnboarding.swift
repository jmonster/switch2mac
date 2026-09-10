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
    @Environment(\.openWindow) private var openWindow
    @AppStorage("onboardingSeen") private var seen = false
    @State private var page = 0
    @State private var output: OutputSetupPath?

    private let pages: [(icon: String, title: String, body: String)] = [
        ("gamecontroller.fill", "Connect, then choose an output",
         "Use a Switch 2 Pro Controller, Joy-Con 2, or NSO GameCube controller with this development bridge. Bluetooth connection is the first step; your game also needs a supported output path."),
        ("dot.radiowaves.left.and.right", "Pair with this app",
         "Run only one controller bridge. Hold Sync next to USB-C until the player LEDs sweep, then look for the controller in the Dashboard. Allow Bluetooth access when macOS asks. For a previously bonded controller, try a button press first."),
        ("arrow.triangle.branch", "Choose your game output",
         "Choose the game or emulator you will use. These are separate integrations, not a system-wide driver. Selecting instructions here does not enable network access or change your settings."),
        ("checkmark.circle", "Verify both ends",
         "First check presses, releases, sticks, and triggers in the Dashboard. Then check them again in the actual game. Dashboard input alone does not prove game compatibility. Configure only the features you need."),
    ]

    var body: some View {
        VStack(spacing: 18) {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: pages[page].icon)
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text(pages[page].title).font(.title.bold())
                    Text(pages[page].body)
                        .foregroundStyle(.secondary)
                    if page == 2 {
                        Picker("Game type", selection: $output) {
                            Text("Choose an integration…").tag(OutputSetupPath?.none)
                            ForEach(OutputSetupPath.allCases) { path in
                                Text(path.title).tag(Optional(path))
                            }
                        }
                        if let output {
                            Text(output.detail).font(.callout)
                            HStack {
                                Link("Setup instructions", destination: output.guideURL)
                                if output == .browser {
                                    Button("Browser Bridge Settings…") { show("browser-bridge") }
                                }
                            }
                        }
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
            HStack {
                ForEach(0..<pages.count, id: \.self) { i in
                    Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(page + 1) of \(pages.count)")
            HStack {
                Button("Skip") { finish() }
                Spacer()
                if page > 0 {
                    Button("Back") { withAnimation { page -= 1 } }
                }
                Button(page == pages.count - 1 ? "Open Dashboard" : "Next") {
                    if page == pages.count - 1 { show("dashboard"); finish() }
                    else { withAnimation { page += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520, height: 500)
        .onAppear { NSApp.activate() }
        // Closing the window by ANY means counts as having seen the tour —
        // otherwise a red-button close would re-present it every launch.
        .onDisappear { seen = true }
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
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
