import Foundation

@main enum VisualizerTests {
    static func main() {
        let box = VisualizerMailbox<Int>(maxSlots: 4)
        for n in 0..<100_000 { precondition(!box.submit(slot: n % 4, state: n)) }
        precondition(box.take().isEmpty, "Invisible UI must admit no work")
        let a = UUID(), b = UUID()
        box.setSubscriber(a, visible: true); box.setSubscriber(b, visible: true)
        precondition(box.submit(slot: 0, state: 1, now: 1))
        for n in 0..<10_000 { precondition(!box.submit(slot: n % 4, state: n, now: 2)) }
        let latest = box.take()
        precondition(latest.count == 4 && latest[3] == 9999 && latest[0] == 9996)
        precondition(!box.submit(slot: -1, state: 1) && !box.submit(slot: 4, state: 1))
        precondition(box.submit(slot: 0, state: 5, now: 3)); _ = box.take()
        precondition(!box.submit(slot: 0, state: 6, now: 3.05))
        precondition(!box.submit(slot: 1, state: 6, now: 3.05), "The UI rate limit is shared across players")
        precondition(box.submit(slot: 0, state: 7, now: 3.2))
        box.setSubscriber(a, visible: false)
        precondition(box.hasSubscribers && box.take()[0] == 7)
        precondition(box.submit(slot: 0, state: 8, now: 4))
        box.setSubscriber(b, visible: false)
        precondition(!box.hasSubscribers && box.take().isEmpty)
        box.setSubscriber(a, visible: true)
        precondition(box.submit(slot: 0, state: 9, now: 4))
        precondition(box.submit(slot: 0, state: 9, now: 4) == false)
        precondition(!box.clear(slot: 0))
        precondition(box.take().isEmpty, "Retired slots must not reappear")
        precondition(box.submit(slot: 0, state: 10, now: 5))
        box.setSubscriber(a, visible: false); box.setSubscriber(a, visible: true)
        precondition(!box.submit(slot: 1, state: 11, now: 5))
        precondition(box.take() == [1: 11], "Queued tasks must read the current lifetime")
        precondition(box.clearAll()); precondition(box.take().isEmpty)
        print("PASS invisible/occluded admission policy, bounded latest UI, multiple subscribers and retirement")
    }
}
