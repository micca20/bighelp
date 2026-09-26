import Foundation

/// Small bounded JSON grammar. Foundation decoders accept duplicate object
/// keys; check the original bytes before any dictionary conversion instead.
/// No repair of UTF-8, lone surrogates, numbers, or escaped-equivalent keys.
indirect enum ReferenceJSONValue: Sendable {
    case object([String: ReferenceJSONValue])
    case array([ReferenceJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    var object: [String: ReferenceJSONValue]? {
        if case .object(let value) = self { return value }; return nil
    }
    var array: [ReferenceJSONValue]? {
        if case .array(let value) = self { return value }; return nil
    }
    var string: String? {
        if case .string(let value) = self { return value }; return nil
    }
    var boolean: Bool? {
        if case .bool(let value) = self { return value }; return nil
    }
    var integer: Int? {
        guard case .number(let value) = self,
              !value.contains("."), !value.contains("e"), !value.contains("E") else { return nil }
        return Int(value)
    }
    var double: Double? {
        guard case .number(let value) = self, let number = Double(value), number.isFinite else { return nil }
        return number
    }
}

struct ReferenceStrictJSONParser: Sendable {
    private let bytes: [UInt8]
    private var index = 0
    private var nodes = 0

    init(data: Data) throws {
        guard data.count <= ReferenceCodec.maximumAppendixBytes else { throw ReferenceCodec.Failure.tooLarge }
        bytes = Array(data)
    }

    mutating func parse() throws -> ReferenceJSONValue {
        let value = try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw ReferenceCodec.Failure.malformedJSON }
        return value
    }

    private mutating func value(depth: Int) throws -> ReferenceJSONValue {
        nodes += 1
        guard depth <= 12, nodes <= 2_048 else { throw ReferenceCodec.Failure.tooLarge }
        whitespace()
        guard index < bytes.count else { throw ReferenceCodec.Failure.malformedJSON }
        switch bytes[index] {
        case 123:
            index += 1
            whitespace()
            var object: [String: ReferenceJSONValue] = [:]
            if consume(125) { return .object(object) }
            while true {
                whitespace()
                let key = try string()
                guard object[key] == nil else { throw ReferenceCodec.Failure.duplicateKey }
                whitespace()
                guard consume(58) else { throw ReferenceCodec.Failure.malformedJSON }
                object[key] = try value(depth: depth + 1)
                whitespace()
                if consume(125) { return .object(object) }
                guard consume(44) else { throw ReferenceCodec.Failure.malformedJSON }
            }
        case 91:
            index += 1
            whitespace()
            var array: [ReferenceJSONValue] = []
            if consume(93) { return .array(array) }
            while true {
                array.append(try value(depth: depth + 1))
                whitespace()
                if consume(93) { return .array(array) }
                guard consume(44) else { throw ReferenceCodec.Failure.malformedJSON }
            }
        case 34: return .string(try string())
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 110: try literal("null"); return .null
        case 45, 48...57: return .number(try number())
        default: throw ReferenceCodec.Failure.malformedJSON
        }
    }

    private mutating func string() throws -> String {
        guard consume(34) else { throw ReferenceCodec.Failure.malformedJSON }
        var output: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 {
                guard String(bytes: output, encoding: .utf8) != nil else { throw ReferenceCodec.Failure.malformedJSON }
                // A JSON string's leading U+FEFF is content, not a file marker.
                // Validate first, then preserve every valid UTF-8 scalar.
                return String(decoding: output, as: UTF8.self)
            }
            guard byte >= 32 else { throw ReferenceCodec.Failure.malformedJSON }
            if byte != 92 { output.append(byte); continue }
            guard index < bytes.count else { throw ReferenceCodec.Failure.malformedJSON }
            let escape = bytes[index]
            index += 1
            switch escape {
            case 34, 47, 92: output.append(escape)
            case 98: output.append(8)
            case 102: output.append(12)
            case 110: output.append(10)
            case 114: output.append(13)
            case 116: output.append(9)
            case 117:
                let first = try hexQuad()
                let scalarValue: UInt32
                if (0xD800...0xDBFF).contains(first) {
                    guard consume(92), consume(117) else { throw ReferenceCodec.Failure.malformedJSON }
                    let second = try hexQuad()
                    guard (0xDC00...0xDFFF).contains(second) else { throw ReferenceCodec.Failure.malformedJSON }
                    scalarValue = 0x10000 + ((first - 0xD800) << 10) + second - 0xDC00
                } else {
                    guard !(0xDC00...0xDFFF).contains(first) else { throw ReferenceCodec.Failure.malformedJSON }
                    scalarValue = first
                }
                guard let scalar = UnicodeScalar(scalarValue) else { throw ReferenceCodec.Failure.malformedJSON }
                output.append(contentsOf: String(scalar).utf8)
            default: throw ReferenceCodec.Failure.malformedJSON
            }
        }
        throw ReferenceCodec.Failure.malformedJSON
    }

    private mutating func hexQuad() throws -> UInt32 {
        guard bytes.count - index >= 4 else { throw ReferenceCodec.Failure.malformedJSON }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            index += 1
            let digit: UInt32
            switch byte {
            case 48...57: digit = UInt32(byte - 48)
            case 65...70: digit = UInt32(byte - 55)
            case 97...102: digit = UInt32(byte - 87)
            default: throw ReferenceCodec.Failure.malformedJSON
            }
            value = value * 16 + digit
        }
        return value
    }

    private mutating func number() throws -> String {
        let start = index
        _ = consume(45)
        guard index < bytes.count else { throw ReferenceCodec.Failure.malformedJSON }
        if !consume(48) {
            guard (49...57).contains(bytes[index]) else { throw ReferenceCodec.Failure.malformedJSON }
            digits()
        }
        if consume(46) {
            let start = index
            digits()
            guard index > start else { throw ReferenceCodec.Failure.malformedJSON }
        }
        if consume(101) || consume(69) {
            if !consume(43) { _ = consume(45) }
            let start = index
            digits()
            guard index > start else { throw ReferenceCodec.Failure.malformedJSON }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func digits() {
        while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
    }

    private mutating func literal(_ value: String) throws {
        for byte in value.utf8 {
            guard consume(byte) else { throw ReferenceCodec.Failure.malformedJSON }
        }
    }

    private mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
