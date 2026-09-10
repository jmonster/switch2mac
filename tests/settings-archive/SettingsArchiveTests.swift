import Foundation

@main
enum SettingsArchiveTests {
    static func defaults() -> UserDefaults {
        let name = "ftcw-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
    static func sampleSettings(name: String = "Pad") -> [String: [String: Any]] {
        ["SERIAL-1": [
            "name": name, "rumble": 0.75, "deadzone": 0.1,
            "mouseSensitivity": 1.2, "holdStyle": "grip",
            "mouseEnabled": true, "invertLY": false, "ledPattern": 3,
            "stickCenterL": [0.01, -0.02],
            "keyMap": ["A": ["keyCode": 0, "modifiers": 0, "label": "A"]],
            "buttonMap": ["A": "B"]
        ]]
    }
    static func main() throws {
        let valid = SettingsArchive.encode(settings: sampleSettings(), links: ["LEFT":"RIGHT"])
        precondition(valid != nil)
        let decoded = SettingsArchive.decode(valid!)!
        precondition((decoded.controllerSettings["SERIAL-1"]?["name"] as? String) == "Pad")
        precondition(decoded.joyConLinks == ["LEFT":"RIGHT"])

        var payload = try JSONDecoder().decode(SettingsArchive.Payload.self, from: valid!)
        payload.version = 999
        let wrongVersion = try JSONEncoder().encode(payload)
        precondition(SettingsArchive.decode(wrongVersion) == nil)

        let malformed: [String: [String: Any]] = ["SERIAL-1": ["deadzone": 9.0]]
        precondition(SettingsArchive.encode(settings: malformed, links: [:]) == nil)
        precondition(SettingsArchive.encode(settings: ["SERIAL-1": ["mouseEnabled": 1]], links: [:]) == nil)
        precondition(SettingsArchive.encode(settings: ["SERIAL-1": ["rumble": true]], links: [:]) == nil)
        precondition(!SettingsArchive.validate(links: ["A":"B", "C":"B"]))
        precondition(!SettingsArchive.validate(links: ["A":"B", "B":"C"]))

        // Every successful export must be accepted by the same-version importer.
        let large = Dictionary(uniqueKeysWithValues: (0..<16).map {
            ("pad-\($0)", ["future": String(repeating: "x", count: 90_000)] as [String: Any])
        })
        precondition(SettingsArchive.encode(settings: large, links: [:]) == nil)
        precondition(SettingsArchive.encode(settings: ["pad": ["stickCenterL": [true, false]]], links: [:]) == nil)
        precondition(SettingsArchive.encode(settings: ["pad": ["keyMap": ["A": ["keyCode": true, "modifiers": 0, "label": "A"]]]], links: [:]) == nil)

        let d = defaults()
        d.set(sampleSettings(name: "before"), forKey: "controllerSettings")
        d.set(["L0":"R0"], forKey: "joyConLinks")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rollback = dir.appendingPathComponent("rollback.plist")
        precondition(SettingsArchive.stageRollback(defaults: d, recoveryURL: rollback))
        d.set(sampleSettings(name: "half-written"), forKey: "controllerSettings")
        d.set(["new":"link"], forKey: "joyConLinks")
        precondition(SettingsArchive.recover(defaults: d, recoveryURL: rollback))
        let restored = d.dictionary(forKey: "controllerSettings") as! [String: [String: Any]]
        precondition((restored["SERIAL-1"]?["name"] as? String) == "before")
        precondition((d.dictionary(forKey: "joyConLinks") as? [String:String]) == ["L0":"R0"])
        precondition(!FileManager.default.fileExists(atPath: rollback.path))

        let appliedData = SettingsArchive.encode(settings: sampleSettings(name: "after"), links: ["L1":"R1"])!
        precondition(SettingsArchive.apply(SettingsArchive.decode(appliedData)!, defaults: d, recoveryURL: rollback))
        let applied = d.dictionary(forKey: "controllerSettings") as! [String: [String: Any]]
        precondition((applied["SERIAL-1"]?["name"] as? String) == "after")
        precondition((d.dictionary(forKey: "joyConLinks") as? [String:String]) == ["L1":"R1"])
        precondition(!FileManager.default.fileExists(atPath: rollback.path))
        // A malformed existing journal must not be replaced by a new transaction.
        let corrupt = Data("not a recovery record".utf8)
        try corrupt.write(to: rollback)
        precondition(!SettingsArchive.apply(decoded, defaults: d, recoveryURL: rollback))
        let retained = try Data(contentsOf: rollback)
        precondition(retained == corrupt)
        precondition((d.dictionary(forKey: "joyConLinks") as? [String:String]) == ["L1":"R1"])
        try FileManager.default.removeItem(at: rollback)
        try FileManager.default.removeItem(at: dir)

        print("PASS settings archive validation and rollback")
    }
}
