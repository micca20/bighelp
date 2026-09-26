import Foundation

enum HermesLogCodec {
    static let maximumLineBytes = 32_768

    static func entry(_ rawValue: String, id: Int) throws -> HermesLogEntry {
        guard rawValue.utf8.count <= maximumLineBytes,
              !rawValue.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw HermesLogsClientError.invalidResponse
        }
        // Redact before splitting header/message so an Authorization-like
        // logger field cannot strip the context needed to recognize a secret.
        let line = HermesLogRedactor.redact(rawValue.trimmingCharacters(in: .newlines))
        guard let parsed = parseHeader(line) else {
            return HermesLogEntry(
                id: id,
                timestamp: nil,
                timestampText: nil,
                severity: .unclassified,
                logger: nil,
                message: line
            )
        }
        return HermesLogEntry(
            id: id,
            timestamp: parsed.date,
            timestampText: parsed.text,
            severity: parsed.severity,
            logger: parsed.logger,
            message: parsed.message
        )
    }

    private struct Header {
        let date: Date?
        let text: String
        let severity: HermesLogSeverity
        let logger: String?
        let message: String
    }

    private static func parseHeader(_ line: String) -> Header? {
        guard line.count >= 19, line.utf8.count >= 25 else { return nil }
        let bytes = Array(line.prefix(19).utf8)
        guard bytes.count == 19,
              bytes[4] == 45, bytes[7] == 45, bytes[10] == 32,
              bytes[13] == 58, bytes[16] == 58 else { return nil }

        var cursor = line.index(line.startIndex, offsetBy: 19)
        var millisecond = 0
        var timestampEnd = cursor
        if cursor < line.endIndex, line[cursor] == "," {
            let digitsStart = line.index(after: cursor)
            guard let digitsEnd = line.index(digitsStart, offsetBy: 3, limitedBy: line.endIndex) else { return nil }
            let digits = line[digitsStart..<digitsEnd]
            guard digits.utf8.count == 3, let parsed = Int(digits) else { return nil }
            millisecond = parsed
            cursor = digitsEnd
            timestampEnd = digitsEnd
        }
        skipWhitespace(in: line, cursor: &cursor)
        guard cursor < line.endIndex else { return nil }

        let levelEnd = line[cursor...].firstIndex(where: { $0 == " " || $0 == "\t" }) ?? line.endIndex
        guard let severity = HermesLogSeverity(rawValue: String(line[cursor..<levelEnd])),
              severity != .unclassified else { return nil }
        cursor = levelEnd
        skipWhitespace(in: line, cursor: &cursor)

        if cursor < line.endIndex, line[cursor] == "[",
           let close = line[cursor...].firstIndex(of: "]") {
            cursor = line.index(after: close)
            skipWhitespace(in: line, cursor: &cursor)
        }

        var logger: String?
        var messageStart = cursor
        if cursor < line.endIndex, let colon = line[cursor...].firstIndex(of: ":") {
            let candidate = String(line[cursor..<colon])
            if !candidate.isEmpty, candidate.utf8.count <= 512,
               !candidate.contains(where: { $0.isWhitespace }) {
                logger = candidate
                messageStart = line.index(after: colon)
                if messageStart < line.endIndex, line[messageStart].isWhitespace {
                    messageStart = line.index(after: messageStart)
                }
            }
        }

        return Header(
            date: date(from: bytes, millisecond: millisecond),
            text: String(line[..<timestampEnd]),
            severity: severity,
            logger: logger,
            message: String(line[messageStart...])
        )
    }

    private static func skipWhitespace(in value: String, cursor: inout String.Index) {
        while cursor < value.endIndex, value[cursor].isWhitespace {
            cursor = value.index(after: cursor)
        }
    }

    private static func date(from bytes: [UInt8], millisecond: Int) -> Date? {
        func number(_ range: Range<Int>) -> Int? {
            Int(String(decoding: bytes[range], as: UTF8.self))
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = millisecond * 1_000_000
        return calendar.date(from: components)
    }
}

/// Hermes applies its RedactingFormatter before writing standard logs. This
/// bounded native pass mirrors its highest-value credential shapes so a host
/// with redaction disabled cannot send an obviously reusable secret to the UI.
enum HermesLogRedactor {
    private static let substitutions: [(pattern: String, replacement: String)] = [
        (#"(?i)((?:proxy-)?authorization\s*:\s*(?:[A-Za-z][A-Za-z0-9._-]*\s+)?)[^\s\"']+"#, "$1«redacted-secret»"),
        (#"(?i)((?:x-api-key|x-goog-api-key|api-key|apikey|x-api-token|x-auth-token|x-access-token)\s*:\s*)\S+"#, "$1«redacted-secret»"),
        (#"(?i)(\"(?:api_?key|token|secret|password|access_token|refresh_token|auth_token|bearer|secret_value|raw_secret|secret_input|key_material)\"\s*:\s*\")[^\"]+(\")"#, "$1«redacted-secret»$2"),
        (#"(?i)([?&;](?:access_token|refresh_token|id_token|token|api_key|apikey|client_secret|password|auth|jwt|session|secret|key|code|signature|x-amz-signature)=)[^&#;\s]+"#, "$1«redacted-secret»"),
        (#"(?i)(\b(?:[A-Z0-9]+_)*(?:API_?KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)(?:_[A-Z0-9]+)*\s*=\s*)[^\s]{8,}"#, "$1«redacted-secret»"),
        (#"(?i)((?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://[^:\s]+:)[^@\s]+(@)"#, "$1«redacted-secret»$2"),
        (#"eyJ[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_=-]{4,}){0,2}"#, "«redacted-secret»"),
        (#"(?i)\b(?:sk-|ghp_|github_pat_|gho_|ghu_|ghs_|ghr_|xapp-|xox[baprs]-|AIza|pplx-|fal_|fc-|bb_live_|gAAAA|sk_live_|sk_test_|rk_live_|SG\.|hf_|r8_|npm_|pypi-|dop_v1_|doo_v1_|gsk_|xai-|glpat-)[A-Za-z0-9._=-]{8,}"#, "«redacted-secret»"),
    ]

    static func redact(_ value: String) -> String {
        if value.localizedCaseInsensitiveContains("-----BEGIN"),
           value.localizedCaseInsensitiveContains("PRIVATE KEY-----") {
            return "[REDACTED PRIVATE KEY]"
        }
        var result = value
        for substitution in substitutions {
            result = result.replacingOccurrences(
                of: substitution.pattern,
                with: substitution.replacement,
                options: .regularExpression
            )
        }
        return result
    }
}
