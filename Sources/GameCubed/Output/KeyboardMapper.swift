// Bluetooth-queue confined. UI/workspace state arrives as an immutable context.
import Foundation
import CoreGraphics

final class KeyboardMapper: @unchecked Sendable {
    private var held = HeldOutputs<Int, UInt16>()
    private var emitted: [UInt16: KeySpec] = [:]
    private var frontApp = ""
    private var permission = false
    private let post: (KeySpec, Bool) -> Void

    init(post: @escaping (KeySpec, Bool) -> Void = KeyboardMapper.postKey) { self.post = post }

    func updateContext(app: String, permission: Bool) {
        if app != frontApp || permission != self.permission { reset() }
        frontApp = app; self.permission = permission
    }

    /// Return the precise controls suppressed; do not parse the map twice or
    /// suppress a digital trigger's bit while leaving its axis asserted.
    func process(player: Int, configuration: ControllerConfiguration,
                 buttons: Switch2.Buttons) -> Switch2.Buttons {
        let map = configuration.keys(for: frontApp)
        guard permission else { reset(player: player); return [] }
        var desired: [UInt16: KeySpec] = [:]
        var suppressed: Switch2.Buttons = []
        // Stable order makes shared-key modifier selection deterministic.
        for (raw, spec) in map.sorted(by: { $0.key < $1.key }) {
            let button = Switch2.Buttons(rawValue: raw)
            suppressed.insert(button)
            if buttons.contains(button), desired[spec.keyCode] == nil { desired[spec.keyCode] = spec }
        }
        let changes = held.replace(player, with: Set(desired.keys))
        for code in changes.released.sorted() { release(code) }
        for code in changes.pressed.sorted() {
            if let spec = desired[code] { emitted[code] = spec; post(spec, true) }
        }
        return suppressed
    }

    func reset(player: Int) {
        for code in held.replace(player, with: []).released.sorted() { release(code) }
    }
    func reset() {
        for code in held.reset().sorted() { release(code) }
    }
    private func release(_ code: UInt16) {
        if let original = emitted.removeValue(forKey: code) { post(original, false) }
    }
    private static func postKey(_ spec: KeySpec, _ down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: spec.keyCode, keyDown: down) else { return }
        event.flags = CGEventFlags(rawValue: spec.modifiers)
        event.post(tap: .cghidEventTap)
    }
}
