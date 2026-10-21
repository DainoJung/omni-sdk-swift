import Foundation

/// The engine behind the `Omni` facade. Identity (anon_id, user_id, opt-out) is guarded by a lock so
/// it can be read from any thread and snapshotted at call time; everything else (queue, session,
/// sending) is confined to one serial background queue.
final class OmniClient {
    static let sessionTimeout: TimeInterval = 30 * 60
    static let maxBatchSize = 100
    static let maxBodyBytes = 500_000
    static let maxEventNameLength = 200

    let key: String
    let options: Omni.Options
    let endpoint: URL
    let log: Log
    let queue = DispatchQueue(label: "app.omnigrowth.sdk", qos: .utility)

    private let storage: KeyValueStore
    private let queueStore: QueueStore
    private let transport: Transport
    private let device: DeviceInfo
    private let now: () -> Date
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    // Identity — guarded by `lock`.
    private let lock = NSLock()
    private var _anonId: String
    private var _userId: String?
    private var _optedOut: Bool
    private var screens = ScreenDeduper()

    // Queue-confined state.
    private(set) var events: [Event] = []
    private(set) var sessionId: String?
    private var lastActivity: Date?
    private var backgroundedAt: Date?
    private var wasBackgrounded = false
    private var coldOpenPending = false
    private var isSending = false
    private var batchLimit = OmniClient.maxBatchSize
    private(set) var retryAttempt = 0
    private(set) var nextRetryAt: Date?
    private var retryWork: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var flushCompletions: [() -> Void] = []

    init(key: String,
         options: Omni.Options,
         endpoint: URL,
         storage: KeyValueStore,
         queueStore: QueueStore,
         transport: Transport,
         device: DeviceInfo,
         now: @escaping () -> Date = Date.init) {
        self.key = key
        self.options = options
        self.endpoint = endpoint
        self.log = Log(enabled: options.debug)
        self.storage = storage
        self.queueStore = queueStore
        self.transport = transport
        self.device = device
        self.now = now

        _anonId = OmniClient.storedAnonId(storage)
        _userId = storage.string(StoreKey.userId)
        _optedOut = storage.bool(StoreKey.optedOut)
        sessionId = storage.string(StoreKey.sessionId)
        lastActivity = storage.double(StoreKey.sessionLastActivity).map(Date.init(timeIntervalSince1970:))

        // Load the persisted queue off the caller's thread; it's the first block on the queue,
        // so anything tracked meanwhile lands after it.
        let optedOut = _optedOut
        queue.async { [self] in
            let loaded = queueStore.load()
            if optedOut {
                if !loaded.isEmpty { queueStore.save([]) }
                return
            }
            events = loaded
            if events.count > options.maxQueue {
                events.removeFirst(events.count - options.maxQueue)
                queueStore.save(events)
            }
            if !events.isEmpty { log("restored \(events.count) queued events") }
        }
    }

    deinit {
        timer?.cancel()
        retryWork?.cancel()
    }

    /// The persisted anon_id, created (and persisted) on first use.
    static func storedAnonId(_ storage: KeyValueStore) -> String {
        if let id = storage.string(StoreKey.anonId), !id.isEmpty { return id }
        let id = newId()
        storage.set(id, forKey: StoreKey.anonId)
        return id
    }

    static func newId() -> String { UUID().uuidString.lowercased() }

    // MARK: Identity

    var anonymousId: String { locked { _anonId } }
    var userId: String? { locked { _userId } }
    var isOptedOut: Bool { locked { _optedOut } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Public operations (any thread)

    func track(_ name: String, properties: [String: Any] = [:]) {
        guard let name = validName(name) else { return }
        if name.hasPrefix("$") {
            log("ignored track(\"\(name)\"): names starting with $ are Omni's own")
            return
        }
        capture(name, properties: Sanitizer.properties(properties, log: log))
    }

    func screen(_ name: String, properties: [String: Any] = [:]) {
        var props = Sanitizer.properties(properties, log: log)
        props["name"] = .string(name)
        locked { screens.record(name) }
        capture("$screen", properties: props)
    }

    /// `$screen` for a screen the SDK saw appear. Skipped when it's the same screen as just before, and for
    /// automatic ones when `captureScreens` is off.
    func observedScreen(_ name: String, auto: Bool) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !auto || options.captureScreens else { return }
        guard locked({ screens.shouldSend(name) }) else { return }
        capture("$screen", properties: ["name": .string(name), "auto": .bool(auto)])
    }

    func identify(_ userId: String, traits: [String: Any]) {
        let userId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userId.isEmpty else {
            log("ignored identify: empty user id")
            return
        }
        let traits = Sanitizer.properties(traits, log: log)
        locked { _userId = userId }
        storage.set(userId, forKey: StoreKey.userId)
        capture("$identify", identity: traits.isEmpty ? nil : Identity(billingId: nil, traits: traits))
    }

    func setTraits(_ traits: [String: Any]) {
        let traits = Sanitizer.properties(traits, log: log)
        guard !traits.isEmpty else {
            log("ignored setTraits: no encodable traits")
            return
        }
        capture("$set", identity: Identity(billingId: nil, traits: traits))
    }

