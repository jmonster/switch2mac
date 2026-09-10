import Foundation

/// Value snapshot constructed on settings changes, never parsed per report.
struct ControllerConfiguration: Sendable {
    var name = ""
    var rumble = 1.0
    var deadzone = 0.0
    var centerL = (0.0, 0.0), centerR = (0.0, 0.0)
    var invertLX = false, invertLY = false, invertRX = false, invertRY = false
    var triggerThreshold = 0.0
    var mouseEnabled = false
    var mouseSensitivity = 1.0
    var screenshot = false
    var buttonMap: [(from: Switch2.Buttons, to: Switch2.Buttons)] = []
    var globalKeys: [UInt32: KeySpec] = [:]
    var appKeys: [String: [UInt32: KeySpec]] = [:]

    init(_ entry: [String: Any] = [:]) {
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            guard let value = entry[key] as? Double, value.isFinite else { return fallback }
            return max(range.lowerBound, min(range.upperBound, value))
        }
        func center(_ key: String) -> (Double, Double) {
            guard let values = entry[key] as? [Double], values.count == 2,
                  values.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { return (0, 0) }
            return (values[0], values[1])
        }
        func keys(_ raw: Any?) -> [UInt32: KeySpec] {
            guard let map = raw as? [String: [String: Any]], map.count <= 32 else { return [:] }
            var result: [UInt32: KeySpec] = [:]
            for (name, raw) in map {
                if let button = Switch2.button(named: name), let spec = KeySpec(dictionary: raw) {
                    result[button.rawValue] = spec
                }
            }
            return result
        }
        name = String((entry["name"] as? String ?? "").prefix(256))
        rumble = number("rumble", 1, 0...1)
        deadzone = number("deadzone", 0, 0...0.95)
        triggerThreshold = number("triggerThreshold", 0, 0...1)
        centerL = center("stickCenterL"); centerR = center("stickCenterR")
        invertLX = entry["invertLX"] as? Bool ?? false
        invertLY = entry["invertLY"] as? Bool ?? false
        invertRX = entry["invertRX"] as? Bool ?? false
        invertRY = entry["invertRY"] as? Bool ?? false
        mouseEnabled = entry["mouseEnabled"] as? Bool ?? false
        mouseSensitivity = number("mouseSensitivity", 1, 0.1...5)
        screenshot = entry["captureScreenshot"] as? Bool ?? false
        if let map = entry["buttonMap"] as? [String: String], !map.isEmpty {
            buttonMap = Switch2.namedButtons.map { name, button in
                (button, Switch2.button(named: map[name] ?? name) ?? button)
            }
        }
        globalKeys = keys(entry["keyMap"])
        if let byApp = entry["keyMapByApp"] as? [String: Any], byApp.count <= 128 {
            for (app, raw) in byApp { appKeys[app] = keys(raw) }
        }
    }

    func keys(for app: String) -> [UInt32: KeySpec] {
        // An explicitly empty app override disables the global mapping there.
        appKeys[app] ?? globalKeys
    }

    func apply(_ input: ControllerState, analogTriggers: Bool) -> ControllerState {
        var output = input
        func shape(_ stick: (x: Double, y: Double), _ center: (Double, Double)) -> (Double, Double) {
            let x = stick.x.isFinite ? max(-1, min(1, stick.x - center.0)) : 0
            let y = stick.y.isFinite ? max(-1, min(1, stick.y - center.1)) : 0
            guard deadzone > 0 else { return (x, y) }
            let magnitude = (x*x + y*y).squareRoot()
            guard magnitude > deadzone else { return (0, 0) }
            let scale = min(1, (magnitude - deadzone) / (1 - deadzone)) / magnitude
            return (x * scale, y * scale)
        }
        output.leftStick = shape(input.leftStick, centerL)
        output.rightStick = shape(input.rightStick, centerR)
        if invertLX { output.leftStick.x *= -1 }; if invertLY { output.leftStick.y *= -1 }
        if invertRX { output.rightStick.x *= -1 }; if invertRY { output.rightStick.y *= -1 }
        if !buttonMap.isEmpty {
            output.buttons = []
            for pair in buttonMap where input.buttons.contains(pair.from) { output.buttons.insert(pair.to) }
            if !analogTriggers {
                output.leftTrigger = output.buttons.contains(.zl) ? 255 : 0
                output.rightTrigger = output.buttons.contains(.zr) ? 255 : 0
            }
        }
        let threshold = UInt8(triggerThreshold * 255)
        if output.leftTrigger < threshold { output.leftTrigger = 0 }
        if output.rightTrigger < threshold { output.rightTrigger = 0 }
        return output
    }

    static func suppress(_ mask: Switch2.Buttons, in state: inout ControllerState, analogTriggers: Bool) {
        state.buttons.subtract(mask)
        // GameCube travel is independent of the physical digital click.
        if !analogTriggers {
            if mask.contains(.zl) { state.leftTrigger = 0 }
            if mask.contains(.zr) { state.rightTrigger = 0 }
        }
    }
}

/// The key code and modifiers actually sent must survive mapping changes.
struct KeySpec: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt64
    var label: String
    init(keyCode: UInt16, modifiers: UInt64, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    init?(dictionary: [String: Any]) {
        guard let code = dictionary["keyCode"] as? Int, let key = UInt16(exactly: code),
              let rawFlags = dictionary["modifiers"] as? Int, let flags = UInt64(exactly: rawFlags),
              let text = dictionary["label"] as? String, text.utf8.count <= 256 else { return nil }
        self.init(keyCode: key, modifiers: flags, label: text)
    }
    var asDictionary: [String: Any] {
        ["keyCode": Int(keyCode), "modifiers": NSNumber(value: modifiers), "label": label]
    }
}

/// Queue-confined ownership ledger: only the first owner presses an output;
/// only the last owner releases it. Replacing a mapping is not a release leak.
struct HeldOutputs<Source: Hashable, Control: Hashable> {
    private var sources: [Source: Set<Control>] = [:]
    private var counts: [Control: Int] = [:]
    mutating func replace(_ source: Source, with desired: Set<Control>) -> (pressed: Set<Control>, released: Set<Control>) {
        let previous = sources[source] ?? []
        var pressed = Set<Control>(), released = Set<Control>()
        for key in previous.subtracting(desired) {
            let remaining = (counts[key] ?? 1) - 1
            if remaining == 0 { counts.removeValue(forKey: key); released.insert(key) }
            else { counts[key] = remaining }
        }
        for key in desired.subtracting(previous) {
            if counts[key] == nil { pressed.insert(key) }
            counts[key, default: 0] += 1
        }
        if desired.isEmpty { sources.removeValue(forKey: source) } else { sources[source] = desired }
        return (pressed, released)
    }
    mutating func reset() -> Set<Control> {
        let held = Set(counts.keys)
        sources.removeAll(); counts.removeAll()
        return held
    }
}
