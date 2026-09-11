import SwiftUI

struct DiscoverySettings: View {
    @ObservedObject var engine: BridgeEngine
    @AppStorage(DiscoveryPolicy.enabledKey) private var quiet = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Controller Discovery").font(.title2)
            Text(engine.engineState.rawValue).font(.headline)
            Toggle("Pause discovery when my remembered controllers are connected", isOn: $quiet)
            Text("Optional: remember up to eight successfully connected physical controllers on this Mac. Once they are all ready, stop broad discovery. Losing one resumes scanning automatically; active controller input and keep-alives are unchanged.")
            Text("Adding an unfamiliar controller while discovery is paused requires Find New Controllers. Enabling this mode opens a 60-second setup window so a second Joy-Con can be added. Automatic discovery remains the default.")
            HStack {
                Button("Find New Controllers for 60 Seconds") { engine.requestDiscoveryWindow() }
                    .disabled(!quiet || engine.engineState == .paused)
                Button("Use Only Currently Connected Controllers") { engine.useConnectedForDiscovery() }
                    .disabled(!quiet || engine.controllers.isEmpty)
            }
            Text("The scan window may end while scanning continues for a missing remembered controller. Use the connected-only button to remove older controllers from this discovery set; it does not unpair or erase their mappings.").font(.caption)
            Text("This reduces requested scan time in the tested ready-set state, not a measured battery-life guarantee. Actual reconnect/radio behavior and power consumption require hardware qualification.").font(.caption)
            Button("Restore Automatic Discovery and Clear This Cache") {
                quiet = false
                UserDefaults.standard.removeObject(forKey: DiscoveryPolicy.rememberedKey)
            }
            Text("The cache contains local peripheral UUIDs, not Bluetooth addresses, and is excluded from support summaries. No identifiers are sent anywhere.").font(.caption)
        }.padding(20).frame(width: 620)
    }
}
