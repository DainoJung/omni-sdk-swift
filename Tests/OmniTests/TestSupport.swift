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
/// error); once empty every request gets 200.
final class MockTransport: Transport {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var statuses: [Int?] = []

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
         device: DeviceInfo = Harness.device) {
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
            now: { clock.now }
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

    /// Sent and still-queued event names, in order.
    var allEventNames: [String] {
        drain()
        return transport.sentEvents.compactMap { $0["event"] as? String } + client.queue.sync { client.events.map(\.event) }
    }
}
