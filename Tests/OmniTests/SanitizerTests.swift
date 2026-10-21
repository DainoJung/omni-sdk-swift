import XCTest
@testable import Omni

final class SanitizerTests: XCTestCase {
    private enum Plan: String { case pro }
    private final class Opaque {}

    func testPrimitivesAndFoundationTypes() {
        let date = Date(timeIntervalSince1970: 1_792_400_000.12)
        let uuid = UUID()
        let optionalNil: Int? = nil
        let optionalSome: String? = "x"
        let props = Sanitizer.properties([
            "string": "hi",
            "int": 3,
            "int8": Int8(-2),
            "uint": UInt(7),
            "double": 1.5,
            "float": Float(0.5),
            "bool": true,
            "nsbool": NSNumber(value: false),
            "nsint": NSNumber(value: 1),
            "date": date,
            "url": URL(string: "https://omnigrowth.app/x?y=1")!,
            "uuid": uuid,
            "null": NSNull(),
            "optional_nil": optionalNil as Any,
            "optional_some": optionalSome as Any,
            "enum": Plan.pro,
            "decimal": Decimal(string: "9.99")!,
        ])
        XCTAssertEqual(props["string"], .string("hi"))
        XCTAssertEqual(props["int"], .int(3))
        XCTAssertEqual(props["int8"], .int(-2))
        XCTAssertEqual(props["uint"], .int(7))
        XCTAssertEqual(props["double"], .double(1.5))
        XCTAssertEqual(props["float"], .double(0.5))
        XCTAssertEqual(props["bool"], .bool(true))
        XCTAssertEqual(props["nsbool"], .bool(false))
        XCTAssertEqual(props["nsint"], .int(1))
        XCTAssertEqual(props["date"], .string(Timestamp.string(from: date)))
        XCTAssertEqual(props["url"], .string("https://omnigrowth.app/x?y=1"))
        XCTAssertEqual(props["uuid"], .string(uuid.uuidString.lowercased()))
        XCTAssertEqual(props["null"], .null)
        XCTAssertEqual(props["optional_nil"], .null)
        XCTAssertEqual(props["optional_some"], .string("x"))
        XCTAssertEqual(props["enum"], .string("pro"))
        XCTAssertEqual(props["decimal"], .double(9.99))
    }

    func testNestedAndDropped() {
        let props = Sanitizer.properties([
            "nested": ["a": [1, "b", ["c": true]], "skip": Opaque()] as [String: Any],
            "list": [1, Opaque(), "two"] as [Any],
            "opaque": Opaque(),
            "closure": { () -> Void in },
            "nan": Double.nan,
            "inf": Double.infinity,
            "int_keys": [1: "one"],
        ])
        XCTAssertEqual(props["nested"], .object(["a": .array([.int(1), .string("b"), .object(["c": .bool(true)])])]))
        XCTAssertEqual(props["list"], .array([.int(1), .string("two")]))
        XCTAssertEqual(props["int_keys"], .object(["1": .string("one")]))
        XCTAssertNil(props["opaque"])
        XCTAssertNil(props["closure"])
        XCTAssertNil(props["nan"])
        XCTAssertNil(props["inf"])
    }

    func testLimits() {
        var many: [String: Any] = [:]
        for i in 0..<150 { many[String(format: "k%03d", i)] = i }
        let capped = Sanitizer.properties(many)
        XCTAssertEqual(capped.count, 100)
        XCTAssertNotNil(capped["k000"])
        XCTAssertNil(capped["k100"])

        let sized = Sanitizer.properties([
            "big": String(repeating: "x", count: 2000),
            "ok": String(repeating: "x", count: 1000),
            "big_list": Array(repeating: "abcdefghij", count: 200),
        ])
        XCTAssertNil(sized["big"])
        XCTAssertNil(sized["big_list"])
        XCTAssertNotNil(sized["ok"])
    }

    func testEncodesToPlainJSON() throws {
        let props = Sanitizer.properties(["a": [1, 2.5, "x", true] as [Any], "b": NSNull()])
        let data = try JSONEncoder().encode(props)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(json["b"] is NSNull)
        let a = try XCTUnwrap(json["a"] as? [Any])
        XCTAssertEqual(a.count, 4)
        XCTAssertEqual(try JSONDecoder().decode([String: JSONValue].self, from: data), props)
    }

    func testOptionsNormalizeAndHost() {
        let o = Omni.Options(host: "https://example.com/", flushAt: 0, flushInterval: -1, maxQueue: 0).normalized
        XCTAssertEqual(o.maxQueue, 1)
        XCTAssertEqual(o.flushAt, 1)
        XCTAssertEqual(o.flushInterval, 1)
        XCTAssertEqual(o.batchURL?.absoluteString, "https://example.com/v1/batch")
        XCTAssertNil(Omni.Options(host: "not a url").batchURL)
        XCTAssertEqual(Omni.Options().batchURL?.absoluteString, "https://api.omnigrowth.app/v1/batch")
    }

    func testLocaleIdentifier() {
        XCTAssertEqual(DeviceInfo.localeIdentifier(Locale(identifier: "ko_KR")), "ko-KR")
        XCTAssertEqual(DeviceInfo.localeIdentifier(Locale(identifier: "en_US@calendar=japanese")), "en-US")
    }
}
