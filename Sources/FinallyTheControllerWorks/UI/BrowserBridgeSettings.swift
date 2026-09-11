import SwiftUI

struct BrowserBridgeSettings: View {
    @State private var enabled = false
    @State private var extensionIDs = ""
    @State private var saved = false
    @State private var validationError: String?

    @State private var resourceError: String?

    var body: some View {
        Form {
            Text("Move this app to Applications before loading the extension, so its installed path stays stable.")
                .font(.caption)
            Button("Show Bundled Browser Extension…") { showExtension() }
            if let resourceError { Text(resourceError).foregroundStyle(.red).font(.caption) }
            Toggle("Enable browser controller bridge", isOn: $enabled)
            TextField("Allowed extension IDs", text: $extensionIDs, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            Text("Copy the 32-letter ID from chrome://extensions after using Load unpacked on the bundled extension folder. Separate multiple IDs with spaces. No websites or wildcards are accepted.")
                .font(.caption)
            Button("Apply Changes") {
                do {
                    try BrowserBridgeConfiguration(enabled: enabled, extensionIDs: extensionIDs).save()
                    validationError = nil; saved = true
                } catch { validationError = error.localizedDescription; saved = false }
            }
            if let validationError { Text(validationError).foregroundStyle(.red).font(.caption) }
            if saved { Text("Settings saved. Connections are restarted automatically; verify the extension reconnects.").font(.caption) }
            Text("Applying changes closes existing browser clients and stops their rumble. No app relaunch or controller re-pairing is needed.")
                .font(.caption)
            Text("Disabled by default. The listener is local-only and rejects other browser origins. Programs already running on this Mac can impersonate an origin; this is not native-client authentication.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            let config = BrowserBridgeConfiguration.load()
            enabled = config.enabled; extensionIDs = config.extensionIDs
        }
        .onChange(of: enabled) { _, _ in saved = false }
        .onChange(of: extensionIDs) { _, _ in saved = false }
    }
    private func showExtension() {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension"),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else {
            resourceError = "This build has no bundled extension. Rebuild with scripts/build-app.sh."
            return
        }
        resourceError = nil
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }
}
