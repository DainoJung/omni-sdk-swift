import Foundation
@testable import Omni

final class MemoryStore: KeyValueStore {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func string(_ key: String) -> String? { get(key) as? String }
    func bool(_ key: String) -> Bool { (get(key) as? Bool) ?? false }
    func double(_ key: String) -> Double? { get(key) as? Double }

    func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    private func get(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
}

final class MemoryQueueStore: QueueStore {
    var saved: [Event] = []
    var saveCount = 0

    func load() -> [Event] { saved }
    func save(_ events: [Event]) {
        saved = events
        saveCount += 1
    }
}

/// Records requests and answers them synchronously. `statuses` are used in order (nil = network
/// error); once empty every request gets 200. Config fetches are kept apart: `configRequests`, answered from
/// `configResponses` in order (nil = network error), then 404; or held until `answerConfig` when `holdConfig` is on.
final class MockTransport: Transport {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var statuses: [Int?] = []
    private(set) var configRequests: [URLRequest] = []
    var configResponses: [(status: Int, body: String)?] = []
    var holdConfig = false
    private var held: [(Int?, Data?, Error?) -> Void] = []

    func fetch(_ request: URLRequest, completion: @escaping (Int?, Data?, Error?) -> Void) {
        lock.lock()
        configRequests.append(request)
        if holdConfig {
            held.append(completion)
            lock.unlock()
            return
        }
        let response: (status: Int, body: String)?? = configResponses.isEmpty ? .some((404, "")) : configResponses.removeFirst()
        lock.unlock()
        switch response {
        case .some(.some(let r)): completion(r.status, Data(r.body.utf8), nil)
        default: completion(nil, nil, URLError(.notConnectedToInternet))
        }
    }

    /// Answers the config fetches held so far.
    func answerConfig(status: Int, body: String) {
        lock.lock()
        let waiting = held
        held = []
        lock.unlock()
        waiting.forEach { $0(status, Data(body.utf8), nil) }
    }

    func send(_ request: URLRequest, completion: @escaping (Int?, Error?) -> Void) {
        lock.lock()
        requests.append(request)
        let status: Int? = statuses.isEmpty ? 200 : statuses.removeFirst()
        lock.unlock()
        completion(status, status == nil ? URLError(.notConnectedToInternet) : nil)
    }

    var bodies: [[String: Any]] {
        requests.compactMap { req in
            req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    /// Every event sent, in order.
    var sentEvents: [[String: Any]] {
        bodies.flatMap { ($0["batch"] as? [[String: Any]]) ?? [] }
    }

    var batchSizes: [Int] {
        bodies.map { ($0["batch"] as? [Any])?.count ?? 0 }
    }
}

final class TestClock {
    var now = Date(timeIntervalSince1970: 1_792_400_000) // 2026-10-21

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

struct Harness {
    let storage: MemoryStore
    let queueStore: QueueStore
    let transport: MockTransport
    let clock: TestClock
    let client: OmniClient

    static let device = DeviceInfo(
        appVersion: "1.4.0",
        build: "52",
        platform: "ios",
        deviceType: "phone",
        locale: "ko-KR",
        osVersion: "26.1",
        deviceModel: "iPhone17,3"
    )

    init(options: Omni.Options = Omni.Options(flushAt: 1000, flushInterval: 3600, captureLifecycle: false),
         storage: MemoryStore = MemoryStore(),
         queueStore: QueueStore = MemoryQueueStore(),
         transport: MockTransport = MockTransport(),
         clock: TestClock = TestClock(),
         device: DeviceInfo = Harness.device,
         pushPermission: PushPermissionReader? = nil,
         pushCategories: PushCategoryRegistrar? = nil,
         timeZone: @escaping () -> String = { TimeZone.current.identifier }) {
        self.storage = storage
        self.queueStore = queueStore
        self.transport = transport
        self.clock = clock
        client = OmniClient(
            key: "opk_test",
            options: options.normalized,
            endpoint: options.batchURL!,
            storage: storage,
            queueStore: queueStore,
            transport: transport,
            device: device,
            pushPermission: pushPermission,
            pushCategories: pushCategories,
            now: { clock.now },
            timeZone: timeZone
        )
    }

    /// Lets every queued block (including chained sends) run.
    func drain() {
        for _ in 0..<30 { client.queue.sync {} }
    }

    var queued: [Event] {
        drain()
        return client.queue.sync { client.events }
    }

    /// Sent and still-queued events, in order.
    var allEvents: [Event] {
        drain()
        let sent = transport.requests.compactMap { req in
            req.httpBody.flatMap { try? JSONDecoder().decode(SentBody.self, from: $0) }
        }.flatMap(\.batch)
        return sent + client.queue.sync { client.events }
    }

    /// Sent and still-queued event names, in order.
    var allEventNames: [String] {
        drain()
        return transport.sentEvents.compactMap { $0["event"] as? String } + client.queue.sync { client.events.map(\.event) }
    }
}

/// The part of a sent body tests read back as `Event`s.
private struct SentBody: Decodable {
    let batch: [Event]
}
