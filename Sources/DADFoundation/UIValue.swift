import Foundation

/// Free-form JSON. The insights layout and the dashboard it binds into are read as untrusted JSON, so a node or
/// field this build does not know can never fail a decode.
public indirect enum UIValue: Sendable, Equatable, Decodable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([UIValue])
    case object([String: UIValue])

    public init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null }
        else if let value = try? single.decode(Bool.self) { self = .bool(value) }
        else if let value = try? single.decode(Int.self) { self = .integer(value) }
        else if let value = try? single.decode(Double.self) { self = .number(value) }
        else if let value = try? single.decode(String.self) { self = .string(value) }
        else if let value = try? single.decode([UIValue].self) { self = .array(value) }
        else { self = .object(try single.decode([String: UIValue].self)) }
    }

    public init(json: Data) throws { self = try JSONDecoder().decode(UIValue.self, from: json) }

    /// Any encodable value as JSON, with dates as ISO 8601 instants.
    public init(encoding value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self = try JSONDecoder().decode(UIValue.self, from: encoder.encode(value))
    }

    var objectValue: [String: UIValue]? { if case .object(let value) = self { value } else { nil } }
    var arrayValue: [UIValue]? { if case .array(let value) = self { value } else { nil } }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var integerValue: Int? { if case .integer(let value) = self { value } else { nil } }

    subscript(key: String) -> UIValue? { objectValue?[key] }
}
