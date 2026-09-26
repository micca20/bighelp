import Foundation

/// A bounded JSON reader that rejects duplicate (including escaped-equivalent) keys
/// and retains number lexemes. Foundation's Int decoding also accepts `5.0`;
/// OAuth intervals must instead be positive JSON integer tokens.
indirect enum GitHubJSON: Sendable {
    case object([String: GitHubJSON]), array([GitHubJSON]), string(String)
    case number(String), bool(Bool), null

    static func parse(_ data: Data, limit: Int = 2_097_152) throws -> GitHubJSON {
        guard data.count <= limit else { throw GitHubError.responseTooLarge }
        var parser = Parser(bytes: Array(data))
        let value = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw GitHubError.invalidResponse }
        return value
    }

    func object() throws -> [String: GitHubJSON] {
        guard case .object(let value) = self else { throw GitHubError.invalidResponse }
        return value
    }

    func array() throws -> [GitHubJSON] {
        guard case .array(let value) = self else { throw GitHubError.invalidResponse }
        return value
    }

    func string(max: Int = 1024, allowEmpty: Bool = false) throws -> String {
        guard case .string(let value) = self, value.utf8.count <= max,
              allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw GitHubError.invalidResponse }
        return value
    }

    func integer(min: Int = 0, max: Int = Int.max) throws -> Int {
        guard case .number(let raw) = self,
              !raw.contains("."), !raw.contains("e"), !raw.contains("E"),
              let value = Int(raw), value >= min, value <= max
        else { throw GitHubError.invalidResponse }
        return value
    }

    /// Preserve exact REST IDs beyond Double/Int precision. Reject signs/fractions/exponents.
    func decimalID() throws -> String {
        guard case .number(let raw) = self, raw.utf8.count <= 40,
              let first = raw.utf8.first, (49...57).contains(first),
              raw.utf8.allSatisfy({ (48...57).contains($0) }) else { throw GitHubError.invalidResponse }
        return raw
    }

    func boolean() throws -> Bool {
        guard case .bool(let value) = self else { throw GitHubError.invalidResponse }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func whitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            whitespace()
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func value(depth: Int) throws -> GitHubJSON {
            whitespace()
            guard depth < 32, index < bytes.count else { throw GitHubError.invalidResponse }
            switch bytes[index] {
            case 123:
                index += 1
                var result: [String: GitHubJSON] = [:]
                if consume(125) { return .object(result) }
                repeat {
                    whitespace()
                    let key = try text()
                    guard result[key] == nil, consume(58) else { throw GitHubError.invalidResponse }
                    result[key] = try value(depth: depth + 1)
                    if consume(125) { return .object(result) }
                    guard consume(44) else { throw GitHubError.invalidResponse }
                } while true
            case 91:
                index += 1
                var result: [GitHubJSON] = []
                if consume(93) { return .array(result) }
                repeat {
                    guard result.count < 10_000 else { throw GitHubError.responseTooLarge }
                    result.append(try value(depth: depth + 1))
                    if consume(93) { return .array(result) }
                    guard consume(44) else { throw GitHubError.invalidResponse }
                } while true
            case 34: return .string(try text())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            case 45, 48...57:
                let start = index
                if bytes[index] == 45 { index += 1 }
                guard index < bytes.count else { throw GitHubError.invalidResponse }
                if bytes[index] == 48 { index += 1 }
                else {
                    guard (49...57).contains(bytes[index]) else { throw GitHubError.invalidResponse }
                    digits()
                }
                if index < bytes.count, bytes[index] == 46 {
                    index += 1
                    let before = index
                    digits()
                    guard index > before else { throw GitHubError.invalidResponse }
                }
                if index < bytes.count, [69, 101].contains(bytes[index]) {
                    index += 1
                    if index < bytes.count, [43, 45].contains(bytes[index]) { index += 1 }
                    let before = index
                    digits()
                    guard index > before else { throw GitHubError.invalidResponse }
                }
                return .number(String(decoding: bytes[start..<index], as: UTF8.self))
            default: throw GitHubError.invalidResponse
            }
        }

        mutating func digits() {
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        }

        mutating func literal(_ text: String) throws {
            let expected = Array(text.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected
            else { throw GitHubError.invalidResponse }
            index += expected.count
        }

        mutating func text() throws -> String {
            guard index < bytes.count, bytes[index] == 34 else { throw GitHubError.invalidResponse }
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 34 {
                    let data = Data(bytes[start..<index])
                    guard let result = try? JSONDecoder().decode(String.self, from: data)
                    else { throw GitHubError.invalidResponse }
                    return result
                }
                if byte == 92 {
                    guard index < bytes.count else { throw GitHubError.invalidResponse }
                    index += 1
                } else if byte < 32 { throw GitHubError.invalidResponse }
            }
            throw GitHubError.invalidResponse
        }
    }
}

extension Dictionary where Key == String, Value == GitHubJSON {
    func required(_ key: String) throws -> GitHubJSON {
        guard let value = self[key] else { throw GitHubError.invalidResponse }
        return value
    }

    func optionalString(_ key: String, max: Int) throws -> String? {
        guard let value = self[key] else { return nil }
        if case .null = value { return nil }
        return try value.string(max: max, allowEmpty: true)
    }
}
