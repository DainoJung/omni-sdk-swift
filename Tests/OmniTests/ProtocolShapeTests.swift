import XCTest
@testable import Omni

final class ProtocolShapeTests: XCTestCase {
    private let isoPattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#

    private func assertISO(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) {
        guard let s = value as? String else { return XCTFail("not a string: \(String(describing: value))", file: file, line: line) }
        XCTAssertNotNil(s.range(of: isoPattern, options: .regularExpression), "not ISO 8601 with ms: \(s)", file: file, line: line)
    }

    private func assertLowercaseUUID(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) {
        guard let s = value as? String else { return XCTFail("not a string", file: file, line: line) }
        XCTAssertEqual(s, s.lowercased(), file: file, line: line)
        XCTAssertNotNil(UUID(uuidString: s), file: file, line: line)
    }

    func testBatchBodyMatchesProtocol() throws {
        let h = Harness()
        h.client.track("lesson_completed", properties: ["lesson": 3])
        h.client.flush()
        h.drain()

        XCTAssertEqual(h.transport.requests.count, 1)
        let request = try XCTUnwrap(h.transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.omnigrowth.app/v1/batch")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(h.transport.bodies.first)
        XCTAssertEqual(Set(body.keys), ["key", "sent_at", "batch"])
        XCTAssertEqual(body["key"] as? String, "opk_test")
        assertISO(body["sent_at"])

        let batch = try XCTUnwrap(body["batch"] as? [[String: Any]])
        XCTAssertEqual(batch.count, 1)
        let event = batch[0]
        XCTAssertEqual(Set(event.keys), ["uuid", "event", "ts", "anon_id", "user_id", "properties", "context"])
        assertLowercaseUUID(event["uuid"])
        XCTAssertEqual(event["event"] as? String, "lesson_completed")
        assertISO(event["ts"])
        XCTAssertEqual(event["ts"] as? String, Timestamp.string(from: h.clock.now))
        XCTAssertEqual(event["anon_id"] as? String, h.client.anonymousId)
        XCTAssertTrue(event["user_id"] is NSNull, "user_id must be an explicit null before identify")
        XCTAssertEqual(event["properties"] as? [String: Int], ["lesson": 3])

        let context = try XCTUnwrap(event["context"] as? [String: Any])
        XCTAssertEqual(Set(context.keys), ["app_version", "build", "platform", "device_type", "locale",
                                           "os_version", "device_model", "session_id", "sdk"])
        XCTAssertEqual(context["app_version"] as? String, "1.4.0")
        XCTAssertEqual(context["build"] as? String, "52")
        XCTAssertEqual(context["platform"] as? String, "ios")
        XCTAssertEqual(context["device_type"] as? String, "phone")
        XCTAssertEqual(context["locale"] as? String, "ko-KR")
        XCTAssertEqual(context["os_version"] as? String, "26.1")
        XCTAssertEqual(context["device_model"] as? String, "iPhone17,3")
        XCTAssertEqual(context["sdk"] as? String, "omni-swift/0.1.0")
        assertLowercaseUUID(context["session_id"])
    }

    func testIdentityEvents() throws {
        let h = Harness()
        let anon = h.client.anonymousId
        h.client.identify("user_42", traits: ["plan": "pro"])
        h.client.setEmail("a@b.co", consent: true)
        h.client.setBillingId("rc_abc")
        h.client.setTraits(["age_group": "20s"])
        h.client.screen("Paywall", properties: ["variant": "b"])
        h.client.track("after_identify")
        h.client.flush()
        h.drain()

        let events = h.transport.sentEvents
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$identify", "$set", "$set", "$set", "$screen", "after_identify"])

        // $identify: both ids set, traits in identity, no properties.
        let identify = events[0]
        XCTAssertEqual(identify["user_id"] as? String, "user_42")
        XCTAssertEqual(identify["anon_id"] as? String, anon)
        XCTAssertEqual((identify["properties"] as? [String: Any])?.count, 0)
        XCTAssertEqual(identify["identity"] as? [String: [String: String]], ["traits": ["plan": "pro"]])

        // setEmail → traits email + email_consent.
        let email = try XCTUnwrap((events[1]["identity"] as? [String: Any])?["traits"] as? [String: Any])
        XCTAssertEqual(email["email"] as? String, "a@b.co")
        XCTAssertEqual(email["email_consent"] as? Bool, true)

        // setBillingId → identity.billing_id only.
        XCTAssertEqual(events[2]["identity"] as? [String: String], ["billing_id": "rc_abc"])
        XCTAssertEqual(events[3]["identity"] as? [String: [String: String]], ["traits": ["age_group": "20s"]])

        // $screen carries the name; regular events have no identity.
        XCTAssertEqual(events[4]["properties"] as? [String: String], ["name": "Paywall", "variant": "b"])
        XCTAssertNil(events[5]["identity"])
        XCTAssertEqual(events[5]["user_id"] as? String, "user_42")

        // The user id survives a relaunch.
        let relaunched = Harness(storage: h.storage)
        XCTAssertEqual(relaunched.client.userId, "user_42")
        XCTAssertEqual(relaunched.client.anonymousId, anon)
    }

    func testEventNameRules() {
        let h = Harness()
        h.client.track("")
        h.client.track("   ")
        h.client.track("$app_opened")
        h.client.track(String(repeating: "x", count: 201))
        h.client.track(String(repeating: "y", count: 200))
        XCTAssertEqual(h.queued.map(\.event), [String(repeating: "y", count: 200)])
    }

    func testQueueFileRoundTripKeepsNullUserId() throws {
        let event = Event(uuid: "u", event: "e", ts: "t", anonId: "a", userId: nil,
                          properties: ["n": .int(1)], context: EventContext(sessionId: "s"), identity: nil)
        let data = try JSONEncoder().encode([event])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertTrue(json[0]["user_id"] is NSNull)
        XCTAssertEqual(try JSONDecoder().decode([Event].self, from: data), [event])
    }
}
