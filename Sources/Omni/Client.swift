import Foundation

/// The engine behind the `Omni` facade. Identity (anon_id, user_id, opt-out) and what `variant()` reads (the
/// experiments config, exposures already reported) are guarded by a lock so they can be read from any thread at call
/// time; everything else (queue, session, sending, fetching the config) is confined to one serial background queue.
final class OmniClient {
    static let sessionTimeout: TimeInterval = 30 * 60
    static let maxBatchSize = 100
    static let maxBodyBytes = 500_000
    static let maxEventNameLength = 200

    let key: String
    let options: Omni.Options
    let endpoint: URL
    let configEndpoint: URL?
    let log: Log
    /// Experiments assign from it. Never sent, never reset.
    let bucketId: String
    /// When this install first ran, or nil when it ran before the SDK kept that (an old user to experiments).
    let firstLaunch: Date?
    let queue = DispatchQueue(label: "app.omnigrowth.sdk", qos: .utility)

    private let storage: KeyValueStore
    private let queueStore: QueueStore
    private let transport: Transport
    private let device: DeviceInfo
    private let pushPermission: PushPermissionReader?
    private let pushCategories: PushCategoryRegistrar?
    private let now: () -> Date
    /// The device's time zone, read for each event (people travel).
    private let timeZone: () -> String
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

    // Experiments — guarded by `lock`.
    private var _config: ExperimentConfig?
    private var _configFetchedAt: Date?
    /// Experiments already reported (`$exposure`) in the current session, and until when that session is surely
    /// alive: `variant()` skips the SDK queue while both say so.
    private var exposed: Set<String> = []
    private var sessionAliveUntil = Date.distantPast

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
    private var isFetchingConfig = false
    private var configCompletions: [() -> Void] = []

    init(key: String,
         options: Omni.Options,
         endpoint: URL,
         storage: KeyValueStore,
         queueStore: QueueStore,
         transport: Transport,
         device: DeviceInfo,
         pushPermission: PushPermissionReader? = nil,
         pushCategories: PushCategoryRegistrar? = nil,
         now: @escaping () -> Date = Date.init,
         timeZone: @escaping () -> String = { TimeZone.current.identifier }) {
        self.key = key
        self.options = options
        self.endpoint = endpoint
        self.configEndpoint = options.configURL(key: key)
        self.log = Log(enabled: options.debug)
        self.storage = storage
        self.queueStore = queueStore
        self.transport = transport
        self.device = device
        self.pushPermission = pushPermission
        self.pushCategories = pushCategories
        self.now = now
        self.timeZone = timeZone

        _anonId = OmniClient.storedAnonId(storage)
        _userId = storage.string(StoreKey.userId)
        _optedOut = storage.bool(StoreKey.optedOut)
        sessionId = storage.string(StoreKey.sessionId)
        lastActivity = storage.double(StoreKey.sessionLastActivity).map(Date.init(timeIntervalSince1970:))
        bucketId = OmniClient.storedBucketId(storage)
        firstLaunch = OmniClient.storedFirstLaunch(storage, now: now())

        // The last config copy, readable at once; and the exposures already reported if this is the same session.
        if let config: ExperimentConfig = OmniClient.decode(storage.string(StoreKey.config)) {
            _config = config
            _configFetchedAt = storage.double(StoreKey.configFetchedAt).map(Date.init(timeIntervalSince1970:))
        }
        if let saved: SessionExposures = OmniClient.decode(storage.string(StoreKey.exposures)),
           saved.session == sessionId, let lastActivity {
            exposed = Set(saved.experiments)
            sessionAliveUntil = lastActivity.addingTimeInterval(OmniClient.sessionTimeout)
        }

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

    static func storedBucketId(_ storage: KeyValueStore) -> String {
        if let id = storage.string(StoreKey.bucketId), !id.isEmpty { return id }
        let id = newId()
        storage.set(id, forKey: StoreKey.bucketId)
        return id
    }

    /// Kept on the first launch ever (no version seen yet: the launch that sends `$app_installed`). Installs that ran
    /// before the SDK kept it have none.
    static func storedFirstLaunch(_ storage: KeyValueStore, now: Date) -> Date? {
        if let t = storage.double(StoreKey.firstLaunch) { return Date(timeIntervalSince1970: t) }
        guard storage.string(StoreKey.lastVersion) == nil, storage.string(StoreKey.lastBuild) == nil else { return nil }
        storage.set(now.timeIntervalSince1970, forKey: StoreKey.firstLaunch)
        return now
    }

    static func decode<T: Decodable>(_ json: String?) -> T? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

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
            // A new session for the new person: `variant()` right after this reports again.
            exposed.removeAll()
            sessionAliveUntil = .distantPast
        }
        storage.set(anon, forKey: StoreKey.anonId)
        storage.set(nil, forKey: StoreKey.userId)
        queue.async { [self] in
            endSession() // the next event starts a new session
            log("reset: new anon_id \(anon)")
            // The device's push token moves to the new anonymous person, so pushes follow who's signed in here.
            if let registration: PushRegistration = OmniClient.decode(storage.string(StoreKey.pushToken)) {
                sendPushToken(registration, at: now(), anonId: anon, userId: nil)
            }
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

    // MARK: Experiments

    /// The variant this device gets for experiment `key`, or nil (not loaded, not listed, not enrolled). The first
    /// one in a session of a running experiment sends `$exposure`.
    func experimentVariant(_ key: String) -> ExperimentVariant? {
        guard let experiment = locked({ _config?.experiment(key) }),
              let chosen = Assignment.choose(experiment, bucketId: bucketId, platform: device.platform, firstLaunch: firstLaunch)
        else { return nil }
        if chosen.running { reportExposure(key, variant: chosen.variant.key) }
        return chosen.variant
    }

    /// `$exposure` once per experiment per session. The lock answers repeat calls without touching the queue; the
    /// queue decides for real, since only it knows whether the session is still the same.
    private func reportExposure(_ experiment: String, variant: String) {
        let ts = now()
        let (anon, user, optedOut, known) = locked {
            (_anonId, _userId, _optedOut, ts < sessionAliveUntil && exposed.contains(experiment))
        }
        guard !optedOut, !known else { return }
        queue.async { [self] in
            if sessionAlive(at: ts) && locked({ exposed.contains(experiment) }) { return }
            enqueue("$exposure", properties: ["experiment": .string(experiment), "variant": .string(variant)],
                    identity: nil, ts: ts, anonId: anon, userId: user)
            let experiments = locked { () -> [String] in
                exposed.insert(experiment)
                return exposed.sorted()
            }
            storage.set(OmniClient.encode(SessionExposures(session: sessionId, experiments: experiments)), forKey: StoreKey.exposures)
        }
    }

    var config: ExperimentConfig? { locked { _config } }

    /// Fetches the experiments config. Without `force`, a copy younger than its `ttl` is kept as is. `completion` runs
    /// on the SDK queue when this fetch, or the one already under way, ends.
    func refreshConfig(force: Bool, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            if let completion { configCompletions.append(completion) }
            if isFetchingConfig { return }
            guard let url = configEndpoint, force || !configIsFresh() else {
                finishConfigFetch()
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("omni-swift/\(Omni.sdkVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            isFetchingConfig = true
            transport.fetch(request) { [weak self] status, body, error in
                guard let self else { return }
                self.queue.async { self.handleConfig(status: status, body: body, error: error) }
            }
        }
    }

    /// Resolves once the config is fetched (or found fresh), or after `timeout` seconds, whichever comes first.
    func loadExperiments(timeout: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            refreshConfig(force: false) { once.resume() }
            let wait = timeout.isFinite ? max(0, timeout) : 2
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + wait) { once.resume() }
        }
    }

