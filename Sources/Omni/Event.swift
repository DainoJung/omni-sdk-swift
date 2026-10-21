import Foundation

/// `context` of an event (PROTOCOL.md). All fields optional; absent ones are omitted.
struct EventContext: Codable, Equatable {
    var appVersion: String?
    var build: String?
    var platform: String?
    var deviceType: String?
    var locale: String?
    var osVersion: String?
    var deviceModel: String?
    var sessionId: String?
    var sdk: String?

    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version"
        case build
        case platform
        case deviceType = "device_type"
        case locale
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case sessionId = "session_id"
        case sdk
    }
}

/// `identity` of an event: only on `$identify` and `$set`.
struct Identity: Codable, Equatable {
    var billingId: String?
    var traits: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case billingId = "billing_id"
        case traits
    }
}

/// One event as it sits in the queue and goes over the wire.
struct Event: Codable, Equatable {
    var uuid: String
    var event: String
    var ts: String
    var anonId: String
    var userId: String?
    var properties: [String: JSONValue]
    var context: EventContext
    var identity: Identity?

    enum CodingKeys: String, CodingKey {
        case uuid, event, ts
        case anonId = "anon_id"
        case userId = "user_id"
        case properties, context, identity
    }

    init(uuid: String, event: String, ts: String, anonId: String, userId: String?,
         properties: [String: JSONValue], context: EventContext, identity: Identity?) {
        self.uuid = uuid
        self.event = event
        self.ts = ts
        self.anonId = anonId
        self.userId = userId
        self.properties = properties
        self.context = context
        self.identity = identity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        event = try c.decode(String.self, forKey: .event)
        ts = try c.decode(String.self, forKey: .ts)
        anonId = try c.decode(String.self, forKey: .anonId)
        userId = try c.decodeIfPresent(String.self, forKey: .userId)
        properties = try c.decodeIfPresent([String: JSONValue].self, forKey: .properties) ?? [:]
        context = try c.decodeIfPresent(EventContext.self, forKey: .context) ?? EventContext()
        identity = try c.decodeIfPresent(Identity.self, forKey: .identity)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid, forKey: .uuid)
        try c.encode(event, forKey: .event)
        try c.encode(ts, forKey: .ts)
        try c.encode(anonId, forKey: .anonId)
        // `user_id` is always present: the id, or null before identify().
        if let userId { try c.encode(userId, forKey: .userId) } else { try c.encodeNil(forKey: .userId) }
        try c.encode(properties, forKey: .properties)
        try c.encode(context, forKey: .context)
        try c.encodeIfPresent(identity, forKey: .identity)
    }
}

/// Body of `POST /v1/batch`.
struct BatchBody: Encodable {
    let key: String
    let sentAt: String
    let batch: [Event]

    enum CodingKeys: String, CodingKey {
        case key
        case sentAt = "sent_at"
        case batch
    }
}
