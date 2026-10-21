import XCTest
@testable import Omni

final class RetryPolicyTests: XCTestCase {
    func testStatusToAction() {
        let table: [(Int?, RetryPolicy.Action)] = [
            (200, .success), (202, .success),
            (400, .drop), (401, .drop), (403, .drop), (404, .drop), (422, .drop),
            (413, .split),
            (408, .retry), (429, .retry),
            (500, .retry), (502, .retry), (503, .retry), (599, .retry),
            (nil, .retry), (302, .retry),
        ]
        for (status, expected) in table {
            XCTAssertEqual(RetryPolicy.action(statusCode: status), expected, "status \(String(describing: status))")
        }
    }

    func testBackoffDoublesFrom5sTo5min() {
        XCTAssertEqual((1...9).map { RetryPolicy.backoff(attempt: $0) }, [5, 10, 20, 40, 80, 160, 300, 300, 300])
        XCTAssertEqual(RetryPolicy.backoff(attempt: 1000), 300)
    }
}

final class DeliveryTests: XCTestCase {
    func testSuccessRemovesAndBatchesAtMost100() {
        let h = Harness()
        for i in 0..<250 { h.client.track("e\(i)") }
        h.client.flush()
        h.drain()
        XCTAssertEqual(h.transport.batchSizes, [100, 100, 50])
        XCTAssertEqual(h.queued.count, 0)
        XCTAssertEqual(h.transport.sentEvents.compactMap { $0["event"] as? String }, (0..<250).map { "e\($0)" })
    }

    func testFlushAtTriggersSend() {
        let h = Harness(options: Omni.Options(flushAt: 3, flushInterval: 3600, captureLifecycle: false))
        h.client.track("a")
        h.client.track("b")
        h.drain()
        XCTAssertEqual(h.transport.requests.count, 0)
        h.client.track("c")
        h.drain()
        XCTAssertEqual(h.transport.batchSizes, [3])
    }

    func testBadRequestAndBadKeyDropTheBatch() {
        let h = Harness()
        h.transport.statuses = [400]
        h.client.track("a")
        h.client.track("b")
        h.client.flush()
        XCTAssertEqual(h.queued.count, 0)

        let k = Harness()
        k.transport.statuses = [401]
        k.client.track("a")
        k.client.flush()
        XCTAssertEqual(k.queued.count, 0)
        XCTAssertEqual(k.client.retryAttempt, 0)
    }

    func testServerErrorsKeepEventsAndBackOff() {
        let h = Harness()
        h.transport.statuses = [500, 503, nil, 429]
        h.client.track("a")
        h.client.track("b")

        h.client.flush()
        h.drain()
        XCTAssertEqual(h.queued.count, 2)
        XCTAssertEqual(h.client.queue.sync { h.client.retryAttempt }, 1)
        XCTAssertEqual(h.client.queue.sync { h.client.nextRetryAt }, h.clock.now.addingTimeInterval(5))

        h.client.flush()
        h.drain()
        XCTAssertEqual(h.client.queue.sync { h.client.nextRetryAt }, h.clock.now.addingTimeInterval(10))

        h.client.flush() // network error
        h.drain()
        XCTAssertEqual(h.client.queue.sync { h.client.retryAttempt }, 3)

        h.client.flush() // 429
        h.drain()
        XCTAssertEqual(h.queued.count, 2)

        h.client.flush() // 200
        h.drain()
        XCTAssertEqual(h.queued.count, 0)
        XCTAssertEqual(h.client.queue.sync { h.client.retryAttempt }, 0)
        XCTAssertNil(h.client.queue.sync { h.client.nextRetryAt })
        XCTAssertEqual(h.transport.requests.count, 5)
    }

    func testAutomaticFlushWaitsOutTheBackoff() {
        let h = Harness(options: Omni.Options(flushAt: 2, flushInterval: 3600, captureLifecycle: false))
        h.transport.statuses = [500]
        h.client.track("a")
        h.client.track("b") // hits flushAt → 500
        h.drain()
        XCTAssertEqual(h.transport.requests.count, 1)

        h.client.track("c") // still backing off: no request
        h.drain()
        XCTAssertEqual(h.transport.requests.count, 1)

        h.clock.advance(6)
        h.client.track("d")
        h.drain()
        XCTAssertEqual(h.transport.requests.count, 2)
        XCTAssertEqual(h.queued.count, 0)
    }

    func testTooLargeHalvesTheBatch() {
        let h = Harness()
        h.transport.statuses = [413, 200, 200]
        for i in 0..<4 { h.client.track("e\(i)") }
        h.client.flush()
        h.drain()
        XCTAssertEqual(h.transport.batchSizes, [4, 2, 2])
        XCTAssertEqual(h.queued.count, 0)
    }

    func testTooLargeSingleEventIsDropped() {
        let h = Harness()
        h.transport.statuses = [413]
        h.client.track("huge")
        h.client.flush()
        h.drain()
        XCTAssertEqual(h.transport.batchSizes, [1])
        XCTAssertEqual(h.queued.count, 0)
    }

    func testQueueCapDropsOldest() {
        let queueStore = MemoryQueueStore()
        let h = Harness(options: Omni.Options(flushAt: 1000, flushInterval: 3600, maxQueue: 5, captureLifecycle: false),
                        queueStore: queueStore)
        h.transport.statuses = [500] // offline: the first send fails, later ones wait out the backoff
        for i in 0..<8 { h.client.track("e\(i)") }
        XCTAssertEqual(h.queued.map(\.event), ["e3", "e4", "e5", "e6", "e7"])
        XCTAssertEqual(queueStore.saved.map(\.event), ["e3", "e4", "e5", "e6", "e7"])
    }

    func testQueuePersistsAcrossLaunches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omni-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("omni/queue.json")

        let first = Harness(queueStore: FileQueueStore(fileURL: url))
        first.client.track("a", properties: ["n": 1])
        first.client.track("b")
        let firstQueue = first.queued
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let second = Harness(queueStore: FileQueueStore(fileURL: url))
        XCTAssertEqual(second.queued, firstQueue)

        second.client.flush()
        second.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "an empty queue removes the file")

        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(FileQueueStore(fileURL: url).load(), [])
    }
}
