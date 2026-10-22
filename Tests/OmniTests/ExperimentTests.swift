import XCTest
@testable import Omni

final class AssignmentTests: XCTestCase {
    /// sdk/test-vectors.json, copied here so the package tests on its own (its repo has no sdk/ folder).
    static let vectors: [(input: String, hash: UInt32, bucket: Int, index5050: Int, index103060: Int)] = [
        ("paywall_headline:00000000-0000-0000-0000-000000000000", 4_186_208_400, 8400, 1, 2),
        ("onboarding_v2:6f1c2d3e-4b5a-4c6d-8e7f-0123456789ab", 3_481_007_406, 7406, 1, 2),
        ("x:a", 3_070_346_514, 6514, 1, 2),
        ("exp_6:a6a3a450-6513-270e-269e-0d37f2a74de4", 2_605_997_556, 7556, 1, 2),
        ("exp_1:1818e811-892f-902b-d23f-0824128b2f33", 3_607_646_409, 6409, 1, 2),
        ("exp_6:81e74ef5-e8e2-5d94-0ed9-04759531985d", 3_554_096_528, 6528, 1, 2),
        ("exp_4:6b0d549b-6f03-675a-1600-a35a099950d8", 658_485_148, 5148, 1, 2),
        ("exp_2:6cad4a26-8d11-6ece-1738-f7d93d9c1724", 3_464_504_351, 4351, 0, 2),
        ("exp_4:f29d0da9-953f-48f1-a09f-76b5a170b338", 1_052_393_823, 3823, 0, 1),
        ("exp_9:7731af10-506b-f2ef-c6f8-77186d76b07e", 2_042_750_113, 113, 0, 0),
    ]

    func testVectors() {
        for v in AssignmentTests.vectors {
            XCTAssertEqual(Assignment.fnv1a32(v.input), v.hash, v.input)
            let colon = v.input.firstIndex(of: ":")!
            let bucket = Assignment.bucket(experiment: String(v.input[..<colon]),
                                           bucketId: String(v.input[v.input.index(after: colon)...]))
            XCTAssertEqual(bucket, v.bucket, v.input)
            XCTAssertEqual(Assignment.variantIndex(weights: [50, 50], bucket: bucket), v.index5050, v.input)
            XCTAssertEqual(Assignment.variantIndex(weights: [10, 30, 60], bucket: bucket), v.index103060, v.input)
        }
    }

    /// In the monorepo, the copy above must match the shared file every SDK tests.
    func testVectorsMatchSharedFile() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("test-vectors.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("no sdk/test-vectors.json outside the monorepo") }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let shared = try XCTUnwrap(json["fnv1a32"] as? [[String: Any]])
        XCTAssertEqual(shared.count, AssignmentTests.vectors.count)
        for (s, v) in zip(shared, AssignmentTests.vectors) {
            XCTAssertEqual(s["input"] as? String, v.input)
            XCTAssertEqual((s["fnv1a32"] as? NSNumber)?.uint32Value, v.hash)
            XCTAssertEqual(s["bucket"] as? Int, v.bucket)
            XCTAssertEqual(s["variant_index_50_50"] as? Int, v.index5050)
            XCTAssertEqual(s["variant_index_10_30_60"] as? Int, v.index103060)
        }
    }

    func testUTF8AndEmpty() {
        XCTAssertEqual(Assignment.fnv1a32(""), 2_166_136_261)
        // Bytes, not characters: "é" is two UTF-8 bytes.
        XCTAssertNotEqual(Assignment.fnv1a32("é"), Assignment.fnv1a32("e"))
        XCTAssertEqual(Assignment.fnv1a32("é"), Assignment.fnv1a32(String(decoding: [0xC3, 0xA9], as: UTF8.self)))
    }

    func testWeightEdges() {
        // Slices in floating point: thirds are 0–3333.33, –6666.67, –10000.
        XCTAssertEqual(Assignment.variantIndex(weights: [1, 1, 1], bucket: 3333), 0)
        XCTAssertEqual(Assignment.variantIndex(weights: [1, 1, 1], bucket: 3334), 1)
        XCTAssertEqual(Assignment.variantIndex(weights: [1, 1, 1], bucket: 9999), 2)
        XCTAssertEqual(Assignment.variantIndex(weights: [0, 1], bucket: 0), 1)
        XCTAssertEqual(Assignment.variantIndex(weights: [1, 0], bucket: 9999), 0)
        XCTAssertNil(Assignment.variantIndex(weights: [], bucket: 0))
        XCTAssertNil(Assignment.variantIndex(weights: [0, 0], bucket: 0))
        XCTAssertEqual(Assignment.variantIndex(weights: [-5, 1], bucket: 0), 1)
    }
}

