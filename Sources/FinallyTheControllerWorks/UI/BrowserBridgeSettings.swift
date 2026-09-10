import SwiftUI

struct BrowserBridgeSettings: View {
    @AppStorage(WebSocketHub.enabledKey) private var enabled = false
    @AppStorage(WebSocketHub.extensionIDsKey) private var extensionIDs = ""

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
            Text("\(WebSocketHub.origins(from: extensionIDs).count) valid extension ID(s). Quit and relaunch this app after changing these settings.")
                .font(.caption)
            Text("Disabled by default. The listener is local-only and rejects other browser origins. Programs already running on this Mac can impersonate an origin; this is not native-client authentication.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460)
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
