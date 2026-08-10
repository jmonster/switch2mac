// GesturesView.swift
// Manage air-gesture macros: pick the trigger button, record new gestures,
// bind each to a keystroke or built-in action, and delete them.

import SwiftUI
import AppKit

struct GesturesView: View {
    @ObservedObject var engine: BridgeEngine

    @State private var gestures: [AirGesture] = []
    @AppStorage("gestureTriggerButton") private var trigger = "GL"
    @State private var recording = false
    @State private var newName = ""
    @StateObject private var capture = KeyCaptureSession()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Air Gestures").font(.largeTitle.bold())
            Text("Hold the trigger button, draw a shape in the air, and release. "
                 + "Matched gestures run their action.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if engine.controllers.isEmpty {
                Label("No controllers connected — press any button on a paired "
                      + "controller to wake one.",
                      systemImage: "gamecontroller")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Trigger button")
                Picker("", selection: $trigger) {
                    ForEach(Switch2.namedButtons, id: \.name) { Text($0.name).tag($0.name) }
                }.labelsHidden().frame(width: 180)
            }

            Divider()

            // Record a new gesture.
            HStack {
                TextField("New gesture name", text: $newName).frame(width: 180)
                if recording {
                    Button("Cancel") { cancelRecording() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Record") { startRecording() }
                        .disabled(newName.isEmpty || engine.controllers.isEmpty)
                }
            }
            if recording {
                Text("Hold \(trigger), draw the shape in the air, then release.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // Existing gestures.
            if gestures.isEmpty {
                Text("No gestures yet — record one above.").foregroundStyle(.secondary)
            } else {
                ForEach(gestures) { g in
                    GestureRow(gesture: g,
                               capturing: capture.capturingID == g.id.uuidString,
                               onCaptureTap: { toggleCapture(for: g) },
                               onAction: { updateAction(g.id, $0) },
                               onDelete: { delete(g.id) })
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 460)
        .onAppear { gestures = load() }
        .onDisappear {
            // Leave nothing armed: an orphaned recording would silently turn
            // the next trigger-hold into a saved gesture.
            cancelRecording()
            capture.cancel()
        }
    }

    private func startRecording() {
        recording = true
        engine.gestureRecognizer.onRecorded = { g in
            DispatchQueue.main.async {
                var named = g; named.name = newName
                gestures.append(named)
                GestureRecognizer.save(gestures)
                engine.gestureRecognizer.reload()
                newName = ""
                recording = false
            }
        }
        engine.gestureRecognizer.recordingName = newName
    }

    private func cancelRecording() {
        engine.gestureRecognizer.recordingName = nil
        engine.gestureRecognizer.onRecorded = nil
        recording = false
    }

    private func toggleCapture(for gesture: AirGesture) {
        let id = gesture.id.uuidString
        if capture.capturingID == id {
            capture.cancel()
        } else {
            capture.begin(id: id) { spec in
                updateAction(gesture.id) { $0.key = spec; $0.builtin = nil }
            }
        }
    }

    private func updateAction(_ id: UUID, _ update: (inout AirGesture) -> Void) {
        guard let idx = gestures.firstIndex(where: { $0.id == id }) else { return }
        update(&gestures[idx])
        GestureRecognizer.save(gestures)
        engine.gestureRecognizer.reload()
    }

    private func delete(_ id: UUID) {
        gestures.removeAll { $0.id == id }
        GestureRecognizer.save(gestures)
        engine.gestureRecognizer.reload()
    }

    private func load() -> [AirGesture] {
        guard let data = UserDefaults.standard.data(forKey: "airGestures"),
              let list = try? JSONDecoder().decode([AirGesture].self, from: data)
        else { return [] }
        return list
    }
}

private struct GestureRow: View {
    let gesture: AirGesture
    let capturing: Bool
    let onCaptureTap: () -> Void
    let onAction: (@escaping (inout AirGesture) -> Void) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "scribble.variable")
            Text(gesture.name).frame(width: 120, alignment: .leading)
            Text("→").foregroundStyle(.tertiary)
            Picker("", selection: Binding(
                get: { gesture.builtin ?? "keystroke" },
                set: { sel in
                    onAction { g in
                        if sel == "keystroke" { g.builtin = nil }
                        else { g.builtin = sel; g.key = nil }
                    }
                })) {
                Text("Keystroke…").tag("keystroke")
                ForEach(GestureAction.builtins, id: \.id) { Text($0.label).tag($0.id) }
            }
            .labelsHidden().frame(width: 170)

            if gesture.builtin == nil {
                KeyCaptureButton(
                    label: gesture.key?.label ?? "Set key",
                    capturing: capturing,
                    onTap: onCaptureTap)
            }
            Spacer()
            Button { onDelete() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Delete \(gesture.name)")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}