final class ExperimentTests: XCTestCase {
    /// With this bucket id, `paywall_headline` lands in bucket 8400 (test vectors): `b` at 50/50.
    private let bucketId = "00000000-0000-0000-0000-000000000000"

    private func config(_ experiments: String, ttl: Int = 300) -> (status: Int, body: String)? {
        (200, #"{"experiments":[\#(experiments)],"ttl":\#(ttl)}"#)
    }

    private let paywall = #"""
    {"key":"paywall_headline","variants":[{"key":"control","weight":50,"payload":{}},
     {"key":"b","weight":50,"payload":{"headline":"Remember every word you meet","trial_days":7}}],
     "audience":{},"winner":null}
    """#

    /// A client on a fresh install whose config fetch at start answered `response`.
    private func started(_ response: (status: Int, body: String)?, storage: MemoryStore = MemoryStore(),
                         clock: TestClock = TestClock(), device: DeviceInfo = Harness.device) -> Harness {
        if storage.string(StoreKey.bucketId) == nil { storage.set(bucketId, forKey: StoreKey.bucketId) }
        let transport = MockTransport()
        transport.configResponses = [response]
        let h = Harness(storage: storage, transport: transport, clock: clock, device: device)
        h.client.start(appInBackground: false)
        h.drain()
        return h
    }

    private func exposures(_ h: Harness) -> [[String: JSONValue]] {
        h.allEvents.filter { $0.event == "$exposure" }.map(\.properties)
    }

    func testVariantAndPayloadFromTheConfig() {
        let h = started(config(paywall))
        XCTAssertEqual(h.client.experimentVariant("paywall_headline")?.key, "b")
        XCTAssertEqual(h.client.experimentVariant("paywall_headline")?.payload, [
            "headline": .string("Remember every word you meet"), "trial_days": .int(7),
        ])
        XCTAssertNil(h.client.experimentVariant("not_listed"))
        XCTAssertEqual(exposures(h), [["experiment": .string("paywall_headline"), "variant": .string("b")]])
    }

    func testConfigRequest() throws {
        let h = started(config(paywall))
        let request = try XCTUnwrap(h.transport.configRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.omnigrowth.app/v1/config?key=opk_test")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertTrue(h.transport.requests.isEmpty, "fetching the config sends no events")
    }

    func testNothingBeforeTheConfigLoads() {
        let h = started(nil) // network error, no copy on the device
        XCTAssertNil(h.client.experimentVariant("paywall_headline"))
        XCTAssertEqual(exposures(h), [])
    }

    func testExposureOncePerSession() {
        let h = started(config(paywall))
        for _ in 0..<5 { _ = h.client.experimentVariant("paywall_headline") }
        h.client.track("other")
        _ = h.client.experimentVariant("paywall_headline")
        XCTAssertEqual(exposures(h).count, 1)

        // 31 idle minutes: a new session, so a new exposure.
        h.clock.advance(31 * 60)
        _ = h.client.experimentVariant("paywall_headline")
        _ = h.client.experimentVariant("paywall_headline")
        let events = h.allEvents.filter { $0.event == "$exposure" }
        XCTAssertEqual(events.count, 2)
        XCTAssertNotEqual(events[0].context.sessionId, events[1].context.sessionId)
    }

    func testExposureNotRepeatedAfterRelaunchInTheSameSession() {
        let storage = MemoryStore()
        let clock = TestClock()
        let first = started(config(paywall), storage: storage, clock: clock)
        _ = first.client.experimentVariant("paywall_headline")
        XCTAssertEqual(exposures(first).count, 1)

        clock.advance(60)
        let second = Harness(storage: storage, clock: clock)
        XCTAssertEqual(second.client.experimentVariant("paywall_headline")?.key, "b", "the copy on the device, before any fetch")
        XCTAssertEqual(exposures(second).count, 0)
    }

    func testOptedOutStillGetsTheVariantButSendsNothing() {
        let h = started(config(paywall))
        h.client.optOut()
        XCTAssertEqual(h.client.experimentVariant("paywall_headline")?.key, "b")
        XCTAssertEqual(h.allEventNames, [])
    }

    func testResetKeepsTheVariantAndStartsANewSession() {
        let h = started(config(paywall))
        _ = h.client.experimentVariant("paywall_headline")
        h.client.reset()
        XCTAssertEqual(h.client.experimentVariant("paywall_headline")?.key, "b")
        XCTAssertEqual(h.storage.string(StoreKey.bucketId), bucketId)
        let events = h.allEvents.filter { $0.event == "$exposure" }
        XCTAssertEqual(events.count, 2)
        XCTAssertNotEqual(events[0].anonId, events[1].anonId)
    }

    func testAudiencePlatforms() {
        let android = paywall.replacingOccurrences(of: #""audience":{}"#, with: #""audience":{"platforms":["android"]}"#)
        XCTAssertNil(started(config(android)).client.experimentVariant("paywall_headline"))

        let apple = paywall.replacingOccurrences(of: #""audience":{}"#, with: #""audience":{"platforms":["ios","ipados"]}"#)
        XCTAssertEqual(started(config(apple)).client.experimentVariant("paywall_headline")?.key, "b")

        var iPad = Harness.device
        iPad.platform = "ipados"
        XCTAssertEqual(started(config(apple), device: iPad).client.experimentVariant("paywall_headline")?.key, "b")
    }

    func testAudienceNewUsersSince() {
        let clock = TestClock() // first launch happens at clock.now
        func since(_ date: Date) -> String {
            paywall.replacingOccurrences(of: #""audience":{}"#,
                                         with: #""audience":{"new_users_since":"\#(Timestamp.string(from: date))"}"#)
        }
        // Installed after the experiment started: in.
        XCTAssertEqual(started(config(since(clock.now.addingTimeInterval(-60))), clock: clock)
            .client.experimentVariant("paywall_headline")?.key, "b")
        // At the very moment: in.
        XCTAssertEqual(started(config(since(clock.now)), clock: clock).client.experimentVariant("paywall_headline")?.key, "b")
        // Installed before: out.
        XCTAssertNil(started(config(since(clock.now.addingTimeInterval(60))), clock: clock)
            .client.experimentVariant("paywall_headline"))

        // An install that ran before the SDK kept its first launch: old, so out.
        let old = MemoryStore()
        old.set("1.3.0", forKey: StoreKey.lastVersion)
        old.set("40", forKey: StoreKey.lastBuild)
        let h = started(config(since(clock.now.addingTimeInterval(-86400))), storage: old, clock: clock)
        XCTAssertNil(h.client.firstLaunch)
        XCTAssertNil(h.client.experimentVariant("paywall_headline"))

        // Not a date: nobody is in.
        let garbled = paywall.replacingOccurrences(of: #""audience":{}"#, with: #""audience":{"new_users_since":"soon"}"#)
        XCTAssertNil(started(config(garbled), clock: clock).client.experimentVariant("paywall_headline"))
    }

    func testFirstLaunchIsKeptOnTheFirstLaunchOnly() {
        let storage = MemoryStore()
        let clock = TestClock()
        let first = Harness(options: Omni.Options(flushAt: 1000, flushInterval: 3600, captureLifecycle: true),
                            storage: storage, clock: clock)
        first.client.start(appInBackground: false)
        XCTAssertEqual(first.allEventNames.first, "$app_installed")
        XCTAssertEqual(first.client.firstLaunch, clock.now)

        clock.advance(86400)
        let second = Harness(storage: storage, clock: clock)
        XCTAssertEqual(second.client.firstLaunch, clock.now.addingTimeInterval(-86400))
    }

    func testWinnerGoesToEveryoneWithoutExposures() {
        let decided = paywall.replacingOccurrences(of: #""winner":null"#, with: #""winner":"control""#)
            .replacingOccurrences(of: #""audience":{}"#, with: #""audience":{"platforms":["ios"],"new_users_since":"2099-01-01T00:00:00.000Z"}"#)
        let h = started(config(decided))
        // Bucket 8400 would be `b`, and this device isn't a new user: the winner goes to it anyway.
        XCTAssertEqual(h.client.experimentVariant("paywall_headline")?.key, "control")
        XCTAssertEqual(h.client.experimentVariant("paywall_headline")?.payload, [:])
        XCTAssertEqual(exposures(h), [])

        var android = Harness.device
        android.platform = "android"
        XCTAssertNil(started(config(decided), device: android).client.experimentVariant("paywall_headline"))
    }

    func testConfigIsRefreshedOnForegroundOnlyWhenOlderThanTTL() {
        let h = started(config(paywall, ttl: 300))
        XCTAssertEqual(h.transport.configRequests.count, 1)

        h.clock.advance(299)
        h.client.appDidBecomeActive()
        h.drain()
        XCTAssertEqual(h.transport.configRequests.count, 1)

        h.clock.advance(1)
        h.client.appDidBecomeActive()
        h.drain()
        XCTAssertEqual(h.transport.configRequests.count, 2)
    }

    func testConfigIsAlwaysFetchedAtStart() {
        let storage = MemoryStore()
        let clock = TestClock()
        XCTAssertEqual(started(config(paywall), storage: storage, clock: clock).transport.configRequests.count, 1)
        clock.advance(10)
        XCTAssertEqual(started(config(paywall), storage: storage, clock: clock).transport.configRequests.count, 1)
    }

    func testFailedFetchKeepsTheLastCopy() {
        let storage = MemoryStore()
        let clock = TestClock()
        _ = started(config(paywall), storage: storage, clock: clock)
        clock.advance(3600)
        for failure: (status: Int, body: String)? in [nil, (500, "oops"), (200, "not json"), (401, #"{"error":"bad key"}"#)] {
            let h = started(failure, storage: storage, clock: clock)
            XCTAssertEqual(h.client.experimentVariant("paywall_headline")?.key, "b")
        }
        // A good answer replaces it, even with nothing running.
        let h = started(config(""), storage: storage, clock: clock)
        XCTAssertNil(h.client.experimentVariant("paywall_headline"))
        XCTAssertEqual(Harness(storage: storage, clock: clock).client.config?.experiments, [])
    }

    func testLenientConfig() throws {
        let body = #"""
        {"experiments":[
          {"key":"broken","variants":"nope"},
          {"key":"ok","variants":[{"key":"a","weight":1},{"key":"b","weight":1,"payload":{"n":1}}],"winner":null,"new_field":true}
        ],"something_new":1}
        """#
        let config = try JSONDecoder().decode(ExperimentConfig.self, from: Data(body.utf8))
        XCTAssertEqual(config.experiments.map(\.key), ["ok"])
        XCTAssertEqual(config.experiments[0].variants[0].payload, [:])
        XCTAssertEqual(config.ttl, 300)
    }

    func testLoadExperimentsWaitsForTheFetch() async {
        let transport = MockTransport()
        transport.holdConfig = true
        let storage = MemoryStore()
        storage.set(bucketId, forKey: StoreKey.bucketId)
        let h = Harness(storage: storage, transport: transport)
        h.client.start(appInBackground: false)

        let answered = expectation(description: "config answered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            transport.answerConfig(status: 200, body: #"{"experiments":[\#(self.paywall)],"ttl":300}"#)
            answered.fulfill()
        }
        await h.client.loadExperiments(timeout: 5)
        await fulfillment(of: [answered], timeout: 1)
        XCTAssertEqual(h.client.experimentVariant("paywall_headline")?.key, "b")
        XCTAssertEqual(transport.configRequests.count, 1, "joins the fetch started at configure")

        // Fresh copy: resolves at once without fetching again.
        await h.client.loadExperiments(timeout: 5)
        XCTAssertEqual(transport.configRequests.count, 1)
    }

    func testLoadExperimentsGivesUpAfterTheTimeout() async {
        let transport = MockTransport()
        transport.holdConfig = true
        let h = Harness(transport: transport)
        let started = Date()
        await h.client.loadExperiments(timeout: 0.2)
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, 0.15)
        XCTAssertLessThan(waited, 2)
        XCTAssertNil(h.client.experimentVariant("paywall_headline"))
    }

    func testPayloadValues() {
        let v: JSONValue = .object(["s": .string("x"), "i": .int(7), "d": .double(1.5), "b": .bool(true), "a": .array([.int(1)])])
        let o = v.objectValue!
        XCTAssertEqual(o["s"]?.stringValue, "x")
        XCTAssertEqual(o["i"]?.intValue, 7)
        XCTAssertEqual(o["i"]?.doubleValue, 7)
        XCTAssertEqual(o["d"]?.intValue, nil)
        XCTAssertEqual(o["b"]?.boolValue, true)
        XCTAssertEqual(o["a"]?.arrayValue, [.int(1)])
        let any = v.anyValue as? [String: Any]
        XCTAssertEqual(any?["i"] as? Int, 7)
        XCTAssertEqual(any?["s"] as? String, "x")
    }
}
