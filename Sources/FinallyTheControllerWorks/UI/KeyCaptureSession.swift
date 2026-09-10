import AppKit
import Combine

/// Owns the local NSEvent key-down monitor during a capture. Exactly one
/// monitor exists at a time (starting a new capture cancels the previous
/// one), Escape cancels without binding, and cancel() — called on tap-out,
/// view disappearance, or deinit — always removes the monitor, so a capture
/// can never leak and swallow keystrokes for the app's lifetime.
@MainActor
final class KeyCaptureSession: ObservableObject {
    @Published private(set) var capturingID: String?
    private var monitor: Any?

    /// The one armed session app-wide. Arming any capture disarms every
    /// other (each controller card and the Gestures window own their own
    /// session), so two monitors can never both swallow keystrokes.
    private static weak var armed: KeyCaptureSession?

    func begin(id: String, onCapture: @escaping (KeySpec) -> Void) {
        KeyCaptureSession.armed?.cancel()
        KeyCaptureSession.armed = self
        capturingID = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // AppKit delivers local event monitors synchronously on the main
            // thread. Do not enqueue a task: the return value controls delivery.
            return MainActor.assumeIsolated {
                guard let self else { return event }
                if event.keyCode == 53 {           // Escape backs out, binds nothing
                    self.cancel()
                    return nil
                }
                let spec = KeySpec(
                    keyCode: event.keyCode,
                    modifiers: Self.cgFlags(from: event.modifierFlags),
                    label: Self.describe(event))
                self.cancel()
                onCapture(spec)
                return nil                          // swallow the key
            }
        }
    }

    func cancel() {
        if KeyCaptureSession.armed === self { KeyCaptureSession.armed = nil }
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        capturingID = nil
    }

    isolated deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }

    static func cgFlags(from flags: NSEvent.ModifierFlags) -> UInt64 {
        var cg: CGEventFlags = []
        if flags.contains(.command) { cg.insert(.maskCommand) }
        if flags.contains(.option) { cg.insert(.maskAlternate) }
        if flags.contains(.control) { cg.insert(.maskControl) }
        if flags.contains(.shift) { cg.insert(.maskShift) }
        return cg.rawValue
    }

    static func describe(_ event: NSEvent) -> String {
        var parts: [String] = []
        let f = event.modifierFlags
        if f.contains(.control) { parts.append("⌃") }
        if f.contains(.option) { parts.append("⌥") }
        if f.contains(.shift) { parts.append("⇧") }
        if f.contains(.command) { parts.append("⌘") }
        let key = event.charactersIgnoringModifiers?.uppercased()
        parts.append(specialKeyName(event.keyCode) ?? (key?.isEmpty == false ? key! : "key\(event.keyCode)"))
        return parts.joined()
    }

    private static func specialKeyName(_ code: UInt16) -> String? {
        switch code {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return nil
        }
    }
}
