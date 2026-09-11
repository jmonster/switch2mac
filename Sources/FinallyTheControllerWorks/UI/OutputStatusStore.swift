import Foundation
import Combine

/// Explicit snapshots, never periodic health polling or report-path publication.
/// A generation owns its callbacks, so timeouts/replacements cannot revive old
/// successes. Unknown and mismatched provider replies stay unknown.
@MainActor
final class OutputStatusStore: ObservableObject {
    static let shared = OutputStatusStore()
    @Published private(set) var reports: [OutputBackend: OutputHealth] = [:]
    @Published private(set) var pending = Set<OutputBackend>()
    @Published private(set) var updatedAt: Date?
    private var providers: [OutputBackend: any OutputHealthProviding] = [:]
    private(set) var generation: UInt64 = 0
    private var timeout: Task<Void, Never>?

    func register<T: OutputHealthProviding>(_ sink: T) -> T {
        // Registration can replace a sink; callbacks from its predecessor must
        // not complete a new snapshot, even for the same backend.
        generation &+= 1
        timeout?.cancel(); timeout = nil
        pending.removeAll(); reports.removeAll(); updatedAt = nil
        providers[sink.outputBackend] = sink
        return sink
    }

    func refresh() {
        guard pending.isEmpty else { return }
        timeout?.cancel(); timeout = nil
        generation &+= 1
        let token = generation
        reports.removeAll(); pending = Set(providers.keys); updatedAt = Date()
        for (backend, provider) in providers {
            provider.requestHealth { [weak self] report in
                Task { @MainActor in self?.receive(report, for: backend, generation: token) }
            }
        }
        guard !pending.isEmpty else { return }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.expire(generation: token)
        }
    }

    private func receive(_ report: OutputHealth, for backend: OutputBackend, generation token: UInt64) {
        guard generation == token, pending.remove(backend) != nil else { return }
        if report.backend == backend {
            var bounded = report
            bounded.activeCount = max(0, min(256, report.activeCount))
            bounded.affectedSlots = Array(Set(report.affectedSlots.prefix(4).filter { (0..<4).contains($0) })).sorted()
            reports[backend] = bounded
        }
        if pending.isEmpty { timeout?.cancel(); timeout = nil }
    }

    /// Shared by the one-shot deadline and deterministic lifecycle tests.
    func expire(generation token: UInt64) {
        guard generation == token else { return }
        pending.removeAll()
        timeout?.cancel(); timeout = nil
    }
}
