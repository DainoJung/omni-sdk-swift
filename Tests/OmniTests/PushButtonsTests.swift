import XCTest
#if canImport(UserNotifications)
import UserNotifications
#endif
@testable import Omni

final class PushButtonsTests: XCTestCase {
    private let review = #"""
    {"id":"omni_7f3a2c","actions":[{"id":"b1","title":"Review now","url":"scribo://review","foreground":true},
                                   {"id":"b2","title":"Later","foreground":false}]}
    """#

    private func config(_ categories: String) -> (status: Int, body: String)? {
        (200, #"{"experiments":[],"push_categories":[\#(categories)],"ttl":300}"#)
    }

    // MARK: Config

    func testCategoriesDecoded() throws {
        let config = try JSONDecoder().decode(ExperimentConfig.self, from: Data(config(review)!.body.utf8))
        XCTAssertEqual(config.pushCategories, [PushCategory(id: "omni_7f3a2c", actions: [
            PushAction(id: "b1", title: "Review now", url: URL(string: "scribo://review"), foreground: true),
            PushAction(id: "b2", title: "Later", foreground: false),
        ])])
    }

    func testLenientCategories() throws {
        let body = #"""
        {"experiments":[{"key":"ok","variants":[{"key":"a","weight":1}]}],
         "push_categories":[
           {"id":"omni_broken","actions":"nope"},
           {"id":"not_ours","actions":[{"id":"b1","title":"Hi"}]},
           {"id":"omni_","actions":[]},
           {"actions":[]},
           "garbage",
           {"id":"omni_ok","actions":[{"id":"b1","title":"Open","url":"scribo://x"},
                                      {"id":"","title":"No id"},
                                      {"id":"b3"},
                                      {"id":"b4","title":"Quiet","url":"","foreground":"yes"}],"new_field":1},
           {"id":"omni_ok","actions":[]}
         ],"ttl":60}
        """#
        let config = try JSONDecoder().decode(ExperimentConfig.self, from: Data(body.utf8))
        XCTAssertEqual(config.experiments.map(\.key), ["ok"], "a bad category never costs the experiments")
        XCTAssertEqual(config.ttl, 60)
        XCTAssertEqual(config.pushCategories, [PushCategory(id: "omni_ok", actions: [
            // No `foreground`: a button with a link opens the app.
            PushAction(id: "b1", title: "Open", url: URL(string: "scribo://x"), foreground: true),
            PushAction(id: "b4", title: "Quiet", url: nil, foreground: false),
        ])])

        // Not a list at all: no categories, the rest stays.
        let odd = try JSONDecoder().decode(ExperimentConfig.self, from: Data(#"{"experiments":[],"push_categories":{"id":"omni_x"}}"#.utf8))
        XCTAssertEqual(odd.pushCategories, [])
        XCTAssertEqual(try JSONDecoder().decode(ExperimentConfig.self, from: Data(#"{"experiments":[]}"#.utf8)).pushCategories, [])
    }

    // MARK: When categories are registered

    func testRegisteredFromTheCopyAtStartAndAfterEachFetch() {
        let storage = MemoryStore()
        let clock = TestClock()
        let registered = Box<[[String]]>([])
        let registrar: PushCategoryRegistrar = { registered.value.append($0.map(\.id)) }

        // First launch: nothing on the device yet, so only the fetched config is registered.
        let transport = MockTransport()
        transport.configResponses = [config(review)]
        let first = Harness(storage: storage, transport: transport, clock: clock, pushCategories: registrar)
        first.client.start(appInBackground: false)
        first.drain()
        XCTAssertEqual(registered.value, [["omni_7f3a2c"]])

        // Next launch: the copy right away, then the fetch; a failed fetch registers nothing.
        registered.value = []
        clock.advance(3600)
        let failing = MockTransport()
        failing.configResponses = [nil, (500, "oops"), config(#"{"id":"omni_new","actions":[]}"#)]
        let second = Harness(storage: storage, transport: failing, clock: clock, pushCategories: registrar)
        second.client.start(appInBackground: false)
        second.drain()
        XCTAssertEqual(registered.value, [["omni_7f3a2c"]])
        second.client.refreshConfig(force: true)
        second.drain()
        XCTAssertEqual(registered.value, [["omni_7f3a2c"]])
        second.client.refreshConfig(force: true)
        second.drain()
        XCTAssertEqual(registered.value, [["omni_7f3a2c"], ["omni_new"]])

        // Kept with the config copy.
        XCTAssertEqual(Harness(storage: storage, clock: clock).client.config?.pushCategories.map(\.id), ["omni_new"])
    }

    #if canImport(UserNotifications) && !os(watchOS) && !os(tvOS)

    // MARK: Registering with the system

    /// Stands in for `UNUserNotificationCenter`'s categories.
    private final class Center {
        var categories: Set<UNNotificationCategory>
        var setCount = 0
        init(_ categories: Set<UNNotificationCategory>) { self.categories = categories }

        func register(_ omni: [PushCategory]) {
            SystemPushCategories.register(omni, get: { $0(self.categories) },
                                          set: { self.categories = $0; self.setCount += 1 })
        }

        var ids: Set<String> { Set(categories.map(\.identifier)) }
        func category(_ id: String) -> UNNotificationCategory? { categories.first { $0.identifier == id } }
    }

    private let appCategory = UNNotificationCategory(
        identifier: "MESSAGE",
        actions: [UNNotificationAction(identifier: "reply", title: "Reply", options: [.foreground])],
        intentIdentifiers: [], options: [])

    private let reviewCategory = PushCategory(id: "omni_7f3a2c", actions: [
        PushAction(id: "b1", title: "Review now", url: URL(string: "scribo://review"), foreground: true),
        PushAction(id: "b2", title: "Later", foreground: false),
    ])

    func testRegistrationKeepsTheAppsCategoriesAndReplacesOnlyOmnis() throws {
        let stale = UNNotificationCategory(identifier: "omni_old", actions: [], intentIdentifiers: [], options: [])
        let center = Center([appCategory, stale])
        center.register([reviewCategory])

        XCTAssertEqual(center.setCount, 1)
        XCTAssertEqual(center.ids, ["MESSAGE", "omni_7f3a2c"])
        XCTAssertTrue(center.category("MESSAGE") === appCategory, "the app's own category is kept as it was")
        let actions = try XCTUnwrap(center.category("omni_7f3a2c")?.actions)
        XCTAssertEqual(actions.map(\.identifier), ["b1", "b2"])
        XCTAssertEqual(actions.map(\.title), ["Review now", "Later"])
        XCTAssertEqual(actions.map { $0.options.contains(.foreground) }, [true, false])

        // No categories in the config any more: Omni's go, the app's stay.
        center.register([])
        XCTAssertEqual(center.ids, ["MESSAGE"])
        XCTAssertEqual(center.setCount, 2)
    }

    func testRegistrationSkippedWhenOmnisAreUnchanged() {
        let center = Center([appCategory])
        center.register([reviewCategory])
        center.register([reviewCategory])
        XCTAssertEqual(center.setCount, 1)

        // Only a link changed: what the system shows is the same, and the link is read when the push is opened.
        var relinked = reviewCategory
        relinked.actions[0].url = URL(string: "scribo://elsewhere")
        center.register([relinked])
        XCTAssertEqual(center.setCount, 1)

        // A title changed: registered again.
        var renamed = reviewCategory
        renamed.actions[1].title = "Not now"
        center.register([renamed])
        XCTAssertEqual(center.setCount, 2)
        XCTAssertEqual(center.category("omni_7f3a2c")?.actions.map(\.title), ["Review now", "Not now"])

        // Nothing of Omni's either way: nothing to set.
        let untouched = Center([appCategory])
        untouched.register([])
        XCTAssertEqual(untouched.setCount, 0)
    }

    func testRegistrationPutsOmnisBackAfterTheAppReplacedTheSet() {
        let center = Center([])
        center.register([reviewCategory])
        center.categories = [appCategory] // the app called setNotificationCategories with only its own
        center.register([reviewCategory])
        XCTAssertEqual(center.ids, ["MESSAGE", "omni_7f3a2c"])
    }

    // MARK: Opening

    private let push: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "Hi"], "category": "omni_7f3a2c"],
        "omni": ["message_id": "m_1", "url": "scribo://words/42"],
    ]

    private func opened(_ action: String, category: String = "omni_7f3a2c", userInfo: [AnyHashable: Any]? = nil,
                        categories: [PushCategory]? = nil) -> (messageId: String, action: String, url: URL?)? {
        Push.opened(actionIdentifier: action, categoryIdentifier: category, userInfo: userInfo ?? push,
                    categories: categories ?? [reviewCategory])
    }

    func testOpenedActionAndURL() {
        // The notification itself: `open`, the push's link.
        XCTAssertEqual(opened(UNNotificationDefaultActionIdentifier)?.action, "open")
        XCTAssertEqual(opened(UNNotificationDefaultActionIdentifier)?.url, URL(string: "scribo://words/42"))
        XCTAssertEqual(opened(UNNotificationDefaultActionIdentifier)?.messageId, "m_1")

        // A button: its id, its own link.
        XCTAssertEqual(opened("b1")?.action, "b1")
        XCTAssertEqual(opened("b1")?.url, URL(string: "scribo://review"))

        // A background button without a link opens nothing, but still counts.
        XCTAssertEqual(opened("b2")?.action, "b2")
        XCTAssertNil(opened("b2")?.url)

        // A foreground button without a link: the push's.
        let noLink = PushCategory(id: "omni_7f3a2c", actions: [PushAction(id: "b1", title: "Go", foreground: true)])
        XCTAssertEqual(opened("b1", categories: [noLink])?.url, URL(string: "scribo://words/42"))

        // The category isn't in the config (not loaded, or gone since): the push's link.
        XCTAssertEqual(opened("b1", categories: [])?.url, URL(string: "scribo://words/42"))
        XCTAssertEqual(opened("b1", category: "omni_other")?.url, URL(string: "scribo://words/42"))

        // Dismissals aren't opens; other pushes aren't Omni's.
        XCTAssertNil(opened(UNNotificationDismissActionIdentifier))
        XCTAssertNil(opened(UNNotificationDefaultActionIdentifier, userInfo: ["aps": ["alert": "not ours"]]))
        XCTAssertNil(opened("b1", userInfo: ["aps": ["category": "omni_7f3a2c"]]))
    }

    func testTrackPushOpenedFromAResponse() throws {
        let transport = MockTransport()
        transport.configResponses = [config(review)]
        let h = Harness(transport: transport)
        h.client.start(appInBackground: false)
        h.drain()

        let track = { (action: String) in
            Omni.trackPushOpened(actionIdentifier: action, categoryIdentifier: "omni_7f3a2c", userInfo: self.push, client: h.client)
        }
        XCTAssertEqual(track("b1"), URL(string: "scribo://review"))
        XCTAssertEqual(track(UNNotificationDefaultActionIdentifier), URL(string: "scribo://words/42"))
        XCTAssertNil(track(UNNotificationDismissActionIdentifier))
        XCTAssertNil(Omni.trackPushOpened(actionIdentifier: "b1", categoryIdentifier: "omni_7f3a2c",
                                          userInfo: ["aps": [:]], client: h.client))

        let opens = h.allEvents.filter { $0.event == "$push_opened" }.map(\.properties)
        XCTAssertEqual(opens, [
            ["message_id": .string("m_1"), "action": .string("b1")],
            ["message_id": .string("m_1"), "action": .string("open")],
        ])
    }

    func testTrackPushOpenedFromAResponseBeforeConfigure() {
        XCTAssertEqual(Omni.trackPushOpened(actionIdentifier: "b1", categoryIdentifier: "omni_7f3a2c", userInfo: push),
                       URL(string: "scribo://words/42"))
    }
    #endif
}
