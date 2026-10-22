import Foundation

/// Small key-value persistence (ids, flags, last seen version). Implementations must be thread-safe.
protocol KeyValueStore: AnyObject {
    func string(_ key: String) -> String?
    func bool(_ key: String) -> Bool
    func double(_ key: String) -> Double?
    func set(_ value: Any?, forKey key: String)
}

enum StoreKey {
    static let anonId = "anon_id"
    static let userId = "user_id"
    static let optedOut = "opted_out"
    static let lastVersion = "last_version"
    static let lastBuild = "last_build"
    static let sessionId = "session_id"
    static let sessionLastActivity = "session_last_activity"
    /// Kept for good, through `reset()`: experiments assign from it, so logging out doesn't change a variant.
    static let bucketId = "bucket_id"
    /// When this install first ran (with the SDK keeping it); experiments with `new_users_since` read it.
    static let firstLaunch = "first_launch_at"
    static let config = "config"
    static let configFetchedAt = "config_fetched_at"
    /// The session and the experiments already reported in it (`$exposure` once per experiment per session).
    static let exposures = "exposures"
    static let pushToken = "push_token"
    static let pushEnvironment = "push_environment"
    static let pushTokenSentAt = "push_token_sent_at"
    static let pushPermission = "push_permission"
}

final class UserDefaultsStore: KeyValueStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The SDK's own suite (`app.omnigrowth.sdk`). On macOS, where apps outside the sandbox share
    /// ~/Library/Preferences, the bundle id is appended so two apps never share an anon_id.
    static func standard() -> UserDefaultsStore {
        var suite = "app.omnigrowth.sdk"
        #if os(macOS)
        let id = Bundle.main.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? ProcessInfo.processInfo.processName
        suite += ".\(id)"
        #endif
        return UserDefaultsStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    func string(_ key: String) -> String? { defaults.string(forKey: key) }
    func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    func double(_ key: String) -> Double? { defaults.object(forKey: key) as? Double }

    func set(_ value: Any?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Persistence for the event queue. Called only from the client's serial queue.
protocol QueueStore: AnyObject {
    func load() -> [Event]
    func save(_ events: [Event])
}

/// The queue as one JSON file, written atomically on every change.
final class FileQueueStore: QueueStore {
    let fileURL: URL
    private let log: Log

    init(fileURL: URL, log: Log = Log(enabled: false)) {
        self.fileURL = fileURL
        self.log = log
    }

    /// Application Support/omni/queue.json (Caches on tvOS, which has no persistent Application Support;
    /// Application Support/<bundle id>/omni on macOS, where it isn't per app).
    static func defaultURL() -> URL {
        let fm = FileManager.default
        #if os(tvOS)
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        #else
        var base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        #if os(macOS)
        // Application Support is shared by every app on a Mac outside the sandbox: nest under this app's id.
        let id = Bundle.main.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? ProcessInfo.processInfo.processName
        base.appendPathComponent(id, isDirectory: true)
        #endif
        #endif
        return base.appendingPathComponent("omni", isDirectory: true).appendingPathComponent("queue.json")
    }

    func load() -> [Event] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([Event].self, from: data)
        } catch {
            log("queue file unreadable, starting empty: \(error)")
            try? FileManager.default.removeItem(at: fileURL)
            return []
        }
    }

    func save(_ events: [Event]) {
        do {
            if events.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                return
            }
            try ensureDirectory()
            let data = try JSONEncoder().encode(events)
            #if os(iOS)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: fileURL, options: .atomic)
            #endif
        } catch {
            log("couldn't save the queue: \(error)")
        }
    }

    private func ensureDirectory() throws {
        var dir = fileURL.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }
}
