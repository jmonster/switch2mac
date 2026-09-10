import Foundation

final class Delegate: ControllerSessionDelegate {
    var ready = 0
    var failures = 0
    func sessionReady(_ session: ControllerSession) { ready += 1 }
    func sessionFailed(_ session: ControllerSession, reason: String) { failures += 1 }
    func sessionDidUpdateState(_ session: ControllerSession) {}
}

final class StateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main
... (go/truncated-by-rlsnow)...