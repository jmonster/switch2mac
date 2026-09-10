import Foundation

@main
enum MailboxTests {
    static func main() {
        orderedAndSingleSchedule()
        overflowRequiresRecovery()
        staleRequiresRecovery()
        clearRetiresSlot()
        roundRobinDoesNotStarveOtherSlot()
        print("PASS bounded state mailbox")
    }

    static func orderedAndSingleSchedule() {
        let box = BoundedStateMailbox<Int>(perSlotCapacity: 4, maxAge: 1, batchLimit: 8)
        precondition(box.submit(slot: 0, state: 1, now: 0))
        precondition(!box.submit(slot: 0, state: 2, now: 0))
        let batch = box.take(now: 0.1)
        precondition(batch.items.map(\.state) == [1, 2])
        precondition(batch.recoveries.isEmpty)
        precondition(!box.completeDrain())
        precondition(box.submit(slot: 0, state: 3, now: 0.2))
    }

    static func overflowRequiresRecovery() {
        let box = BoundedStateMailbox<Int>(perSlotCapacity: 2, maxAge: 1, batchLimit: 8)
        _ = box.submit(slot: 1, state: 10, now: 0)
        _ = box.submit(slot: 1, state: 11, now: 0)
        _ = box.submit(slot: 1, state: 12, now: 0)
        _ = box.submit(slot: 1, state: 13, now: 0)
        let batch = box.take(now: 0.1)
        precondition(batch.items.isEmpty)
        precondition(batch.recoveries.count == 1)
        precondition(batch.recoveries[0].slot == 1 && batch.recoveries[0].latest == 13)
    }

    static func staleRequiresRecovery() {
        let box = BoundedStateMailbox<Int>(perSlotCapacity: 8, maxAge: 0.25, batchLimit: 8)
        _ = box.submit(slot: 2, state: 20, now: 1)
        _ = box.submit(slot: 2, state: 21, now: 1.1)
        let batch = box.take(now: 1.4)
        precondition(batch.items.isEmpty)
        precondition(batch.recoveries.map(\.latest) == [21])
    }

    static func clearRetiresSlot() {
        let box = BoundedStateMailbox<Int>()
        _ = box.submit(slot: 0, state: 1, now: 0)
        _ = box.submit(slot: 1, state: 2, now: 0)
        box.clear(slot: 0)
        let batch = box.take(now: 0.1)
        precondition(batch.items.map(\.slot) == [1])
    }

    static func roundRobinDoesNotStarveOtherSlot() {
        let box = BoundedStateMailbox<Int>(perSlotCapacity: 8, maxAge: 1, batchLimit: 3)
        for n in 0..<5 { _ = box.submit(slot: 0, state: n, now: 0) }
        _ = box.submit(slot: 1, state: 99, now: 0)
        let batch = box.take(now: 0.1)
        precondition(batch.items.map(\.slot) == [0, 1, 0])
        precondition(box.completeDrain())
    }
}
