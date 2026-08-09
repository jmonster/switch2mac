// KeyboardMapper.swift
// Turns controller buttons into keyboard keystrokes so the controller works
// in apps and games that have NO controller support (map buttons to WASD,
// arrows, space, etc.). Mappings can be global ("All apps") or scoped to the
// frontmost application's bundle id — a per-app profile that switches
// automatically as you change apps.
//
// A key-mapped button is SUPPRESSED from the gamepad output (so it doesn't
// double-act as both a key and a pad button). Key events are posted via
// CGEvent, which needs the same Accessibility permission as mouse mode.

import Foundation
import CoreGraphics
import AppKit

/// A bound key: virtual keycode + modifier flags + a human label.
struct KeySpec: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64      // CGEventFlags rawValue
    var label: String

    var asDictionary: [String: Any] {
        ["keyCode": Int(keyCode), "modifiers": Int(modifiers), "label": label]
    }
    init(keyCode: UInt16, modifiers: UInt64, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    init?(dictionary: [String: Any]) {
        guard let k = dictionary["keyCode"] as? Int,
              let m = dictionary["modifiers"] as? Int,
              let l = dictionary["label"] as? String else { return nil }
        keyCode = UInt16(k); modifiers = UInt64(m); label = l
    }
}

final class KeyboardMapper: @unchecked Sendable {

    /// Frontmost app bundle id, refreshed by a workspace observer.
    private var frontApp: String = ""
    private var lastButtons: [Int: Switch2.Buttons] = [:]    // per player
    private var permissionOK = false
    private var permissionChecked = false

    init() {
        frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontApp = app?.bundleIdentifier ?? ""
        }
    }

    /// The set of buttons currently mapped to keys for this controller in the
    /// active app — these are suppressed from the gamepad output.
    func mappedButtons(serial: String) -> Switch2.Buttons {
        let map = Self.activeMap(serial: serial, app: frontApp)
        var mask: Switch2.Buttons = []
        for name in map.keys {
            if let b = Switch2.button(named: name) { mask.insert(b) }
        }
        return mask
    }

    /// Process one player's button state; post key events on edges.
    /// Returns true if this controller has ANY key mapping active (so the
    /// engine knows to suppress mapped buttons).
    @discardableResult
    func process(player: Int, serial: String, buttons: Switch2.Buttons) -> Bool {
        let map = Self.activeMap(serial: serial, app: frontApp)
        guard !map.isEmpty else {
            lastButtons[player] = buttons
            return false
        }
        guard ensurePermission() else { return true }

        let prev = lastButtons[player] ?? []
        for (name, spec) in map {
            guard let b = Switch2.button(named: name) else { continue }
            let now = buttons.contains(b), was = prev.contains(b)
            if now && !was { postKey(spec, down: true) }
            else if !now && was { postKey(spec, down: false) }
        }
        lastButtons[player] = buttons
        return true
    }

    // MARK: - Mapping lookup

    /// The effective button→key map for a controller in an app: the app
    /// override if present, else the global ("") map.
    private static func activeMap(serial: String, app: String) -> [String: KeySpec] {
        let store = UserDefaults.standard.dictionary(forKey: "controllerSettings")
        guard let entry = store?[serial] as? [String: Any] else { return [:] }
        func parse(_ raw: Any?) -> [String: KeySpec] {
            guard let dict = raw as? [String: [String: Any]] else { return [:] }
            var out: [String: KeySpec] = [:]
            for (k, v) in dict { if let s = KeySpec(dictionary: v) { out[k] = s } }
            return out
        }
        let byApp = entry["keyMapByApp"] as? [String: [String: [String: Any]]]
        if !app.isEmpty, let appMap = byApp?[app], !appMap.isEmpty {
            return parse(appMap)
        }
        return parse(entry["keyMap"])
    }

    // MARK: - Event posting

    private func postKey(_ spec: KeySpec, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil,
                                  virtualKey: CGKeyCode(spec.keyCode), keyDown: down) else { return }
        event.flags = CGEventFlags(rawValue: spec.modifiers)
        event.post(tap: .cghidEventTap)
    }

    private func ensurePermission() -> Bool {
        if permissionChecked { return permissionOK }
        permissionChecked = true
        permissionOK = CGPreflightPostEventAccess() || CGRequestPostEventAccess()
        if !permissionOK {
            bridgeLog(.warning, "keymap",
                      "Accessibility permission needed for keyboard mapping — "
                      + "grant it in System Settings > Privacy & Security > Accessibility")
        }
        return permissionOK
    }
}
