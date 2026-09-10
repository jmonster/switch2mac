import AppKit

@main
struct KeyCaptureTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        func key(_ code: UInt16, _ characters: String = "a", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                            timestamp: 1, windowNumber: 0, context: nil,
                            characters: characters, charactersIgnoringModifiers: characters,
                            isARepeat: false, keyCode: code)!
        }
        let first = KeyCaptureSession(), second = KeyCaptureSession()
        var received: [KeySpec] = []
        first.begin(id: "A") { received.append($0) }
        second.begin(id: "B") { received.append($0) }
        precondition(first.capturingID == nil && second.capturingID == "B")
        NSApp.sendEvent(key(0, "a", [.command, .shift]))
        precondition(received.count == 1 && received[0].keyCode == 0)
        precondition(received[0].modifiers == CGEventFlags([.maskCommand, .maskShift]).rawValue)
        precondition(received[0].label == "⇧⌘A" && second.capturingID == nil)
        second.begin(id: "B") { received.append($0) }
        NSApp.sendEvent(key(53, "\u{1b}"))
        precondition(received.count == 1 && second.capturingID == nil)
        first.begin(id: "A") { received.append($0) }; first.cancel(); first.cancel()
        precondition(first.capturingID == nil)
        weak var retired: KeyCaptureSession?
        do {
            let temporary = KeyCaptureSession(); retired = temporary
            temporary.begin(id: "X") { received.append($0) }
        }
        precondition(retired == nil, "Monitor must not keep its owner alive")
        first.begin(id: "Y") { received.append($0) }
        NSApp.sendEvent(key(36, "\r"))
        precondition(received.count == 2 && received[1].label == "Return")
        precondition(first.capturingID == nil)
        print("PASS main-actor key capture: replacement, modifiers, Escape, cancellation, release and reuse")
    }
}
