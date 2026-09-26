import Foundation

struct LoopdyLinkGenerativeUIFormSubmission: Encodable, Equatable, Sendable {
    let version = 1
    let type = "generative.ui.form.submit"
    let requestID: String
    let sessionID: String
    let profile: String
    let idempotencyKey: UUID
    let values: [String: LoopdyJSONValue]
    let submittedAt: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case requestID = "requestId"
        case sessionID = "sessionId"
        case profile
        case idempotencyKey
        case values
        case submittedAt
    }

    init(
        requestID: String,
        sessionID: String,
        profile: String,
        idempotencyKey: UUID = UUID(),
        values: [String: LoopdyJSONValue],
        submittedAt: Int
    ) throws {
        guard
            submittedAt > 0,
            Self.accepts(
                requestID: requestID,
                sessionID: sessionID,
                profile: profile,
                values: values
            )
        else { throw LoopdyLinkWireError.invalidValue }
        self.requestID = requestID
        self.sessionID = sessionID
        self.profile = profile
        self.idempotencyKey = idempotencyKey
        self.values = values
        self.submittedAt = submittedAt
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(type, forKey: .type)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(profile, forKey: .profile)
        try container.encode(idempotencyKey.uuidString.lowercased(), forKey: .idempotencyKey)
        try container.encode(values, forKey: .values)
        try container.encode(submittedAt, forKey: .submittedAt)
    }

    static func accepts(
        requestID: String,
        sessionID: String,
        profile: String,
        values: [String: LoopdyJSONValue]
    ) -> Bool {
        requestID.count == 32
            && requestID.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) })
            && LoopdyLinkSessionCoordinate.isValid(sessionID)
            && LoopdyLinkPickerValidation.opaque(profile, minimum: 1, maximum: 80)
            && values.count <= 12
            && values.allSatisfy({ Self.acceptsFieldID($0.key) && Self.validValue($0.value) })
            && ((try? JSONEncoder().encode(values).count) ?? 8_193) <= 8_192
    }

    static func acceptsFieldID(_ value: String) -> Bool {
        guard (1...40).contains(value.count), value.first?.isLetter == true else { return false }
        return value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    private static func validValue(_ value: LoopdyJSONValue) -> Bool {
        switch value {
        case .string(let value):
            return value.count <= 2_000 && !value.contains("\0")
        case .number(let value):
            return value.isFinite && abs(value) <= 1_000_000_000_000
        case .integer(let value):
            return abs(Double(value)) <= 1_000_000_000_000
        case .boolean:
            return true
        case .array(let values):
            return values.count <= 10 && values.allSatisfy {
                if case .array = $0 { return false }
                if case .object = $0 { return false }
                if case .null = $0 { return false }
                return validValue($0)
            }
        case .object, .null:
            return false
        }
    }
}

struct LoopdyLinkGenerativeUIFormResult: Decodable, Equatable, Sendable {
    enum State: String, Decodable, Equatable, Sendable {
        case success
        case error
    }

    let requestID: String
    let sessionID: String
    let idempotencyKey: UUID
    let state: State
    let code: String
    let message: String
    let sentAt: Int

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let expected = Set([
            "version", "type", "requestId", "sessionId", "idempotencyKey",
            "state", "code", "message", "sentAt",
        ])
        guard Set(container.allKeys.map(\.stringValue)) == expected else {
            throw LoopdyLinkWireError.invalidValue
        }
        func key(_ value: String) -> AnyKey { AnyKey(stringValue: value)! }
        let rawID = try container.decode(String.self, forKey: key("idempotencyKey"))
        guard
            try container.decode(Int.self, forKey: key("version")) == 1,
            try container.decode(String.self, forKey: key("type")) == "generative.ui.form.result",
            let parsedID = UUID(uuidString: rawID),
            parsedID.uuidString.lowercased() == rawID
        else { throw LoopdyLinkWireError.invalidValue }
        requestID = try container.decode(String.self, forKey: key("requestId"))
        sessionID = try container.decode(String.self, forKey: key("sessionId"))
        idempotencyKey = parsedID
        state = try container.decode(State.self, forKey: key("state"))
        code = try container.decode(String.self, forKey: key("code"))
        message = try container.decode(String.self, forKey: key("message"))
        sentAt = try container.decode(Int.self, forKey: key("sentAt"))
        let codes = Set([
            "accepted", "request_not_found", "request_expired", "owner_mismatch",
            "invalid_value", "already_submitted", "already_consumed",
            "idempotency_conflict", "payload_too_large", "internal_error",
        ])
        guard
            requestID.count == 32,
            requestID.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }),
            LoopdyLinkSessionCoordinate.isValid(sessionID),
            codes.contains(code),
            !message.isEmpty,
            message.count <= 160,
            !message.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            sentAt > 0
        else { throw LoopdyLinkWireError.invalidValue }
    }
}
