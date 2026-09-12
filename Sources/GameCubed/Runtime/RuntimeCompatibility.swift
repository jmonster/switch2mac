import Foundation

enum RuntimeCompatibility {
    struct Report: Encodable {
        let schema = 1
        let scope = "packaged-loader-and-protocol"
        let architecture: String
        let operatingSystem: String
        let declaredMinimum: String
        let sourceRevision: String
        let sourceDirty: Bool
        let hardwareQualification = "not-run"
        let gameQualification = "not-run"
        let hidEntitlementQualification = "not-run"
    }
    enum Failure: Error { case malformedBundle, unsupportedRuntime, protocolSelfCheck }
    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
    static func report(info: [String: Any], os: OperatingSystemVersion) throws -> Report {
        guard info["CFBundleIdentifier"] as? String == "io.github.switch2mac.gamecubed",
              let minimum = info["LSMinimumSystemVersion"] as? String,
              let revision = info["FTCWSourceRevision"] as? String,
              revision.utf8.count == 40, revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let dirty = info["FTCWSourceDirty"] as? Bool,
              info["FTCWBuildArchitecture"] as? String == architecture,
              architecture != "unknown" else { throw Failure.malformedBundle }
        let parts = minimum.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard (1...3).contains(parts.count), numbers.count == parts.count,
              numbers.allSatisfy({ (0...1000).contains($0) }) else { throw Failure.malformedBundle }
        let wanted = numbers + Array(repeating: 0, count: 3 - numbers.count)
        let actual = [os.majorVersion, os.minorVersion, os.patchVersion]
        guard !actual.lexicographicallyPrecedes(wanted) else { throw Failure.unsupportedRuntime }
        guard Switch2.u16(Data([0x34, 0x12]), 0) == 0x1234,
              Switch2.InputReport(data: Data(repeating: 0, count: 3)) == nil,
              Switch2.Model.allCases.count == 4 else { throw Failure.protocolSelfCheck }
        return Report(architecture: architecture, operatingSystem: actual.map(String.init).joined(separator: "."),
                      declaredMinimum: minimum, sourceRevision: revision, sourceDirty: dirty)
    }
}
