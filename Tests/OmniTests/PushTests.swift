import XCTest
@testable import Omni

final class PushTests: XCTestCase {
    private let token = Data([0x0a, 0xff, 0x00, 0x7b])

    private func pushTokens(_ h: Harness) -> [Event] {
        h.allEvents.filter { $0.event == "$push_token" }
    }

    func testTokenIsHex() {
        XCTAssertEqual(Push.hex(token), "0aff007b")
        XCTAssertEqual(Push.hex(Data()), "")
    }

    func testTokenEventShape() throws {
        let h = Harness()
        h.client.setPushToken("0aff007b", provider: "apns", environment: "sandbox", topic: "com.example.app")
        let event = try XCTUnwrap(pushTokens(h).first)
        XCTAssertEqual(event.properties, [
            "token": .string("0aff007b"), "provider": .string("apns"),
            "environment": .string("sandbox"), "topic": .string("com.example.app"),
        ])
        XCTAssertEqual(event.anonId, h.client.anonymousId)
    }

    func testTokenSentOnChangeOrWeekly() {
        let storage = MemoryStore()
        let clock = TestClock()
        let h = Harness(storage: storage, clock: clock)
        let set = { (token: String, env: String) in h.client.setPushToken(token, provider: "apns", environment: env, topic: "app") }

        set("aa", "production")
        set("aa", "production") // same: nothing
        XCTAssertEqual(pushTokens(h).count, 1)

        // Every launch calls it again; a relaunch a day later doesn't resend.
        clock.advance(86400)
        let relaunched = Harness(storage: storage, clock: clock)
        relaunched.client.setPushToken("aa", provider: "apns", environment: "production", topic: "app")
        XCTAssertEqual(pushTokens(relaunched).count, 0)

        // A week after it was sent: again.
        clock.advance(6 * 86400 - 1)
        set("aa", "production")
        XCTAssertEqual(pushTokens(h).count, 1)
        clock.advance(1)
        set("aa", "production")
        XCTAssertEqual(pushTokens(h).count, 2)

        set("bb", "production") // new token
        set("bb", "sandbox")    // new environment
        XCTAssertEqual(pushTokens(h).map { $0.properties["token"] }, [.string("aa"), .string("aa"), .string("bb"), .string("bb")])
        XCTAssertEqual(pushTokens(h).last?.properties["environment"], .string("sandbox"))
    }

    func testResetMovesTheTokenToTheNewPerson() {
        let h = Harness()
        h.client.identify("user_1", traits: [:])
        h.client.setPushToken("aa", provider: "apns", environment: "production", topic: "app")
        h.client.reset()
        let tokens = pushTokens(h)
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].userId, "user_1")
        XCTAssertNil(tokens[1].userId)
        XCTAssertEqual(tokens[1].anonId, h.client.anonymousId)
        XCTAssertEqual(tokens[1].properties["token"], .string("aa"))
    }

    func testOptedOutTokenIsSentAfterOptIn() {
        let h = Harness()
        h.client.optOut()
        h.client.setPushToken("aa", provider: "apns", environment: "production", topic: "app")
        XCTAssertEqual(pushTokens(h).count, 0)
        h.client.optIn()
        h.client.setPushToken("aa", provider: "apns", environment: "production", topic: "app")
        XCTAssertEqual(pushTokens(h).count, 1)
    }

    func testPermissionAtStartAndWhenItChangesOnForeground() {
        let status = Box("not_determined")
        let storage = MemoryStore()
        let reader: PushPermissionReader = { $0(status.value) }
        let h = Harness(storage: storage, pushPermission: reader)
        h.client.start(appInBackground: false)
        h.client.appDidBecomeActive()
        h.client.appDidEnterBackground(completion: nil)
        h.client.appDidBecomeActive() // unchanged: nothing
        status.value = "authorized"
        h.client.appDidBecomeActive()
        XCTAssertEqual(h.allEvents.filter { $0.event == "$push_permission" }.map { $0.properties["status"] },
                       [.string("not_determined"), .string("authorized")])

        // Remembered across launches: a relaunch with the same status sends nothing.
        let relaunched = Harness(storage: storage, pushPermission: reader)
        relaunched.client.start(appInBackground: false)
        XCTAssertEqual(relaunched.allEventNames, [])
    }

    func testANewTokenCarriesThePermissionAlreadySeen() {
        let h = Harness(pushPermission: { $0("denied") })
        h.client.start(appInBackground: false)
        h.client.setPushToken("aa", provider: "apns", environment: "production", topic: "app")
        XCTAssertEqual(h.allEventNames, ["$push_permission", "$push_token", "$push_permission"])
    }

    func testPushOpened() throws {
        let h = Harness()
        h.client.pushOpened(messageId: "m_1")
        let event = try XCTUnwrap(h.allEvents.first)
        XCTAssertEqual(event.event, "$push_opened")
        XCTAssertEqual(event.properties, ["message_id": .string("m_1")])
    }

    func testOmniMessageParsing() {
        let apns: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Hi"]],
            "omni": ["message_id": "m_1", "url": "scribo://words/42"],
        ]
        XCTAssertEqual(Push.omniMessage(apns)?.messageId, "m_1")
        XCTAssertEqual(Push.omniMessage(apns)?.url, URL(string: "scribo://words/42"))

        // As it comes from UserNotifications: Foundation dictionaries.
        let bridged = NSDictionary(dictionary: ["omni": NSDictionary(dictionary: ["message_id": "m_2"])]) as! [AnyHashable: Any]
        XCTAssertEqual(Push.omniMessage(bridged)?.messageId, "m_2")
        XCTAssertNil(Push.omniMessage(bridged)?.url)

        XCTAssertNil(Push.omniMessage(["aps": ["alert": "not ours"]]))
        XCTAssertNil(Push.omniMessage(["omni": ["url": "https://x.test"]]))
        XCTAssertNil(Push.omniMessage(["omni": ["message_id": ""]]))
        XCTAssertNil(Push.omniMessage(["omni": "m_1"]))
        XCTAssertNil(Push.omniMessage(["omni": ["message_id": "m_3", "url": ""]])?.url)
    }

    func testTrackPushOpenedReturnsTheLinkBeforeConfigureToo() {
        XCTAssertEqual(Omni.trackPushOpened(["omni": ["message_id": "m_1", "url": "https://s.test/a"]]),
                       URL(string: "https://s.test/a"))
        XCTAssertNil(Omni.trackPushOpened(["aps": [:]]))
    }

    // MARK: Environment from the provisioning profile

    private func profile(_ entitlements: String) -> Data {
        var data = Data([0x30, 0x82, 0x1f, 0x00, 0x06, 0x09]) // CMS envelope bytes before the plist
        data.append(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Name</key><string>Dev</string>
        <key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
        """.utf8))
        data.append(Data([0xa0, 0x82, 0x0d, 0x00])) // signature after it
        return data
    }

    func testEnvironmentFromProfile() {
        XCTAssertEqual(Push.environment(profile: profile("<key>aps-environment</key><string>development</string>")), "sandbox")
        XCTAssertEqual(Push.environment(profile: profile("<key>aps-environment</key><string>production</string>")), "production")
        XCTAssertEqual(Push.environment(profile: profile("<key>com.apple.developer.aps-environment</key><string>development</string>")), "sandbox")
        XCTAssertEqual(Push.environment(profile: profile("<key>get-task-allow</key><true/>")), "production")
        XCTAssertEqual(Push.environment(profile: Data("garbage".utf8)), "production")
        // No profile: App Store / TestFlight.
        XCTAssertEqual(Push.environment(profile: nil), "production")
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
