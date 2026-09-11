import Foundation

enum CGEventType { case leftMouseDown, leftMouseUp, rightMouseDown, rightMouseUp, leftMouseDragged, rightMouseDragged, mouseMoved }
enum CGMouseButton { case left, right }
enum CGEventField { case mouseEventDeltaX, mouseEventDeltaY }
enum CGEventTapLocation { case cghidEventTap }
final class CGEvent {
    static var cursor = CGPoint(x: 100, y: 100)
    static var allowCreation = true
    static var lastDeltaX: Int64 = 0
    private var deltaX: Int64 = 0
    var location: CGPoint
    init?(source: AnyObject?) { location = Self.cursor }
    init?(mouseEventSource: AnyObject?, mouseType: CGEventType, mouseCursorPosition: CGPoint, mouseButton: CGMouseButton) {
        guard Self.allowCreation else { return nil }
        location = mouseCursorPosition
    }
    func setIntegerValueField(_ field: CGEventField, value: Int64) { if field == .mouseEventDeltaX { deltaX = value } }
    func post(tap: CGEventTapLocation) { Self.cursor = location; Self.lastDeltaX = deltaX }
}
@main enum MouseTests {
    static func main() {
        let mouse = MouseController()
        mouse.updateContext(permission: true, screens: [CGRect(x: 0, y: 0, width: 200, height: 200)])
        var config = ControllerConfiguration(); config.mouseEnabled = true
        var state = ControllerState(); state.mouseX = 1000; state.mouseY = 1000; state.liftDistance = 10
        func input() -> Bool { mouse.handle(serial: "test", model: .joyCon2Right, state: state, configuration: config) }
        precondition(!input(), "The first sample only primes counters")
        state.mouseX += 10
        precondition(input() && CGEvent.cursor.x == 103)
        precondition(!input(), "Stationary reports are not activity")
        state.liftDistance = 0; state.mouseX += 100
        precondition(!input())
        state.liftDistance = 10; state.surfaceQuality = 5000; state.mouseX += 100
        precondition(!input())
        state.surfaceQuality = 0; config.mouseEnabled = false; state.mouseX += 100
        precondition(!input())
        config.mouseEnabled = true; precondition(!input())
        mouse.updateContext(permission: false, screens: []); state.mouseX += 100
        precondition(!input())
        mouse.updateContext(permission: true, screens: [CGRect(x: 0, y: 0, width: 200, height: 200)])
        state.mouseX = UInt16.max; precondition(!input())
        state.mouseX = 3; precondition(input(), "Counter wrap must retain accepted motion")
        CGEvent.cursor = CGPoint(x: 199, y: 100); state.mouseX += 10
        precondition(input() && CGEvent.cursor.x == 199 && CGEvent.lastDeltaX == 3,
                     "Cursor clamping must preserve relative mouse events for games")
        CGEvent.cursor = CGPoint(x: 100, y: 100); CGEvent.allowCreation = false; state.mouseX += 10
        precondition(!input(), "Failed event creation is not activity")
        CGEvent.allowCreation = true; mouse.reset(); config.mouseSensitivity = 0.1
        precondition(!input())
        for _ in 0..<1000 {
            state.mouseX += 1; precondition(!input())
            state.mouseX -= 1; precondition(!input())
        }
        precondition(!mouse.handle(serial: "pro", model: .proController2, state: state, configuration: config))
        print("PASS accepted pointer motion, noise, lift/quality, wrap, disabled/denied, edge clamping and event failure")
    }
}
