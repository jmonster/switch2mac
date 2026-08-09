// DashboardView.swift
// The main window: connection status, per-controller cards, and the live log.

import SwiftUI
import AppKit

struct DashboardView: View {
    @ObservedObject var engine: BridgeEngine

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if engine.controllers.isEmpty {
                emptyState
            } else {
                controllerList
            }
            Divider()
            LogView()
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: engine.controllers.isEmpty
                  ? "gamecontroller" : "gamecontroller.fill")
                .font(.title2)
            Text(engine.engineState.rawValue)
                .font(.headline)
            Spacer()
            Text("\(engine.controllers.count)/\(BridgeEngine.maxSlots) controllers")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No controllers connected")
                .font(.title3)
            Text("Press any button on a paired controller to wake it, or hold "
                 + "the Sync button (next to the USB-C port) until the player "
                 + "LEDs sweep to pair a new one.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding()
    }

    private var controllerList: some View {
        VStack(spacing: 8) {
            ForEach(engine.controllers) { controller in
                ControllerCard(status: controller) {
                    engine.testRumble(slot: controller.id)
                }
            }
            if engine.joyConPairAvailable || engine.joyConsCombined {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.grid.1x2")
                        .foregroundStyle(.secondary)
                    Toggle("Combine Joy-Cons into one gamepad (grip mode)",
                           isOn: Binding(
                               get: { engine.joyConsCombined },
                               set: { engine.setCombineJoyCons($0) }))
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
            }
        }
        .padding()
    }
}

struct ControllerCard: View {
    let status: ControllerStatus
    var onTestRumble: () -> Void = {}

    @ObservedObject private var settings = ControllerSettings.shared
    @State private var expanded = false
    @State private var editingName = false
    @State private var nameDraft = ""

    private func saveName() {
        settings.setCustomName(nameDraft, forSerial: status.serial)
        editingName = false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("P\(status.id + 1)")
                    .font(.system(.title2, design: .rounded).bold())
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.tint.opacity(0.15)))

                VStack(alignment: .leading, spacing: 2) {
                    if editingName {
                        HStack(spacing: 6) {
                            TextField(status.name, text: $nameDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 220)
                                .onSubmit { saveName() }
                            Button("Save") { saveName() }
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(settings.displayName(forSerial: status.serial,
                                                      modelName: status.name))
                                .font(.headline)
                                .foregroundStyle(nameColor)
                            Button {
                                nameDraft = settings.customName(forSerial: status.serial)
                                editingName = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Rename this controller")
                        }
                    }
                    Text(status.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Serial \(status.serial)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Label("\(status.batteryPercent)%", systemImage: batteryIcon)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Controller options")
            }
            .padding(10)

            if expanded {
                Divider().padding(.horizontal, 10)
                HStack(spacing: 12) {
                    Text("Rumble")
                    Slider(value: rumbleBinding, in: 0...1, step: 0.05)
                    Text("\(Int(settings.rumbleIntensity(forSerial: status.serial) * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Button("Test") { onTestRumble() }
                        .help("Play a short rumble pulse at this controller's strength")
                }
                .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    private var rumbleBinding: Binding<Double> {
        Binding(
            get: { settings.rumbleIntensity(forSerial: status.serial) },
            set: { settings.setRumbleIntensity($0, forSerial: status.serial) }
        )
    }

    /// Joy-Con accent colors: neon red for the right unit, neon blue for
    /// the left — matching the hardware.
    private var nameColor: Color {
        switch status.model {
        case .joyCon2Right: return Color(red: 1.00, green: 0.24, blue: 0.16)
        case .joyCon2Left: return Color(red: 0.04, green: 0.73, blue: 0.90)
        default: return .primary
        }
    }

    private var batteryIcon: String {
        switch status.batteryPercent {
        case 0..<15: return "battery.0percent"
        case 15..<40: return "battery.25percent"
        case 40..<65: return "battery.50percent"
        case 65..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct LogView: View {
    @ObservedObject private var store = LogStore.shared
    @State private var minLevel: LogLevel = .info
    @State private var autoScroll = true

    private var visibleEntries: [LogEntry] {
        store.entries.filter { $0.level.sortRank >= minLevel.sortRank }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log").font(.headline)
                Picker("", selection: $minLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                Toggle("Follow", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Export…") { exportLog() }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleEntries) { entry in
                            LogLine(entry: entry)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: store.entries.count) { _, _ in
                    if autoScroll, let last = visibleEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minHeight: 180)
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ftcw-diagnostics.log"
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: LogStore.shared.logFileURL, to: dest)
        }
    }
}

struct LogLine: View {
    let entry: LogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.timeFormatter.string(from: entry.date))
                .foregroundStyle(.secondary)
            Text(entry.level.rawValue)
                .foregroundStyle(levelColor)
                .frame(width: 44, alignment: .leading)
            Text(entry.message)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
        .id(entry.id)
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
