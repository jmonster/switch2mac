import SwiftUI

struct BrowserBridgeSettings: View {
    @AppStorage(WebSocketHub.enabledKey) private var enabled = false
    @AppStorage(WebSocketHub.extensionIDsKey) private var extensionIDs = ""

    var body: some View {
        Form {
            Toggle("Enable browser controller bridge", isOn: $enabled)
            TextField("Allowed extension IDs", text: $extensionIDs, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            Text("Copy the 32-letter ID from chrome://extensions after loading browser/extension. Separate multiple IDs with spaces. No websites or wildcards are accepted.")
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
}
