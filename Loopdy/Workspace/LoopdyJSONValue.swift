import Foundation

enum LoopdyJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case integer(Int)
    case boolean(Bool)
    case object([String: LoopdyJSONValue])
    case array([LoopdyJSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: LoopdyJSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([LoopdyJSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var number: Double? {
        switch self {
        case .number(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }

    var integer: Int? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    var boolean: Bool? {
        guard case .boolean(let value) = self else { return nil }
        return value
    }

    var object: [String: LoopdyJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var array: [LoopdyJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var displayText: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.formatted(.number.precision(.fractionLength(0...2)))
        case .integer(let value): value.formatted()
        case .boolean(let value): value ? "Yes" : "No"
        default: nil
        }
    }
}
