// Bluetooth-queue confined; no AppKit or permission queries on the report path.
import Foundation
import CoreGraphics

final class MouseController: @unchecked Sendable {
    private struct UnitState {
        var lastX: UInt16 = 0, lastY: UInt16 = 0
        var primed = false
        var residualX = 0.0, residualY = 0.0
    }
    private var units: [String: UnitState] = [:]
    private var owners = HeldOutputs<String, Int>()
    private var pressed = Set<Int>()
    private var permission = false
    private var screens: [CGRect] = []

    func updateContext(permission: Bool, screens: [CGRect]) {
        if !permission { reset() }
        self.permission = permission; self.screens = screens
    }
    func reset(serial: String) {
        units.removeValue(forKey: serial)
        applyButtons(serial: serial, desired: [])
    }
    func reset() {
        units.removeAll()
        for button in owners.reset() { postButton(button, down: false) }
        pressed.removeAll()
    }
    private func applyButtons(serial: String, desired: Set<Int>) {
        let changes = owners.replace(serial, with: desired)
        for button in changes.released { postButton(button, down: false); pressed.remove(button) }
        for button in changes.pressed { postButton(button, down: true); pressed.insert(button) }
    }
    private static func wrapDiff(_ current: UInt16, _ previous: UInt16) -> Int {
        Int(Int16(bitPattern: current &- previous))
    }
    func handle(serial: String, model: Switch2.Model, state: ControllerState,
                configuration: ControllerConfiguration) {
        guard configuration.mouseEnabled, permission,
              model == .joyCon2Left || model == .joyCon2Right else { reset(serial: serial); return }
        let left = model == .joyCon2Left ? state.buttons.contains(.slL) : state.buttons.contains(.slR)
        let right = model == .joyCon2Left ? state.buttons.contains(.srL) : state.buttons.contains(.srR)
        var buttons = Set<Int>()
        if left { buttons.insert(0) }; if right { buttons.insert(1) }
        applyButtons(serial: serial, desired: buttons)
        var unit = units[serial] ?? UnitState()
        defer { units[serial] = unit }
        let dx = Self.wrapDiff(state.mouseX, unit.lastX), dy = Self.wrapDiff(state.mouseY, unit.lastY)
        unit.lastX = state.mouseX; unit.lastY = state.mouseY
        guard unit.primed else { unit.primed = true; return }
        guard state.liftDistance != 0 && state.liftDistance < 1000 && state.surfaceQuality < 4000 else { return }
        let scale = 0.35 * configuration.mouseSensitivity
        let x = Double(dx) * scale + unit.residualX, y = Double(dy) * scale + unit.residualY
        let moveX = x.rounded(.towardZero), moveY = y.rounded(.towardZero)
        unit.residualX = x - moveX; unit.residualY = y - moveY
        guard moveX != 0 || moveY != 0 else { return }
        postMove(dx: moveX, dy: moveY)
    }
    private func postButton(_ button: Int, down: Bool) {
        let left = button == 0
        let type: CGEventType = left ? (down ? .leftMouseDown : .leftMouseUp)
                                      : (down ? .rightMouseDown : .rightMouseUp)
        CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero,
                mouseButton: left ? .left : .right)?.post(tap: .cghidEventTap)
    }
    private func postMove(dx: Double, dy: Double) {
        let current = CGEvent(source: nil)?.location ?? .zero
        var target = CGPoint(x: current.x + dx, y: current.y + dy)
        if !screens.isEmpty && !screens.contains(where: { $0.contains(target) }) {
            let candidates = screens.map { bounds in
                CGPoint(x: max(bounds.minX, min(bounds.maxX - 1, target.x)),
                        y: max(bounds.minY, min(bounds.maxY - 1, target.y)))
            }
            target = candidates.min { a, b in
                hypot(a.x-target.x, a.y-target.y) < hypot(b.x-target.x, b.y-target.y)
            } ?? target
        }
        let type: CGEventType = pressed.contains(0) ? .leftMouseDragged
            : (pressed.contains(1) ? .rightMouseDragged : .mouseMoved)
        let button: CGMouseButton = pressed.contains(1) && !pressed.contains(0) ? .right : .left
        if let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: button) {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
            event.post(tap: .cghidEventTap)
        }
    }
}
