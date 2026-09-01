import Foundation

/// A dynamically-typed JSON value.
///
/// `pi` owns the shape of agent messages, model descriptors and tool arguments, and
/// evolves them independently of this app. Modelling every variant here would fork
/// upstream's schema and break on every pi release, so payloads whose shape belongs
/// to pi are carried as `JSONValue` and read through narrow accessors at the point
/// of use. Envelope types the protocol itself defines stay strongly typed.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not valid JSON"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    // MARK: - Accessors

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case let .number(value) = self, value.isFinite else { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// Member lookup on objects; `nil` for every other kind.
    public subscript(key: String) -> JSONValue? {
        guard case let .object(members) = self else { return nil }
        return members[key]
    }

    /// Element lookup on arrays; `nil` for every other kind or an out-of-range index.
    public subscript(index: Int) -> JSONValue? {
        guard case let .array(elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    /// Follows a dotted key path, e.g. `value.path("data.model.id")`.
    public func path(_ keyPath: String) -> JSONValue? {
        keyPath.split(separator: ".").reduce(self as JSONValue?) { current, component in
            current?[String(component)]
        }
    }
}
