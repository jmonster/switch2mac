import AppKit
import CoreGraphics

/// All platform queries and permission prompts run on the main actor. The
/// engine receives a value snapshot; no TCC round trip is made per report.
struct InputContext: Sendable {
    var application = ""
    var canPostEvents = false
    var screens: [CGRect] = [] // Quartz coordinates, including negative origins.
}

@MainActor
final class InputEnvironment {
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var asked = false
    private let changed: @Sendable (InputContext) -> Void
    private var last = InputContext()
    private var needed = false

    init(changed: @escaping @Sendable (InputContext) -> Void) {
        self.changed = changed
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        refresh()
    }

    func setNeeded(_ value: Bool) {
        needed = value
        if value && timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        } else if !value {
            timer?.invalidate(); timer = nil
        }
        if value && !asked {
            asked = true
            if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        }
        refresh()
    }

    func refresh() {
        var context = InputContext()
        context.application = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        context.canPostEvents = needed && CGPreflightPostEventAccess()
        context.screens = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(number.uint32Value)
        }
        if context.application != last.application || context.canPostEvents != last.canPostEvents || context.screens != last.screens {
            last = context; changed(context)
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
}
