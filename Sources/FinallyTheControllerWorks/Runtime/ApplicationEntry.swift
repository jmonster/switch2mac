import Foundation
import SwiftUI

/// The runtime probe exits before constructing the SwiftUI app, its delegate,
/// Bluetooth engine, settings recovery, output listeners or permission prompts.
@main enum ApplicationEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--sensor-profile") {
            guard CommandLine.arguments.count == 2 else {
                FileHandle.standardError.write(Data("Use --sensor-profile without additional arguments.\n".utf8))
                exit(2)
            }
            do {
                FileHandle.standardOutput.write(try SensorProfileReport.data(
                    revision: Bundle.main.object(forInfoDictionaryKey: "FTCWSourceRevision") as? String))
            } catch {
                FileHandle.standardError.write(Data("Could not describe the sensor profile.\n".utf8))
                exit(1)
            }
            return
        }
        guard CommandLine.arguments.contains("--runtime-check") else {
            if ApplicationSensorPolicy.selectedProfile != .compatibility {
                bridgeLog(.warning, "app", "Unqualified sensor profile: \(ApplicationSensorPolicy.selectedProfile.rawValue). Some sensor features are disabled; normal relaunch and reconnect restores compatibility.")
            }
            FTCWApp.main()
            return
        }
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Use --runtime-check without additional arguments.\n".utf8))
            exit(2)
        }
        do {
            let report = try RuntimeCompatibility.report(info: Bundle.main.infoDictionary ?? [:],
                                                         os: ProcessInfo.processInfo.operatingSystemVersion)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(report); data.append(10)
            FileHandle.standardOutput.write(data)
        } catch {
            FileHandle.standardError.write(Data("Runtime probe failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
