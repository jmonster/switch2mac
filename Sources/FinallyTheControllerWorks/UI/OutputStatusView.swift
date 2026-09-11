import SwiftUI

/// No polling or per-report publication. A refresh asks each sink on its own
/// queue; a wedged queue times out rather than freezing the main actor.
@MainActor
final class OutputStatusStore: ObservableObject {
    static let shared = OutputStatusStore()
    @Published private(set) var reports: [OutputBackend: OutputHealth] = [:]
    @Published private(set) var pending = Set<OutputBackend>()
    @Published private(set) var updatedAt: Date?
    private var providers: [OutputBackend: any OutputHealthProviding] = [:]
    private var generation: UInt64 = 0
    private var timeout: Task<Void, Never>?

    func register<T: ControllerOutputSink & OutputHealthProviding>(_ sink: T) -> T {
        providers[sink.outputBackend] = sink
        return sink
    }
    func refresh() {
        guard pending.isEmpty else { return }
        generation &+= 1
        let token = generation
        reports.removeAll(); pending = Set(providers.keys); updatedAt = Date()
        for (backend, provider) in providers {
            provider.requestHealth { [weak self] report in
                Task { @MainActor in
                    guard let self, self.generation == token, self.pending.contains(backend) else { return }
                    self.reports[backend] = report
                    self.pending.remove(backend)
                    if self.pending.isEmpty { self.timeout?.cancel(); self.timeout = nil }
                }
            }
        }
        guard !pending.isEmpty else { return }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.generation == token else { return }
            // Missing reports stay visibly unknown, never reuse a stale success.
            self.pending.removeAll(); self.timeout = nil
        }
    }
}

struct OutputStatusView: View {
    @ObservedObject var engine: BridgeEngine
    @ObservedObject private var store = OutputStatusStore.shared
    @State private var backend = OutputBackend.sdl
    @State private var model = Switch2.Model.proController2
    @State private var showSupport = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Bluetooth connection is only the first step")
                    .font(.title2)
                Text("\(engine.controllers.count) controller(s) connected. Output snapshots below describe this bridge, not game acceptance.")
                HStack {
                    Button("Refresh Output Status") { store.refresh() }.disabled(!store.pending.isEmpty)
                    if let date = store.updatedAt {
                        Text("Snapshot: \(date.formatted(date: .omitted, time: .standard))").font(.caption)
                    }
                }
                ForEach(OutputBackend.allCases, id: \.self) { output in
                    GroupBox(output.title) {
                        VStack(alignment: .leading, spacing: 6) {
                            if let report = store.reports[output] {
                                Text(report.summary).font(.headline)
                                Text(report.guidance)
                                if !report.affectedSlots.isEmpty {
                                    Text("Affected player slots: " + report.affectedSlots.map { String($0 + 1) }.joined(separator: ", "))
                                }
                            } else {
                                Text(store.pending.contains(output) ? "Reading status…" : "Status not available. Refresh to retry.")
                            }
                            if output == .browser {
                                Button("Open Browser Bridge Settings") { openWindow(id: "browser-bridge") }
                            } else if output == .retroarch {
                                Button("Open Dashboard Configuration") {
                                    UserDefaults.standard.set(true, forKey: "showConfig")
                                    openWindow(id: "dashboard")
                                }
                            } else { Link("Setup and troubleshooting", destination: output.guideURL) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button("Preview Support Summary…") { showSupport = true }
                    .disabled(!store.pending.isEmpty)
                Divider()
                Text("What can this model and output do?").font(.headline)
                Picker("Output to inspect", selection: $backend) {
                    ForEach(OutputBackend.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Controller model to inspect", selection: $model) {
                    ForEach(Switch2.Model.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("These selectors inspect capabilities; they do not switch outputs or change your controller settings.").font(.caption)
                Text(OutputCapabilities(model: model, backend: backend).explanation)
                let controller = engine.controllers.first { $0.model == model && $0.player >= 0 }
                Button(controller.map { "Test P\($0.player + 1) rumble directly" } ?? "No matching assigned controller") {
                    if let controller { engine.testRumble(player: controller.player) }
                }
                .disabled(controller == nil || !OutputCapabilities(model: model, backend: backend).directRumble)
                Text("Direct tests bypass the selected game output. GameCube preset rumble is not verified; its HD-motor test is disabled here.").font(.caption)
                Link("Full model and hardware-acceptance limits", destination: URL(string: "https://github.com/jmonster/switch2mac/blob/main/docs/pro-controller-support.md")!)
            }.padding(20)
        }
        .frame(minWidth: 560, minHeight: 500)
        .onAppear { store.refresh() }
        .sheet(isPresented: $showSupport) {
            SupportSummaryView(engine: engine, outputs: Array(store.reports.values), snapshotAt: store.updatedAt)
        }
    }
}

struct OutputStatusShortcut: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack {
            Text("Bluetooth connection is not game readiness. Rumble pulses test the controller directly.").font(.caption)
            Spacer()
            Button("Output Status and Capabilities…") { openWindow(id: "output-status") }
        }.padding(10)
    }
}