    func setEmail(_ email: String, consent: Bool) {
        setTraits(["email": email, "email_consent": consent])
    }

    func setBillingId(_ id: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            log("ignored setBillingId: empty id")
            return
        }
        capture("$set", identity: Identity(billingId: id, traits: nil))
    }

    func reset() {
        let anon = OmniClient.newId()
        locked {
            _anonId = anon
            _userId = nil
            screens = ScreenDeduper()
        }
        storage.set(anon, forKey: StoreKey.anonId)
        storage.set(nil, forKey: StoreKey.userId)
        queue.async { [self] in
            sessionId = nil // the next event starts a new session
            log("reset: new anon_id \(anon)")
        }
    }

    /// `$delete_user` carries the ids as they are now, so Omni can find everything about this person; then a fresh start.
    func deleteUser() {
        capture("$delete_user")
        reset()
        flush()
    }

    func optOut() {
        locked { _optedOut = true }
        storage.set(true, forKey: StoreKey.optedOut)
        queue.async { [self] in
            events.removeAll()
            queueStore.save([])
            retryWork?.cancel()
            retryWork = nil
            nextRetryAt = nil
            retryAttempt = 0
            log("opted out: queue cleared, collection stopped")
        }
    }

    func optIn() {
        locked { _optedOut = false }
        storage.set(false, forKey: StoreKey.optedOut)
        log("opted in")
    }

    /// Sends everything queued now (ignores backoff). `completion` runs on the SDK queue when the
    /// queue is empty or a send failed.
    func flush(completion: (() -> Void)? = nil) {
        queue.async { [self] in flushOnQueue(force: true, completion: completion) }
    }

    // MARK: Lifecycle

    /// Cold start: install/update detection, the first `$app_opened`, and the flush timer.
    func start(appInBackground: Bool) {
        queue.async { [self] in
            detectInstallOrUpdate()
            if options.captureLifecycle {
                if appInBackground {
                    coldOpenPending = true
                } else {
                    captureOnQueue("$app_opened", properties: ["from_background": .bool(false)])
                }
            }
            startTimer()
        }
    }

    func appDidBecomeActive() {
        queue.async { [self] in
            if let since = backgroundedAt, now().timeIntervalSince(since) >= OmniClient.sessionTimeout {
                sessionId = nil
            }
            backgroundedAt = nil
            let coldOpen = coldOpenPending
            let fromBackground = wasBackgrounded
            coldOpenPending = false
            wasBackgrounded = false
            guard options.captureLifecycle else { return }
            if coldOpen {
                captureOnQueue("$app_opened", properties: ["from_background": .bool(false)])
            } else if fromBackground {
                captureOnQueue("$app_opened", properties: ["from_background": .bool(true)])
            }
        }
    }

    func appDidEnterBackground(completion: (() -> Void)?) {
        queue.async { [self] in
            backgroundedAt = now()
            wasBackgrounded = true
            flushOnQueue(force: true, completion: completion)
        }
    }

    private func detectInstallOrUpdate() {
        let version = device.appVersion ?? ""
        let build = device.build ?? ""
        let previousVersion = storage.string(StoreKey.lastVersion)
        let previousBuild = storage.string(StoreKey.lastBuild)
        if options.captureLifecycle {
            if previousVersion == nil && previousBuild == nil {
                captureOnQueue("$app_installed", properties: ["version": .string(version), "build": .string(build)])
            } else if previousVersion != version || previousBuild != build {
                captureOnQueue("$app_updated", properties: [
                    "version": .string(version),
                    "build": .string(build),
                    "previous_version": .string(previousVersion ?? ""),
                    "previous_build": .string(previousBuild ?? ""),
                ])
            }
        }
        storage.set(version, forKey: StoreKey.lastVersion)
        storage.set(build, forKey: StoreKey.lastBuild)
    }

    // MARK: Capture

    private func validName(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            log("ignored event with an empty name")
            return nil
        }
        if name.count > OmniClient.maxEventNameLength {
            log("ignored event \"\(name.prefix(40))…\": names are at most \(OmniClient.maxEventNameLength) characters")
            return nil
        }
        return name
    }

    /// Snapshots time and identity now, then queues the event in order.
    func capture(_ name: String, properties: [String: JSONValue] = [:], identity: Identity? = nil) {
        let ts = now()
        let (anon, user, optedOut) = locked { (_anonId, _userId, _optedOut) }
        if optedOut {
            log("opted out: dropped \(name)")
            return
        }
        queue.async { [self] in
            enqueue(name, properties: properties, identity: identity, ts: ts, anonId: anon, userId: user)
        }
    }

    /// `capture` for code already on the SDK queue (lifecycle), so those events keep their place.
    private func captureOnQueue(_ name: String, properties: [String: JSONValue]) {
        let (anon, user, optedOut) = locked { (_anonId, _userId, _optedOut) }
        guard !optedOut else { return }
        enqueue(name, properties: properties, identity: nil, ts: now(), anonId: anon, userId: user)
    }

    private func enqueue(_ name: String, properties: [String: JSONValue], identity: Identity?,
                         ts: Date, anonId: String, userId: String?) {
        enqueue(Event(
            uuid: OmniClient.newId(),
            event: name,
            ts: Timestamp.string(from: ts),
            anonId: anonId,
            userId: userId,
            properties: properties,
            context: context(at: ts),
            identity: identity
        ))
    }

    private func context(at ts: Date) -> EventContext {
        if sessionId == nil || lastActivity.map({ ts.timeIntervalSince($0) >= OmniClient.sessionTimeout }) ?? true {
            sessionId = OmniClient.newId()
            storage.set(sessionId, forKey: StoreKey.sessionId)
        }
        lastActivity = ts
        storage.set(ts.timeIntervalSince1970, forKey: StoreKey.sessionLastActivity)
        return EventContext(
            appVersion: device.appVersion,
            build: device.build,
            platform: device.platform,
            deviceType: device.deviceType,
            locale: device.locale,
            osVersion: device.osVersion,
            deviceModel: device.deviceModel,
            sessionId: sessionId,
            sdk: "omni-swift/\(Omni.sdkVersion)"
        )
    }

    private func enqueue(_ event: Event) {
        events.append(event)
        if events.count > options.maxQueue {
            let overflow = events.count - options.maxQueue
            events.removeFirst(overflow)
            log("queue full (\(options.maxQueue)): dropped \(overflow) oldest event(s)")
        }
        queueStore.save(events)
        log("queued \(event.event) (\(events.count) waiting)")
        if events.count >= options.flushAt {
            flushOnQueue(force: false)
        }
    }

    // MARK: Sending (SDK queue only)

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = options.flushInterval
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in
            guard let self, !self.events.isEmpty else { return }
            self.flushOnQueue(force: false)
        }
        t.resume()
        timer = t
    }

    /// `force` ignores the backoff window (explicit flush, going to background, the retry itself).
    private func flushOnQueue(force: Bool, completion: (() -> Void)? = nil) {
        if let completion { flushCompletions.append(completion) }
        if isSending { return } // completions run when the current send cycle ends
        if !force, let next = nextRetryAt, now() < next {
            finishFlush()
            return
        }
        sendNextBatch()
    }

    private func sendNextBatch() {
        guard !isOptedOut, !events.isEmpty else {
            finishFlush()
            return
        }
        var count = min(batchLimit, events.count, OmniClient.maxBatchSize)
        var body: Data?
        while true {
            body = try? encoder.encode(BatchBody(key: key, sentAt: Timestamp.string(from: now()), batch: Array(events.prefix(count))))
            if let b = body, b.count > OmniClient.maxBodyBytes, count > 1 {
                count = max(1, count / 2)
                continue
            }
            break
        }
        let ids = Set(events.prefix(count).map(\.uuid))
        guard let body else {
            log("couldn't encode \(count) event(s); dropped them")
            remove(ids)
            sendNextBatch()
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("omni-swift/\(Omni.sdkVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        request.timeoutInterval = 30

        isSending = true
        log("sending \(count) event(s)")
        transport.send(request) { [weak self] status, error in
            guard let self else { return }
            self.queue.async { self.handleResponse(status: status, error: error, ids: ids, count: count) }
        }
    }

    private func handleResponse(status: Int?, error: Error?, ids: Set<String>, count: Int) {
        isSending = false
        switch RetryPolicy.action(statusCode: status) {
        case .success:
            remove(ids)
            retryAttempt = 0
            nextRetryAt = nil
            retryWork?.cancel()
            retryWork = nil
            batchLimit = min(OmniClient.maxBatchSize, batchLimit * 2)
            log("sent \(count) event(s)")
            sendNextBatch()
        case .drop:
            remove(ids)
            if status == 401 {
                log("HTTP 401: the key was rejected; dropped \(count) event(s). Check the key passed to Omni.configure.")
                finishFlush()
            } else {
                log("HTTP \(status ?? 0): the server rejected the batch; dropped \(count) event(s)")
                sendNextBatch()
            }
        case .split:
            if count <= 1 {
                remove(ids)
                log("HTTP 413: a single event is too large; dropped it")
            } else {
                batchLimit = max(1, count / 2)
                log("HTTP 413: retrying in batches of \(batchLimit)")
            }
            sendNextBatch()
        case .retry:
            retryAttempt += 1
            let delay = RetryPolicy.backoff(attempt: retryAttempt)
            nextRetryAt = now().addingTimeInterval(delay)
            scheduleRetry(after: delay)
            if let status {
                log("HTTP \(status): keeping \(events.count) event(s), retrying in \(Int(delay))s")
            } else {
                log("network error (\(error?.localizedDescription ?? "unknown")): keeping \(events.count) event(s), retrying in \(Int(delay))s")
            }
            finishFlush()
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWork = nil
            self.flushOnQueue(force: true)
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func remove(_ ids: Set<String>) {
        events.removeAll { ids.contains($0.uuid) }
        queueStore.save(events)
    }

    private func finishFlush() {
        guard !flushCompletions.isEmpty else { return }
        let completions = flushCompletions
        flushCompletions = []
        completions.forEach { $0() }
    }
}