    private func configIsFresh() -> Bool {
        let (fetchedAt, ttl) = locked { (_configFetchedAt, _config?.ttl ?? ExperimentConfig.defaultTTL) }
        guard let fetchedAt else { return false }
        let age = now().timeIntervalSince(fetchedAt)
        return age >= 0 && age < ttl
    }

    private func handleConfig(status: Int?, body: Data?, error: Error?) {
        isFetchingConfig = false
        if let status, (200..<300).contains(status), let body,
           let config = try? JSONDecoder().decode(ExperimentConfig.self, from: body) {
            let at = now()
            locked {
                _config = config
                _configFetchedAt = at
            }
            storage.set(String(data: body, encoding: .utf8), forKey: StoreKey.config)
            storage.set(at.timeIntervalSince1970, forKey: StoreKey.configFetchedAt)
            log("experiments: \(config.experiments.map(\.key)), push categories: \(config.pushCategories.map(\.id))")
            pushCategories?(config.pushCategories)
        } else if let status {
            log("experiments config: HTTP \(status); keeping the last copy")
        } else {
            log("experiments config: network error (\(error?.localizedDescription ?? "unknown")); keeping the last copy")
        }
        finishConfigFetch()
    }

    private func finishConfigFetch() {
        guard !configCompletions.isEmpty else { return }
        let completions = configCompletions
        configCompletions = []
        completions.forEach { $0() }
    }

    // MARK: Push

