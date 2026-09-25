import Foundation

/// Any JSON value, for results whose shape only the practice knows.
public enum JSONValue: Codable, Hashable, Sendable {
    case null, bool(Bool), int(Int64), number(Double), string(String), array([JSONValue]), object([String: JSONValue], order: [String])

    public init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: AnyKey.self) {
            var dict: [String: JSONValue] = [:]
            // JSONDecoder does not keep key order; the order is re-read from the raw text by
            // `JSONValue.parse` when it matters (tables use explicit columns instead).
            for key in c.allKeys { dict[key.stringValue] = try c.decode(JSONValue.self, forKey: key) }
            self = .object(dict, order: dict.keys.sorted())
            return
        }
        if var a = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !a.isAtEnd { items.append(try a.decode(JSONValue.self)) }
            self = .array(items)
            return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        // Integers first: 64-bit ids (device_hash) do not survive a trip through Double.
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let b): var c = encoder.singleValueContainer(); try c.encode(b)
        case .int(let i): var c = encoder.singleValueContainer(); try c.encode(i)
        case .number(let n): var c = encoder.singleValueContainer(); try c.encode(n)
        case .string(let s): var c = encoder.singleValueContainer(); try c.encode(s)
        case .array(let a): var c = encoder.unkeyedContainer(); for v in a { try c.encode(v) }
        case .object(let o, let order):
            var c = encoder.container(keyedBy: AnyKey.self)
            for k in order { try c.encode(o[k]!, forKey: AnyKey(stringValue: k)) }
        }
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Compact one-line text for a table cell.
    public var cellText: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s): return s
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }
}
