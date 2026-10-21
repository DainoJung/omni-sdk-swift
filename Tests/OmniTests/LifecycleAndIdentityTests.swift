import XCTest
@testable import Omni

final class LifecycleAndIdentityTests: XCTestCase {
    private let lifecycle = Omni.Options(flushAt: 1000, flushInterval: 3600, captureLifecycle: true)

    func testInstallThenSameVersionThenUpdate() throws {
        let storage = MemoryStore()

        let first = Harness(options: lifecycle, storage: storage)
        first.client.start(appInBackground: false)
        let firstEvents = first.queued
        XCTAssertEqual(firstEvents.map(\.event), ["$app_installed", "$app_opened"])
        XCTAssertEqual(firstEvents[0].properties, ["version": .string("1.4.0"), "build": .string("52")])
        XCTAssertEqual(firstEvents[1].properties, ["from_background": .bool(false)])

        let second = Harness(options: lifecycle, storage: storage)
        second.client.start(appInBackground: false)
        XCTAssertEqual(second.queued.map(\.event), ["$app_opened"])

        var newBuild = Harness.device
        newBuild.build = "53"
        let third = Harness(options: lifecycle, storage: storage, device: newBuild)
        third.client.start(appInBackground: false)
        let thirdEvents = third.queued
        XCTAssertEqual(thirdEvents.map(\.event), ["$app_updated", "$app_opened"])
        XCTAssertEqual(thirdEvents[0].properties, [
            "version": .string("1.4.0"), "build": .string("53"),
            "previous_version": .string("1.4.0"), "previous_build": .string("52"),
        ])

        var newVersion = Harness.device
        newVersion.appVersion = "1.5.0"
        newVersion.build = "53"
        let fourth = Harness(options: lifecycle, storage: storage, device: newVersion)
        fourth.client.start(appInBackground: false)
        XCTAssertEqual(fourth.queued.first?.properties["previous_version"], .string("1.4.0"))
    }

    func testLifecycleOffSendsNothingButRemembersVersion() {
        let storage = MemoryStore()
        let h = Harness(storage: storage)
        h.client.start(appInBackground: false)
        h.client.appDidEnterBackground(completion: nil)
        h.client.appDidBecomeActive()
        XCTAssertEqual(h.allEventNames, [])
        XCTAssertEqual(storage.string(StoreKey.lastBuild), "52")
    }

    func testAppOpenedFromBackground() {
        let h = Harness(options: lifecycle)
        h.client.start(appInBackground: false)
        h.drain()
        h.client.appDidBecomeActive() // launch activation: already counted at cold start
        h.client.appDidEnterBackground(completion: nil)
        h.client.appDidBecomeActive()
        h.client.appDidBecomeActive() // e.g. after Control Center: not a new open
        XCTAssertEqual(h.allEventNames, ["$app_installed", "$app_opened", "$app_opened"])
        let lastOpen = h.client.queue.sync { h.client.events.last?.properties["from_background"] }
            ?? (h.transport.sentEvents.last?["properties"] as? [String: Bool])?["from_background"].map(JSONValue.bool)
        XCTAssertEqual(lastOpen, .bool(true))
    }

    func testLaunchedInBackgroundWaitsForOpen() {
        let h = Harness(options: lifecycle)
        h.client.start(appInBackground: true)
        XCTAssertEqual(h.allEventNames, ["$app_installed"])
        h.client.appDidBecomeActive()
        XCTAssertEqual(h.queued.last?.properties, ["from_background": .bool(false)])
    }