    /// `$push_token` when the token, provider or environment changed, or a week after it was last sent.
    func setPushToken(_ token: String, provider: String, environment: String, topic: String?) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            log("ignored setPushToken: empty token")
            return
        }
        let ts = now()
        let (anon, user) = locked { (_anonId, _userId) }
        let registration = PushRegistration(token: token, provider: provider, environment: environment, topic: topic,
                                            buttons: Push.showsButtons, sentAt: nil)
        queue.async { [self] in
            let last: PushRegistration? = OmniClient.decode(storage.string(StoreKey.pushToken))
            if let last, last.sameDevice(as: registration), let sentAt = last.sentAt.map(Date.init(timeIntervalSince1970:)),
               ts >= sentAt, ts.timeIntervalSince(sentAt) < Push.resendAfter {
                return
            }
            guard sendPushToken(registration, at: ts, anonId: anon, userId: user) else { return }
            // Omni keeps the permission with the token: a new token gets the one already seen.
            if last?.token != token, let status = storage.string(StoreKey.pushPermission) {
                enqueue("$push_permission", properties: ["status": .string(status)], identity: nil, ts: ts, anonId: anon, userId: user)
            }
        }
    }

    /// Queue only. Not remembered as sent while opted out, so it goes out once collection resumes.
    @discardableResult
    private func sendPushToken(_ registration: PushRegistration, at ts: Date, anonId: String, userId: String?) -> Bool {
        guard !isOptedOut else { return false }
        var props: [String: JSONValue] = [
            "token": .string(registration.token),
            "provider": .string(registration.provider),
            "environment": .string(registration.environment),
        ]
        if let topic = registration.topic { props["topic"] = .string(topic) }
        // This device can show Omni's buttons; devices without it get pushes without them.
        if Push.showsButtons { props["buttons"] = .bool(true) }
        enqueue("$push_token", properties: props, identity: nil, ts: ts, anonId: anonId, userId: userId)
        var sent = registration
        sent.buttons = Push.showsButtons
        sent.sentAt = ts.timeIntervalSince1970
        storage.set(OmniClient.encode(sent), forKey: StoreKey.pushToken)
        return true
    }

    /// `$push_opened` for one of Omni's pushes: `action` is `open` (the notification itself) or the button's id.
    func pushOpened(messageId: String, action: String = "open") {
        capture("$push_opened", properties: ["message_id": .string(messageId), "action": .string(action)])
    }

    private func readPushPermission() {
        guard let pushPermission else { return }
        pushPermission { [weak self] status in
            guard let self, let status else { return }
            self.queue.async { self.pushPermissionSeen(status) }
        }
    }

    /// `$push_permission` when it differs from the last one sent.
    private func pushPermissionSeen(_ status: String) {
        guard storage.string(StoreKey.pushPermission) != status, !isOptedOut else { return }
        captureOnQueue("$push_permission", properties: ["status": .string(status)])
        storage.set(status, forKey: StoreKey.pushPermission)
    }

    // MARK: Lifecycle

    /// Cold start: install/update detection, the first `$app_opened`, the flush timer, the push categories of the
    /// config copy on the device, a fresh experiments config and the push permission.
    func start(appInBackground: Bool) {
        queue.async { [self] in
            if let pushCategories, let config = locked({ _config }) { pushCategories(config.pushCategories) }
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
        refreshConfig(force: true)
        readPushPermission()
    }

    func appDidBecomeActive() {
        refreshConfig(force: false)
        readPushPermission()
        queue.async { [self] in
            if let since = backgroundedAt, now().timeIntervalSince(since) >= OmniClient.sessionTimeout {
                endSession()
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

    /// `$app_installed` goes with the first launch `storedFirstLaunch` kept at init.
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
        if !sessionAlive(at: ts) {
            sessionId = OmniClient.newId()
            storage.set(sessionId, forKey: StoreKey.sessionId)
            locked { exposed.removeAll() }
            storage.set(nil, forKey: StoreKey.exposures)
        }
        lastActivity = ts
        storage.set(ts.timeIntervalSince1970, forKey: StoreKey.sessionLastActivity)
        locked { sessionAliveUntil = ts.addingTimeInterval(OmniClient.sessionTimeout) }
        return EventContext(
            appVersion: device.appVersion,
            build: device.build,
            platform: device.platform,
            deviceType: device.deviceType,
            locale: device.locale,
            osVersion: device.osVersion,
            deviceModel: device.deviceModel,
            timezone: timeZone(),
            sessionId: sessionId,
            sdk: "omni-swift/\(Omni.sdkVersion)"
        )
    }

    /// Whether an event at `ts` still belongs to the current session.
    private func sessionAlive(at ts: Date) -> Bool {
        guard sessionId != nil, let lastActivity else { return false }
        return ts.timeIntervalSince(lastActivity) < OmniClient.sessionTimeout
    }

    /// The next event starts a new session, with no experiments reported in it yet.
    private func endSession() {
        sessionId = nil
        locked {
            exposed.removeAll()
            sessionAliveUntil = .distantPast
        }
        storage.set(nil, forKey: StoreKey.exposures)
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

/// The experiments already reported in one session (persisted, so a relaunch inside the session doesn't repeat them).
struct SessionExposures: Codable {
    var session: String?
    var experiments: [String]
}

/// The push token last sent, and when.
struct PushRegistration: Codable, Equatable {
    var token: String
    var provider: String
    var environment: String
    var topic: String?
    /// Sent as `buttons`. Nil in registrations kept by SDKs before 0.5.0, so updating resends the token at once.
    var buttons: Bool?
    var sentAt: TimeInterval?

    func sameDevice(as other: PushRegistration) -> Bool {
        token == other.token && provider == other.provider && environment == other.environment && buttons == other.buttons
    }
}

/// Resumes a continuation once, whichever of the config fetch or the timeout comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func resume() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}
