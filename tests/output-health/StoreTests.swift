import Foundation
import Synchronization

final class Provider: OutputHealthProviding, Sendable {
    let outputBackend: OutputBackend
    private let replies = Mutex<[@Sendable (OutputHealth) -> Void]>([])
    init(_ backend: OutputBackend) { outputBackend = backend }
    func requestHealth(_ reply: @escaping @Sendable (OutputHealth) -> Void) {
        replies.withLock { $0.append(reply) }
    }
    var count: Int { replies.withLock { $0.count } }
    func send(_ index: Int, _ report: OutputHealth) { replies.withLock { $0[index] }(report) }
}
@main enum StoreTests {
    @MainActor static func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        precondition(condition(), "Main-actor callback did not finish")
    }
    @MainActor static func main() async {
        let store = OutputStatusStore()
        store.refresh()
        precondition(store.pending.isEmpty && store.reports.isEmpty)
        let sdl = store.register(Provider(.sdl)), browser = store.register(Provider(.browser))
        store.refresh(); let old = store.generation
        store.refresh()
        precondition(sdl.count == 1 && browser.count == 1, "overlapping refresh queued work")
        sdl.send(0, OutputHealth(backend: .sdl, state: .clientConnected, activeCount: Int.max, affectedSlots: [-1,2,2,9]))
        await settle { store.reports[.sdl] != nil }
        precondition(store.reports[.sdl]?.activeCount == 256 && store.reports[.sdl]?.affectedSlots == [2])
        store.expire(generation: old)
        precondition(store.pending.isEmpty && store.reports[.browser] == nil)
        store.refresh(); let current = store.generation
        browser.send(0, OutputHealth(backend: .browser, state: .clientConnected))
        sdl.send(1, OutputHealth(backend: .browser, state: .deviceActive)) // wrong backend
        await settle { !store.pending.contains(.sdl) }
        precondition(store.reports.isEmpty && store.pending == [.browser])
        store.expire(generation: old)
        precondition(store.pending == [.browser], "old deadline expired a new snapshot")
        browser.send(1, OutputHealth(backend: .browser, state: .disabled))
        await settle { store.pending.isEmpty }
        precondition(store.reports[.browser]?.state == .disabled)
        browser.send(1, OutputHealth(backend: .browser, state: .clientConnected)) // duplicate
        let replacement = store.register(Provider(.browser))
        precondition(store.reports.isEmpty && store.updatedAt == nil)
        store.refresh()
        sdl.send(2, OutputHealth(backend: .sdl, state: .listening))
        replacement.send(0, OutputHealth(backend: .browser, state: .needsConfiguration))
        await settle { store.pending.isEmpty }
        precondition(store.reports[.browser]?.state == .needsConfiguration)
        store.expire(generation: current)
        precondition(store.reports[.browser]?.state == .needsConfiguration)
        print("PASS snapshot timeout, generation, provider replacement, wrong/duplicate replies and bounds")
    }
}