    func testBackgroundFlushCallsCompletion() {
        let h = Harness()
        h.client.track("a")
        let done = expectation(description: "flush done")
        h.client.appDidEnterBackground { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(h.transport.batchSizes, [1])
    }

    func testResetGivesNewAnonIdAndClearsUser() throws {
        let h = Harness()
        let oldAnon = h.client.anonymousId
        h.client.identify("user_1", traits: [:])
        h.client.track("before")
        h.client.reset()
        XCTAssertNotEqual(h.client.anonymousId, oldAnon)
        XCTAssertNil(h.client.userId)
        XCTAssertEqual(h.storage.string(StoreKey.anonId), h.client.anonymousId)
        XCTAssertNil(h.storage.string(StoreKey.userId))
        h.client.track("after")

        let events = h.queued
        let before = try XCTUnwrap(events.first { $0.event == "before" })
        let after = try XCTUnwrap(events.first { $0.event == "after" })
        XCTAssertEqual(before.anonId, oldAnon)
        XCTAssertEqual(before.userId, "user_1")
        XCTAssertEqual(after.anonId, h.client.anonymousId)
        XCTAssertNil(after.userId)
        XCTAssertNotEqual(before.context.sessionId, after.context.sessionId)
    }

    func testAnonIdPersistsAcrossLaunches() {
        let storage = MemoryStore()
        let a = Harness(storage: storage).client.anonymousId
        let b = Harness(storage: storage).client.anonymousId
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, a.lowercased())
    }

    func testOptOutDropsAndStops() {
        let storage = MemoryStore()
        let queueStore = MemoryQueueStore()
        let h = Harness(storage: storage, queueStore: queueStore)
        h.client.track("a")
        h.client.track("b")
        XCTAssertEqual(h.queued.count, 2)

        h.client.optOut()
        XCTAssertTrue(h.client.isOptedOut)
        XCTAssertEqual(h.queued.count, 0)
        XCTAssertEqual(queueStore.saved.count, 0)

        h.client.track("c")
        h.client.identify("u", traits: [:])
        h.client.flush()
        XCTAssertEqual(h.queued.count, 0)
        XCTAssertEqual(h.transport.requests.count, 0)

        // Remembered across launches.
        let relaunched = Harness(storage: storage)
        XCTAssertTrue(relaunched.client.isOptedOut)
        relaunched.client.track("d")
        XCTAssertEqual(relaunched.queued.count, 0)

        relaunched.client.optIn()
        relaunched.client.track("e")
        XCTAssertEqual(relaunched.queued.map(\.event), ["e"])
        XCTAssertFalse(Harness(storage: storage).client.isOptedOut)
    }

    func testSessionRotatesAfterThirtyMinutesIdle() {
        let h = Harness()
        h.client.track("a")
        h.drain()
        h.clock.advance(29 * 60)
        h.client.track("b")
        h.drain()
        h.clock.advance(31 * 60)
        h.client.track("c")
        let s = h.queued.map { $0.context.sessionId }
        XCTAssertEqual(s[0], s[1])
        XCTAssertNotEqual(s[1], s[2])
    }

    func testSessionRotatesAfterThirtyMinutesInBackground() {
        let h = Harness(options: lifecycle)
        h.transport.statuses = [500, 500] // keep events queued so we can read them
        h.client.start(appInBackground: false)
        h.drain()
        h.client.appDidEnterBackground(completion: nil)
        h.drain()
        h.clock.advance(10 * 60)
        h.client.appDidBecomeActive()
        h.drain()
        h.client.appDidEnterBackground(completion: nil)
        h.drain()
        h.clock.advance(31 * 60)
        h.client.appDidBecomeActive()
        let opens = h.queued.filter { $0.event == "$app_opened" }
        XCTAssertEqual(opens.count, 3)
        XCTAssertEqual(opens[0].context.sessionId, opens[1].context.sessionId)
        XCTAssertNotEqual(opens[1].context.sessionId, opens[2].context.sessionId)
    }

    func testSessionContinuesAcrossQuickRelaunch() {
        let storage = MemoryStore()
        let clock = TestClock()
        let first = Harness(storage: storage, clock: clock)
        first.client.track("a")
        let s1 = first.queued[0].context.sessionId
        clock.advance(60)
        let second = Harness(storage: storage, clock: clock)
        second.client.track("b")
        XCTAssertEqual(second.queued.last?.context.sessionId, s1)
    }
}
