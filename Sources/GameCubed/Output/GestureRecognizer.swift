// GestureRecognizer.swift
// Air-gesture macros: hold a chosen "gesture button," move the controller to
// draw a shape (a circle, a check, a flick), release — the app matches the
// gyro path against saved templates and fires the bound action.
//
// Holding a button to bookend the motion makes segmentation trivial and
// eliminates false positives from ordinary handling. Matching resamples each
// path to a fixed length, normalizes it (translation + scale invariant), and
// takes the nearest template under a distance threshold — a 1-D adaptation of
// the "$1 recognizer" idea over the 3-axis gyro signal.

import Foundation
import Synchronization
import CoreGraphics
import AppKit

/// A stored gesture: normalized template + the action it triggers.
struct AirGesture: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var template: [Double]        // 3*N normalized samples
    var key: KeySpec?             // keystroke action…
    var builtin: String?         // …or a built-in action id
}

enum GestureAction {
    static let builtins: [(id: String, label: String)] = [
        ("screenshot", "Take a screenshot"),
        ("lock", "Lock the screen"),
        ("missionControl", "Mission Control"),
        ("spotlight", "Spotlight search"),
    ]
}

final class GestureRecognizer: @unchecked Sendable {

    static let sampleCount = 24
    static let matchThreshold = 0.55

    private struct State: Sendable {
        var trigger: Switch2.Buttons = .gl
        var gestures: [AirGesture] = []
        var capturing: [Int: [SIMD3<Double>]] = [:]
        var wasHeld: [Int: Bool] = [:]
        var recordingName: String?
        var onRecorded: (@Sendable (AirGesture) -> Void)?
    }
    private let state = Mutex(State())
    var recordingName: String? {
        get { state.withLock { $0.recordingName } }
        set { state.withLock { $0.recordingName = newValue } }
    }
    var onRecorded: (@Sendable (AirGesture) -> Void)? {
        get { state.withLock { $0.onRecorded } }
        set { state.withLock { $0.onRecorded = newValue } }
    }
    init() { reload() }
    func reload() {
        let trigger = Switch2.button(named: UserDefaults.standard.string(forKey: "gestureTriggerButton") ?? "GL") ?? .gl
        let data = UserDefaults.standard.data(forKey: "airGestures") ?? Data()
        let list = (try? JSONDecoder().decode([AirGesture].self, from: data)) ?? []
        state.withLock {
            $0.trigger = trigger
            $0.gestures = Array(list.prefix(128)).filter {
                $0.template.count == Self.sampleCount * 3 && $0.template.allSatisfy(\.isFinite)
            }
        }
    }
    func reset(player: Int? = nil) {
        state.withLock {
            if let player { $0.capturing.removeValue(forKey: player); $0.wasHeld.removeValue(forKey: player) }
            else { $0.capturing.removeAll(); $0.wasHeld.removeAll() }
        }
    }

    static func save(_ gestures: [AirGesture]) {
        if let data = try? JSONEncoder().encode(gestures) {
            UserDefaults.standard.set(data, forKey: "airGestures")
        }
    }

    /// Configuration/capture state is locked; callbacks and platform effects
    /// execute after unlocking. No per-report UserDefaults or main-actor task.
    func process(player: Int, buttons: Switch2.Buttons, gyro: (Int16, Int16, Int16)) {
        let result: (AirGesture, (@Sendable (AirGesture) -> Void)?, Bool)? = state.withLock { storage in
            guard storage.recordingName != nil || !storage.gestures.isEmpty else { return nil }
            let held = buttons.contains(storage.trigger)
            let was = storage.wasHeld[player] ?? false
            storage.wasHeld[player] = held
            if held {
                var buffer = storage.capturing[player] ?? []
                if buffer.count < 400 { buffer.append(SIMD3(Double(gyro.0), Double(gyro.1), Double(gyro.2))) }
                storage.capturing[player] = buffer
                return nil
            }
            guard was else { return nil }
            let path = storage.capturing.removeValue(forKey: player) ?? []
            guard path.count >= 8 else { return nil }
            let template = Self.normalize(Self.resample(path, to: Self.sampleCount))
            if let name = storage.recordingName {
                storage.recordingName = nil
                return (AirGesture(name: name, template: template), storage.onRecorded, true)
            }
            var best: (AirGesture, Double)?
            for gesture in storage.gestures {
                let distance = Self.distance(template, gesture.template)
                if best == nil || distance < best!.1 { best = (gesture, distance) }
            }
            guard let (gesture, distance) = best, distance < Self.matchThreshold else { return nil }
            return (gesture, nil, false)
        }
        guard let (gesture, callback, recorded) = result else { return }
        if recorded { callback?(gesture) }
        else { DispatchQueue.main.async { [weak self] in self?.fire(gesture) } }
    }

    // MARK: - Signal processing

    private static func resample(_ path: [SIMD3<Double>], to n: Int) -> [SIMD3<Double>] {
        guard path.count > 1 else { return Array(repeating: path.first ?? .zero, count: n) }
        var out: [SIMD3<Double>] = []
        for i in 0..<n {
            let t = Double(i) / Double(n - 1) * Double(path.count - 1)
            let lo = Int(t.rounded(.down)), hi = min(lo + 1, path.count - 1)
            let frac = t - Double(lo)
            out.append(path[lo] * (1 - frac) + path[hi] * frac)
        }
        return out
    }

    /// Flatten, subtract mean, scale to unit RMS → translation/scale-invariant.
    private static func normalize(_ path: [SIMD3<Double>]) -> [Double] {
        var flat: [Double] = []
        for v in path { flat.append(v.x); flat.append(v.y); flat.append(v.z) }
        let mean = flat.reduce(0, +) / Double(flat.count)
        flat = flat.map { $0 - mean }
        let rms = (flat.map { $0 * $0 }.reduce(0, +) / Double(flat.count)).squareRoot()
        guard rms > 1e-6 else { return flat }
        return flat.map { $0 / rms }
    }

    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for i in 0..<min(a.count, b.count) { let d = a[i] - b[i]; sum += d * d }
        return (sum / Double(a.count)).squareRoot()
    }

    // MARK: - Actions

    @MainActor private func fire(_ g: AirGesture) {
        if let key = g.key {
            guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else { return }
            for down in [true, false] {
                if let e = CGEvent(keyboardEventSource: nil,
                                   virtualKey: CGKeyCode(key.keyCode), keyDown: down) {
                    e.flags = CGEventFlags(rawValue: key.modifiers)
                    e.post(tap: .cghidEventTap)
                }
            }
        } else if let builtin = g.builtin {
            Self.runBuiltin(builtin)
        }
    }

    @MainActor private static func runBuiltin(_ id: String) {
        switch id {
        case "screenshot":
            run("/usr/sbin/screencapture", ["-x",
                FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("Gesture \(Int(Date().timeIntervalSince1970)).png").path])
        case "lock":
            run("/usr/bin/pmset", ["displaysleepnow"])
        case "missionControl":
            run("/usr/bin/open", ["-a", "Mission Control"])
        case "spotlight":
            postHotkey(keyCode: 49, flags: .maskCommand)   // ⌘Space
        default: break
        }
    }

    private static func run(_ path: String, _ args: [String]) {
        let t = Process(); t.executableURL = URL(fileURLWithPath: path); t.arguments = args
        try? t.run()
    }

    private static func postHotkey(keyCode: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) {
                e.flags = flags; e.post(tap: .cghidEventTap)
            }
        }
    }
}
