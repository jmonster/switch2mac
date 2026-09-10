// KeyboardMappingView.swift
// Per-controller keyboard mapping editor: bind any controller button to a
// keystroke, either globally or for the currently-frontmost app (a per-app
// profile that activates automatically when you switch to that app).

import SwiftUI
import AppKit

struct KeyboardMappingView: View {
    let serial: String
    @ObservedObject private var settings = ControllerSettings.shared

    /// nil = global ("All apps"); otherwise a bundle id.
    @State private var scopeApp: String? = nil
    @State private var frontApp: (id: String, name: String)?
    @StateObject private var capture = KeyCaptureSession()
    @State private var confirmClear = false
    /// Starts optimistic (banner hidden); the real preflight runs in
    /// onAppear/didBecomeActive — a TCC call in the @State initializer would
    /// re-run on every 10 Hz card re-render just to be discarded.
    @State private var hasEventPermission = true

    var body: some View {
        let map = settings.keyMap(forSerial: serial, app: scopeApp)
        VStack(alignment: .leading, spacing: 8) {
            Text("Bind controller buttons to keyboard keys — makes the "
                 + "controller work in apps with no controller support.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !hasEventPermission {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("Keyboard mapping needs Accessibility permission — "
                          + "until it's granted, mapped buttons act as normal "
                          + "gamepad buttons.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") {
                        AppInfo.openPrivacySettings(anchor: "Privacy_Accessibility")
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Text("Applies to:")
                Picker("", selection: Binding(
                    get: { scopeApp ?? "" },
                    set: { scopeApp = $0.isEmpty ? nil : $0 })) {
                    Text("All apps").tag("")
                    if let front = frontApp {
                        Text("Only \(front.name)").tag(front.id)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                Spacer()
                Button("Remove All…") { confirmClear = true }
                    .disabled(map.isEmpty)
                    .confirmationDialog(
                        "Remove all \(map.count) bindings for \(scopeName)?",
                        isPresented: $confirmClear, titleVisibility: .visible
                    ) {
                        Button("Remove All", role: .destructive) {
                            settings.clearKeyMap(forSerial: serial, app: scopeApp)
                        }
                    } message: {
                        Text("Captured bindings can't be restored — you'd have to re-record them.")
                    }
            }

            ForEach(Switch2.namedButtons, id: \.name) { entry in
                HStack {
                    Text(entry.name)
                        .frame(width: 130, alignment: .leading)
                        .foregroundStyle(map[entry.name] != nil ? Color.accentColor : .primary)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    KeyCaptureButton(
                        label: map[entry.name]?.label ?? "—",
                        capturing: capture.capturingID == entry.name,
                        onTap: {
                            if capture.capturingID == entry.name {
                                capture.cancel()   // second click backs out
                            } else {
                                capture.begin(id: entry.name) { spec in
                                    settings.setKeyMapping(button: entry.name, key: spec,
                                                           forSerial: serial, app: scopeApp)
                                }
                            }
                        })
                    if map[entry.name] != nil {
                        Button {
                            settings.setKeyMapping(button: entry.name, key: nil,
                                                   forSerial: serial, app: scopeApp)
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                        .accessibilityLabel("Remove mapping for \(entry.name)")
                    }
                    Spacer()
                }
            }
        }
        .padding(.top, 6)
        .onAppear {
            hasEventPermission = CGPreflightPostEventAccess()
            if let app = NSWorkspace.shared.frontmostApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                frontApp = (app.bundleIdentifier ?? "", app.localizedName ?? "app")
            }
        }
        // Re-check when the user comes back from System Settings.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            hasEventPermission = CGPreflightPostEventAccess()
        }
        .onDisappear { capture.cancel() }
    }

    private var scopeName: String {
        guard scopeApp != nil else { return "All apps" }
        return frontApp.map { "Only \($0.name)" } ?? "this app"
    }
}

/// The visible face of a key binding: shows the bound key (or "—"), and the
/// capturing state while its KeyCaptureSession is armed. The monitor itself
/// lives in the session, owned by the enclosing view — not here.
struct KeyCaptureButton: View {
    let label: String
    let capturing: Bool
    let onTap: () -> Void

    var body: some View {
        Button(capturing ? "Press a key… (Esc cancels)" : label) { onTap() }
            .frame(width: 150)
            .foregroundStyle(capturing ? .orange : .primary)
    }

}
