import Foundation

/// A JSON value. Everything the SDK queues and sends is made of these, and experiment payloads come as these.
///
/// ```swift
/// let headline = Omni.payload("paywall_headline")?["headline"]?.stringValue ?? "Go Pro"
/// ```
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: Reading values

    /// The string, or nil when this isn't one.
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// The number as an `Int`, or nil when this isn't a whole number.
    public var intValue: Int? {
        switch self {
        case .int(let v): return Int(exactly: v)
        case .double(let v): return Int(exactly: v)
        default: return nil
        }
    }

    /// The number as a `Double` (whole numbers too), or nil when this isn't a number.
    public var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    /// Plain Swift values (`String`, `Int`, `Double`, `Bool`, `NSNull`, arrays, dictionaries), for code that reads
    /// `[String: Any]`: `Omni.payload("onboarding_v2")?.mapValues(\.anyValue)`.
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return Int(exactly: v).map { $0 as Any } ?? Double(v)
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.anyValue)
        case .object(let v): return v.mapValues(\.anyValue)
        }
    }
}

/// Turns arbitrary `[String: Any]` from the host app into JSON-safe values.
/// Dates become ISO 8601 strings, URLs and UUIDs strings; anything that can't be encoded is dropped.
enum Sanitizer {
    static let maxKeys = 100
    static let maxValueBytes = 1024
    private static let maxDepth = 16

    /// Sanitizes a property / trait dictionary and applies the protocol limits
    /// (≤ 100 keys, each value ≤ 1 KB as JSON).
    static func properties(_ dict: [String: Any], log: Log = Log(enabled: false)) -> [String: JSONValue] {
        if dict.isEmpty { return [:] }
        let encoder = JSONEncoder()
        var out: [String: JSONValue] = [:]
        for key in dict.keys.sorted() {
            guard let raw = dict[key] else { continue }
            guard let value = sanitize(raw) else {
                log("dropped property \"\(key)\": \(type(of: raw)) isn't JSON-encodable")
                continue
            }
            if needsSizeCheck(value), let data = try? encoder.encode(value), data.count > maxValueBytes {
                log("dropped property \"\(key)\": larger than 1 KB")
                continue
            }
            if out.count >= maxKeys {
                log("dropped properties after the first \(maxKeys) keys")
                break
            }
            out[key] = value
        }
        return out
    }

    /// Converts one value, or returns nil when it can't be represented as JSON.
    static func sanitize(_ any: Any, depth: Int = 0) -> JSONValue? {
        if depth > maxDepth { return nil }
        switch any {
        case let v as String: return .string(v)
        case let v as Substring: return .string(String(v))
        case let v as Character: return .string(String(v))
        case is NSNull: return .null
        case let v as Date: return .string(Timestamp.string(from: v))
        case let v as URL: return .string(v.absoluteString)
        case let v as UUID: return .string(v.uuidString.lowercased())
        case let v as NSDecimalNumber:
            let d = v.doubleValue
            return d.isFinite ? .double(d) : nil
        case let v as NSNumber: return number(v)
        case let v as [Any]:
            return .array(v.compactMap { sanitize($0, depth: depth + 1) })
        case let v as [String: Any]:
            var obj: [String: JSONValue] = [:]
            for (k, item) in v { if let s = sanitize(item, depth: depth + 1) { obj[k] = s } }
            return .object(obj)
        case let v as [AnyHashable: Any]:
            var obj: [String: JSONValue] = [:]
            for (k, item) in v {
                if let s = sanitize(item, depth: depth + 1) { obj[String(describing: k.base)] = s }
            }
            return .object(obj)
        default:
            break
        }
        if let r = any as? any RawRepresentable {
            return sanitize(r.rawValue, depth: depth + 1)
        }
        let mirror = Mirror(reflecting: any)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return .null }
            return sanitize(child.value, depth: depth + 1)
        }
        return nil
    }

    private static func number(_ n: NSNumber) -> JSONValue? {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
        if CFNumberIsFloatType(n) {
            let d = n.doubleValue
            return d.isFinite ? .double(d) : nil
        }
        let type = String(cString: n.objCType)
        if type == "Q" || type == "L" || type == "I", n.uint64Value > UInt64(Int64.max) {
            return .double(n.doubleValue)
        }
        return .int(n.int64Value)
    }

    private static func needsSizeCheck(_ v: JSONValue) -> Bool {
        switch v {
        case .string(let s): return s.utf8.count > maxValueBytes - 2
        case .array, .object: return true
        default: return false
        }
    }
}

enum Timestamp {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let wholeSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `2026-10-21T08:59:58.120Z`
    static func string(from date: Date) -> String { formatter.string(from: date) }

    /// ISO 8601 with or without fractional seconds, or nil.
    static func date(from string: String) -> Date? {
        formatter.date(from: string) ?? wholeSeconds.date(from: string)
    }
}

struct Log {
    let enabled: Bool

    func callAsFunction(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print("[Omni] \(message())")
    }
}
