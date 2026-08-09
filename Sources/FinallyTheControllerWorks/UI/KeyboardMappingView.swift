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
    @State private var capturingButton: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bind controller buttons to keyboard keys — makes the "
                 + "controller work in apps with no controller support.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                Button("Clear") {
                    settings.clearKeyMap(forSerial: serial, app: scopeApp)
                }
            }

            let map = settings.keyMap(forSerial: serial, app: scopeApp)
            ForEach(Switch2.namedButtons, id: \.name) { entry in
                HStack {
                    Text(entry.name)
                        .frame(width: 130, alignment: .leading)
                        .foregroundStyle(map[entry.name] != nil ? Color.accentColor : .primary)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    KeyCaptureButton(
                        label: map[entry.name]?.label ?? "—",
                        capturing: capturingButton == entry.name,
                        onStart: { capturingButton = entry.name },
                        onCapture: { spec in
                            settings.setKeyMapping(button: entry.name, key: spec,
                                                   forSerial: serial, app: scopeApp)
                            capturingButton = nil
                        })
                    if map[entry.name] != nil {
                        Button {
                            settings.setKeyMapping(button: entry.name, key: nil,
                                                   forSerial: serial, app: scopeApp)
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
        }
        .padding(.top, 6)
        .onAppear {
            if let app = NSWorkspace.shared.frontmostApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                frontApp = (app.bundleIdentifier ?? "", app.localizedName ?? "app")
            }
        }
    }
}

/// A button that, when clicked, captures the next physical keystroke and
/// reports it as a KeySpec. Uses a local event monitor while capturing.
struct KeyCaptureButton: View {
    let label: String
    let capturing: Bool
    let onStart: () -> Void
    let onCapture: (KeySpec) -> Void

    @State private var monitor: Any?

    var body: some View {
        Button(capturing ? "Press a key…" : label) {
            if capturing { return }
            onStart()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let spec = KeySpec(
                    keyCode: event.keyCode,
                    modifiers: Self.cgFlags(from: event.modifierFlags),
                    label: Self.describe(event))
                onCapture(spec)
                if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
                return nil   // swallow the key
            }
        }
        .frame(width: 150)
        .foregroundStyle(capturing ? .orange : .primary)
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> UInt64 {
        var cg: CGEventFlags = []
        if flags.contains(.command) { cg.insert(.maskCommand) }
        if flags.contains(.option) { cg.insert(.maskAlternate) }
        if flags.contains(.control) { cg.insert(.maskControl) }
        if flags.contains(.shift) { cg.insert(.maskShift) }
        return cg.rawValue
    }

    private static func describe(_ event: NSEvent) -> String {
        var parts: [String] = []
        let f = event.modifierFlags
        if f.contains(.control) { parts.append("⌃") }
        if f.contains(.option) { parts.append("⌥") }
        if f.contains(.shift) { parts.append("⇧") }
        if f.contains(.command) { parts.append("⌘") }
        let key = event.charactersIgnoringModifiers?.uppercased()
        parts.append(specialKeyName(event.keyCode) ?? (key?.isEmpty == false ? key! : "key\(event.keyCode)"))
        return parts.joined()
    }

    private static func specialKeyName(_ code: UInt16) -> String? {
        switch code {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return nil
        }
    }
}
