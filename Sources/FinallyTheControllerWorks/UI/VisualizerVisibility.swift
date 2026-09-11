import SwiftUI
import AppKit

/// SwiftUI appearance alone is insufficient: closed, minimized, hidden and
/// fully occluded windows can retain their view hierarchy. Observe the window,
/// not a polling timer, and give each subscriber its own lifetime token.
struct VisualizerVisibility: NSViewRepresentable {
    let engine: BridgeEngine
    func makeNSView(context: Context) -> VisibilityView { VisibilityView(engine: engine) }
    func updateNSView(_ nsView: VisibilityView, context: Context) { nsView.refresh() }
    static func dismantleNSView(_ nsView: VisibilityView, coordinator: ()) { nsView.stop() }

    @MainActor final class VisibilityView: NSView {
        private weak var engine: BridgeEngine?
        private let subscriber = UUID()
        private var observers: [NSObjectProtocol] = []
        init(engine: BridgeEngine) { self.engine = engine; super.init(frame: .zero) }
        required init?(coder: NSCoder) { return nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setVisible(false) }
            })
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                })
            }
            refresh()
        }
        func refresh() {
            setVisible(window?.isVisible == true && window?.isMiniaturized == false
                       && window?.occlusionState.contains(.visible) == true && !NSApp.isHidden)
        }
        private func setVisible(_ value: Bool) { engine?.setVisualizerVisible(value, subscriber: subscriber) }
        func stop() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll(); setVisible(false)
        }
    }
}
