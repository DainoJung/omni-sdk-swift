import Foundation

/// Omni: send product events from your app to Omni Cloud.
///
/// ```swift
/// Omni.configure(key: "opk_…")
/// Omni.track("lesson_completed", properties: ["lesson": 3])
/// ```
///
/// Every call is thread-safe, returns immediately and never throws. Work happens on a background queue.
public enum Omni {
    public static let sdkVersion = "0.1.0"

    public struct Options: Sendable {
        /// Omni Cloud's base URL. Events go to `<host>/v1/batch`.
        public var host: String
        /// Send once this many events are queued.
        public var flushAt: Int
        /// Send queued events at least this often, in seconds.
        public var flushInterval: TimeInterval
        /// Most events kept on the device while offline; the oldest are dropped first.
        public var maxQueue: Int
        /// Send `$app_installed`, `$app_updated` and `$app_opened` automatically.
        /// (Flushing when the app goes to the background happens either way.)
        public var captureLifecycle: Bool
        /// Log what the SDK does to the console.
        public var debug: Bool

        public init(host: String = "https://api.omnigrowth.app",
                    flushAt: Int = 20,
                    flushInterval: TimeInterval = 30,
                    maxQueue: Int = 1000,
                    captureLifecycle: Bool = true,
                    debug: Bool = false) {
            self.host = host
            self.flushAt = flushAt
            self.flushInterval = flushInterval
            self.maxQueue = maxQueue
            self.captureLifecycle = captureLifecycle
            self.debug = debug
        }

        /// The same options with out-of-range values pulled into range.
        var normalized: Options {
            var o = self
            o.maxQueue = max(1, maxQueue)
            o.flushAt = min(max(1, flushAt), o.maxQueue)
            o.flushInterval = flushInterval.isFinite ? max(1, flushInterval) : 30
            return o
        }

        /// `<host>/v1/batch`, or nil when `host` isn't an http(s) URL.
        var batchURL: URL? {
            var base = host.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") { base.removeLast() }
            guard let url = URL(string: base + "/v1/batch"),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  url.host != nil else { return nil }
            return url
        }
    }

    // MARK: Setup

    /// Starts Omni. Call once, as early as possible (your `App` init or
    /// `application(_:didFinishLaunchingWithOptions:)`). Later calls are ignored.
    ///
    /// - Parameter key: your app's public write key (`opk_…`), shown in Omni.
    public static func configure(key: String, options: Options = .init()) {
        let options = options.normalized
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            print("[Omni] configure: the key is empty, so Omni stays off.")
            return
        }
        guard let endpoint = options.batchURL else {
            print("[Omni] configure: \"\(options.host)\" isn't a valid host, so Omni stays off.")
            return
        }
        if options.debug && !key.hasPrefix("opk_") {
            print("[Omni] configure: keys normally start with opk_. Is this the right key?")
        }
        if let existing = currentClient() {
            existing.log("configure called again; ignored")
            return
        }

        // Collected outside the lock: it may hop to the main thread.
        let log = Log(enabled: options.debug)
        let device = DeviceInfo.collect()
        let client = OmniClient(
            key: key,
            options: options,
            endpoint: endpoint,
            storage: UserDefaultsStore.standard(),
            queueStore: FileQueueStore(fileURL: FileQueueStore.defaultURL(), log: log),
            transport: URLSessionTransport(),
            device: device
        )

        lock.lock()
        guard sharedClient == nil else {
            lock.unlock()
            return
        }
        sharedClient = client
        observer = LifecycleObserver(client: client)
        lock.unlock()

        client.start(appInBackground: AppState.isInBackground())
        log("configured (\(device.platform), \(device.deviceModel ?? "unknown model"), anon_id \(client.anonymousId))")
    }

    // MARK: Events

    /// Records an event. Names starting with `$` are Omni's own and are ignored here.
    /// Property values may be strings, numbers, booleans, dates, URLs, arrays and dictionaries of these;
    /// anything else is dropped.
    public static func track(_ event: String, properties: [String: Any] = [:]) {
        client("track")?.track(event, properties: properties)
    }

    /// Records a screen view (`$screen`).
    public static func screen(_ name: String, properties: [String: Any] = [:]) {
        client("screen")?.screen(name, properties: properties)
    }

    // MARK: Identity

    /// Links this device to your own user id (`$identify`). Call after sign-in.
    /// Traits are person properties, e.g. `["plan": "pro"]`.
    public static func identify(_ userId: String, traits: [String: Any] = [:]) {
        client("identify")?.identify(userId, traits: traits)
    }

    /// Updates person properties (`$set`).
    public static func setTraits(_ traits: [String: Any]) {
        client("setTraits")?.setTraits(traits)
    }

    /// Sets the person's email. Pass `consent: true` only after they agreed to marketing email.
    public static func setEmail(_ email: String, consent: Bool) {
        client("setEmail")?.setEmail(email, consent: consent)
    }

    /// Tells Omni who this person is on the billing side, so revenue joins product events.
    /// Pass RevenueCat's `Purchases.shared.appUserID` or the Stripe customer id (`cus_…`).
    public static func setBillingId(_ id: String) {
        client("setBillingId")?.setBillingId(id)
    }

    /// Call on sign-out: a new anonymous id, and the user id is cleared.
    public static func reset() {
        client("reset")?.reset()
    }

    // MARK: Sending and privacy

    /// Sends queued events now.
    public static func flush() {
        client("flush")?.flush()
    }

    /// Stops collection and deletes queued events. Remembered across launches.
    /// Works before `configure` too.
    public static func optOut() {
        if let c = currentClient() {
            c.optOut()
        } else {
            UserDefaultsStore.standard().set(true, forKey: StoreKey.optedOut)
        }
    }

    /// Resumes collection after `optOut()`.
    public static func optIn() {
        if let c = currentClient() {
            c.optIn()
        } else {
            UserDefaultsStore.standard().set(false, forKey: StoreKey.optedOut)
        }
    }

    public static var isOptedOut: Bool {
        currentClient()?.isOptedOut ?? UserDefaultsStore.standard().bool(StoreKey.optedOut)
    }

    /// The random id Omni knows this device by until `identify`. New after `reset()`.
    public static var anonymousId: String {
        currentClient()?.anonymousId ?? OmniClient.storedAnonId(UserDefaultsStore.standard())
    }

    // MARK: Internals

    private static let lock = NSLock()
    private static var sharedClient: OmniClient?
    private static var observer: LifecycleObserver?
    private static var warnedUnconfigured = false

    private static func currentClient() -> OmniClient? {
        lock.lock()
        defer { lock.unlock() }
        return sharedClient
    }

    private static func client(_ call: String) -> OmniClient? {
        lock.lock()
        defer { lock.unlock() }
        if let sharedClient { return sharedClient }
        if !warnedUnconfigured {
            warnedUnconfigured = true
            print("[Omni] \(call) called before Omni.configure(key:); ignored.")
        }
        return nil
    }
}
