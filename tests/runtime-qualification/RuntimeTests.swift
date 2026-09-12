import Foundation

@main enum RuntimeTests {
    static func main() throws {
        let info: [String: Any] = ["CFBundleIdentifier": "io.github.switch2mac.gamecubed",
            "LSMinimumSystemVersion": "15.0", "FTCWSourceRevision": String(repeating: "a", count: 40),
            "FTCWSourceDirty": false, "FTCWBuildArchitecture": RuntimeCompatibility.architecture]
        let report = try RuntimeCompatibility.report(info: info, os: .init(majorVersion: 15, minorVersion: 7, patchVersion: 9))
        precondition(report.operatingSystem == "15.7.9" && report.hardwareQualification == "not-run")
        precondition((try? RuntimeCompatibility.report(info: info, os: .init(majorVersion: 14, minorVersion: 9, patchVersion: 0))) == nil)
        for key in info.keys {
            var missing = info; missing.removeValue(forKey: key)
            precondition((try? RuntimeCompatibility.report(info: missing, os: .init(majorVersion: 26, minorVersion: 0, patchVersion: 0))) == nil)
        }
        for bad in ["", "15.x", "15..0", "-1", "15.0.0.0", "1001"] {
            var invalid = info; invalid["LSMinimumSystemVersion"] = bad
            precondition((try? RuntimeCompatibility.report(info: invalid, os: .init(majorVersion: 26, minorVersion: 0, patchVersion: 0))) == nil)
        }
        print("PASS runtime metadata, deployment comparison, missing fields and protocol probe")
    }
}
