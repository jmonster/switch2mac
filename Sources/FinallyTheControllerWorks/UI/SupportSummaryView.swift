import SwiftUI
import UniformTypeIdentifiers

struct SupportSummaryView: View {
    @ObservedObject var engine: BridgeEngine
    let outputs: [OutputHealth]
    let snapshotAt: Date?
    @Environment(\.dismiss) private var dismiss
    @State private var preview: Data?
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview Support Summary").font(.title2)
            Text("Only the text shown below will be saved. Raw log messages, controller identifiers, extension IDs, preferences, input, NFC and audio are excluded. Nothing is uploaded.")
            ScrollView {
                Text(preview.map { String(decoding: $0, as: UTF8.self) } ?? "Preparing summary…")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let failure { Text(failure).foregroundStyle(.secondary) }
            HStack {
                Button("Close") { dismiss() }.disabled(saving)
                Spacer()
                Button("Save Previewed JSON…", action: save).disabled(preview == nil || saving)
            }
        }.padding(20).frame(width: 620, height: 540)
        .task { prepare() }
    }

    @MainActor private func prepare() {
        // Freeze one snapshot before showing the save panel. No permission
        // checks, discovery, capture or file reads are triggered by this export.
        guard preview == nil else { return }
        let bundle = Bundle.main.infoDictionary ?? [:]
        let architecture: String
#if arch(arm64)
        architecture = "arm64"
#elseif arch(x86_64)
        architecture = "x86_64"
#else
        architecture = "unknown"
#endif
        let state: String
        switch engine.engineState {
        case .paused: state = "paused"
        case .off: state = "off"
        case .unauthorized: state = "unauthorized"
        case .scanning: state = "scanning"
        case .connecting: state = "connecting"
        case .idle: state = "idle"
        case .ready: state = "ready"
        }
        let events = LogStore.shared.entries.suffix(SupportSummary.maximumEvents).map {
            SupportSummary.Event(level: $0.level.rawValue, subsystem: $0.subsystem)
        }
        do {
            preview = try SupportSummary.make(revision: bundle["FTCWSourceRevision"] as? String,
                dirty: bundle["FTCWSourceDirty"] as? Bool, os: ProcessInfo.processInfo.operatingSystemVersion,
                architecture: architecture, engineState: state, models: engine.controllers.map(\.model),
                outputs: outputs, snapshotAge: snapshotAt.map { Date().timeIntervalSince($0) }, events: events)
        } catch { failure = "Could not prepare a bounded summary. Nothing was saved or uploaded." }
    }

    @MainActor private func save() {
        guard let data = preview, !saving else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "switch2mac-support.json"
        saving = true
        panel.begin { result in
            Task { @MainActor in
                guard result == .OK, let url = panel.url else { saving = false; return }
                do {
                    try await Task.detached(priority: .utility) { try SupportSummary.save(data, to: url) }.value
                    failure = nil
                } catch { failure = "Could not save the summary. Choose a writable, regular-file destination. Nothing was uploaded." }
                saving = false
            }
        }
    }
}
