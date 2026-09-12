import Foundation
import Synchronization
import XCTest
@testable import Switch2Kit

final class ObservationTests: XCTestCase {
    private func controller(_ lifetime: SessionLifetime, id: Switch2ControllerID = .init(rawValue: UUID()),
                            sequence: UInt64 = 1) -> Switch2Controller {
        .init(id: id, model: .proController2, state: .init(buttons: .a, sequence: sequence),
              connectedAt: Date(timeIntervalSince1970: 0), bodyColor: nil, buttonColor: nil,
              serialNumber: nil, sessionGeneration: lifetime.id, lastActivityAt: 0)
    }

    func testInitialSnapshotDoesNotSkipAlreadyQueuedInput() throws {
        let queue = DispatchQueue(label: "test.observation.fifo")
        queue.suspend()
        let hub = ControllerEventHub(), lifetime = SessionLifetime()
        let reports = Mutex<[UInt64]>([])
        let observation = try hub.observe(queue: queue, capacity: 256) { event in
            if case .input(let controller) = event { reports.withLock { $0.append(controller.state.sequence) } }
        }
        for sequence in 1...100 {
            let controller = controller(lifetime, sequence: UInt64(sequence))
            hub.publish(.init(controllers: [controller]), event: .input(controller), lifetime: lifetime)
        }
        queue.resume(); queue.sync {}
        for _ in 0..<8 { queue.sync {} }
        XCTAssertEqual(reports.withLock { $0 }, Array(UInt64(1)...100))
        observation.cancel()
    }

    func testSlowObserverReceivesOneAuthoritativeResynchronization() throws {
        let queue = DispatchQueue(label: "test.observation.overflow")
        queue.suspend()
        let hub = ControllerEventHub(), lifetime = SessionLifetime()
        let values = Mutex<[Switch2ControllerEvent]>([])
        let observation = try hub.observe(queue: queue, capacity: 4) { event in values.withLock { $0.append(event) } }
        let id = Switch2ControllerID(rawValue: UUID())
        for sequence in 1...10_000 {
            let value = controller(lifetime, id: id, sequence: UInt64(sequence))
            hub.publish(.init(controllers: [value]), event: .input(value), lifetime: lifetime)
        }
        queue.resume(); queue.sync {}; queue.sync {}
        let events = values.withLock { $0 }
        XCTAssertEqual(events.count, 1)
        guard case .snapshot(let snapshot) = events.first else { return XCTFail("Overflow must resynchronize, not silently lose retirement") }
        XCTAssertEqual(snapshot.controllers.first?.state.sequence, 10_000)
        observation.cancel()
    }

    func testQueuedInputAndReadySnapshotsCannotResurrectRetiredAttempt() throws {
        let queue = DispatchQueue(label: "test.observation.retirement")
        queue.suspend()
        let hub = ControllerEventHub(), lifetime = SessionLifetime()
        let value = controller(lifetime)
        hub.publish(.init(controllers: [value]), event: .connected(value), lifetime: lifetime)
        let delivered = Mutex<[Switch2ControllerEvent]>([])
        let observation = try hub.observe(queue: queue, capacity: 64) { event in delivered.withLock { $0.append(event) } }
        hub.publish(.init(controllers: [value]), event: .input(value), lifetime: lifetime)
        lifetime.retire()
        hub.publish(.init(), event: .disconnected(value.id, .requested))
        queue.resume(); queue.sync {}; queue.sync {}
        for event in delivered.withLock({ $0 }) {
            switch event {
            case .input, .connected: XCTFail("Retired input escaped its generation fence")
            case .snapshot(let state), .status(let state): XCTAssertTrue(state.controllers.isEmpty)
            default: break
            }
        }
        observation.cancel()
    }

    func testCancellationAndObserverAdmissionAreBounded() throws {
        let queue = DispatchQueue(label: "test.observation.cancel")
        queue.suspend()
        let hub = ControllerEventHub(), calls = Mutex(0)
        var observations: [Switch2ControllerObservation] = []
        for _ in 0..<32 {
            observations.append(try hub.observe(queue: queue, capacity: 1) { _ in calls.withLock { $0 += 1 } })
        }
        XCTAssertThrowsError(try hub.observe(queue: queue, capacity: 1) { _ in }) { error in
            XCTAssertEqual(error as? Switch2KitError, .observerLimitReached)
        }
        observations.forEach { $0.cancel(); $0.cancel() }
        queue.resume(); queue.sync {}
        XCTAssertEqual(calls.withLock { $0 }, 0)
        let replacement = try hub.observe(queue: queue, capacity: 1) { _ in }
        replacement.cancel()
    }

    func testMailboxStorageIsBoundedOnConcurrentDeliveryQueue() {
        let queue = DispatchQueue(label: "test.observation.concurrent", attributes: .concurrent)
        queue.suspend()
        let mailbox = EventMailbox(capacity: 8, queue: queue, current: {
            EventEnvelope(sequence: 10_001, event: .snapshot(.init()), lifetime: nil)
        }, handler: { _ in })
        for sequence in 1...10_000 {
            mailbox.enqueue(.init(sequence: UInt64(sequence), event: .status(.init()), lifetime: nil))
            XCTAssertLessThanOrEqual(mailbox.pendingCount, 8)
        }
        mailbox.cancel(); queue.resume()
        queue.sync(flags: .barrier) {}
        XCTAssertEqual(mailbox.pendingCount, 0)
    }

    func testConfigurationRetainsOnlyBoundedDistinctIdentities() {
        let ids = (0..<100).map { _ in Switch2ControllerID(rawValue: UUID()) }
        let configuration = Switch2ControllerConfiguration(rememberedControllers: ids + ids, maximumControllers: 8)
        XCTAssertEqual(configuration.rememberedControllers, Array(ids.prefix(8)))
        XCTAssertFalse(configuration.includeSerialNumbers)
    }
}
