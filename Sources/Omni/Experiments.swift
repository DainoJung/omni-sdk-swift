import Foundation

/// What `GET <host>/v1/config` serves (PROTOCOL.md, Experiments). Decoded leniently: an experiment Omni added later in
/// a shape this version doesn't know is skipped, not a reason to drop the whole config.
struct ExperimentConfig: Decodable, Equatable {
    static let defaultTTL: TimeInterval = 300

    var experiments: [Experiment]
    var ttl: TimeInterval

    init(experiments: [Experiment], ttl: TimeInterval = ExperimentConfig.defaultTTL) {
        self.experiments = experiments
        self.ttl = ttl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        experiments = (try c.decodeIfPresent([Lossy<Experiment>].self, forKey: .experiments) ?? []).compactMap(\.value)
        let ttl = (try? c.decodeIfPresent(Double.self, forKey: .ttl)) ?? nil
        self.ttl = ttl.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? ExperimentConfig.defaultTTL
    }

    enum CodingKeys: String, CodingKey { case experiments, ttl }

    func experiment(_ key: String) -> Experiment? {
        experiments.first { $0.key == key }
    }
}

struct Experiment: Decodable, Equatable {
    var key: String
    var variants: [ExperimentVariant]
    var audience: Audience?
    var winner: String?
}

struct ExperimentVariant: Decodable, Equatable {
    var key: String
    var weight: Double
    var payload: [String: JSONValue]

    init(key: String, weight: Double, payload: [String: JSONValue] = [:]) {
        self.key = key
        self.weight = weight
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        weight = (try? c.decodeIfPresent(Double.self, forKey: .weight)) ?? 0
        payload = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .payload)) ?? [:]
    }

    enum CodingKeys: String, CodingKey { case key, weight, payload }
}

struct Audience: Decodable, Equatable {
    var platforms: [String]?
    /// As sent; when it's there but not a date, nobody matches (we can't tell who's new).
    var newUsersSince: String?

    enum CodingKeys: String, CodingKey {
        case platforms
        case newUsersSince = "new_users_since"
    }
}

/// Decodes `T`, or nil when this element doesn't fit.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Which variant a device gets. Pure and identical in every SDK (PROTOCOL.md, Assignment; sdk/test-vectors.json).
enum Assignment {
    /// 32-bit FNV-1a over the UTF-8 bytes.
    static func fnv1a32(_ s: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for byte in s.utf8 {
            h ^= UInt32(byte)
            h = h &* 16_777_619
        }
        return h
    }

    /// 0–9999, from the experiment key and this device's bucket id.
    static func bucket(experiment: String, bucketId: String) -> Int {
        Int(fnv1a32("\(experiment):\(bucketId)") % 10_000)
    }

    /// The index of the variant whose slice of 0–9999 holds `bucket`, or nil when no weight is positive.
    /// Slices are `weight * 10000 / W` in floating point, in order.
    static func variantIndex(weights: [Double], bucket: Int) -> Int? {
        let weights = weights.map { $0.isFinite ? max(0, $0) : 0 }
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }
        var running = 0.0
        for (i, w) in weights.enumerated() {
            running += w * 10_000 / total
            if running > Double(bucket) { return i }
        }
        // Rounding left the last slice a hair short: it belongs to the last variant that has any weight.
        return weights.lastIndex { $0 > 0 }
    }

    /// What this device sees for `experiment`, and whether it's an exposure to report (running, enrolled).
    /// Nil: not enrolled, and the app shows its default.
    static func choose(_ experiment: Experiment, bucketId: String, platform: String,
                       firstLaunch: Date?) -> (variant: ExperimentVariant, running: Bool)? {
        let audience = experiment.audience
        if let platforms = audience?.platforms, !platforms.contains(platform) { return nil }

        // Decided: everyone on a listed platform gets the winner, enrolled or not.
        if let winner = experiment.winner {
            let variant = experiment.variants.first { $0.key == winner } ?? ExperimentVariant(key: winner, weight: 0)
            return (variant, false)
        }

        if let since = audience?.newUsersSince {
            // Devices from before the first launch was kept have none: they count as old.
            guard let sinceDate = Timestamp.date(from: since), let firstLaunch, firstLaunch >= sinceDate else { return nil }
        }
        let bucket = bucket(experiment: experiment.key, bucketId: bucketId)
        guard let index = variantIndex(weights: experiment.variants.map(\.weight), bucket: bucket) else { return nil }
        return (experiment.variants[index], true)
    }
}
