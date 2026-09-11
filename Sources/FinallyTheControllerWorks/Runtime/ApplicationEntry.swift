import Foundation
import SwiftUI

/// The runtime probe exits before constructing the SwiftUI app, its delegate,
/// Bluetooth engine, settings recovery, output listeners or permission prompts.
@main enum ApplicationEntry {
    @MainActor static func main() {
        guard CommandLine.arguments.contains("--runtime-check") else {
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
