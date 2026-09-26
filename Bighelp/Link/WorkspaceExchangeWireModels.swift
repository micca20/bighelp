import Foundation

struct BighelpLinkWorkspaceRequest: Encodable, Equatable, Sendable {
    let requestID: String
    let operation: BighelpLinkWorkspaceOperation
    let payload: [String: BighelpJSONValue]
    let sentAt: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case requestID = "requestId"
        case operation
        case payload
        case sentAt
    }

    init(
        requestID: String,
        operation: BighelpLinkWorkspaceOperation,
        payload: [String: BighelpJSONValue],
        sentAt: Int
    ) throws {
        guard
            Self.opaque(requestID, minimum: 16, maximum: 128),
            sentAt > 0,
            Self.valid(
                .object(payload),
                depth: 0,
                maximumStringBytes: BighelpLinkWorkspacePayloadLimits.requestStringBytes(
                    for: operation
                )
            ),
            let encoded = try? JSONEncoder().encode(BighelpJSONValue.object(payload)),
            encoded.count <= BighelpLinkWorkspacePayloadLimits.requestBytes(for: operation)
        else { throw BighelpLinkWireError.invalidValue }
        self.requestID = requestID
        self.operation = operation
        self.payload = payload
        self.sentAt = sentAt
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode("workspace.request", forKey: .type)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(operation, forKey: .operation)
        try container.encode(payload, forKey: .payload)
        try container.encode(sentAt, forKey: .sentAt)
    }

    private static let forbiddenKeys = Set([
        "authorization", "cookie", "credential", "gateway", "gatewaytoken",
        "gatewayurl", "password", "secret", "token",
    ])
    private static let forbiddenStringControls = CharacterSet.controlCharacters.subtracting(
        CharacterSet(charactersIn: "\n\r\t")
    )

    private static func valid(
        _ value: BighelpJSONValue,
        depth: Int,
        maximumStringBytes: Int
    ) -> Bool {
        guard depth <= 8 else { return false }
        switch value {
        case .string(let value):
            return value.utf8.count <= maximumStringBytes
                && !value.unicodeScalars.contains(where: {
                    forbiddenStringControls.contains($0)
                })
        case .number(let value):
            return value.isFinite
        case .integer:
            return true
        case .boolean, .null:
            return true
        case .array(let values):
            return values.count <= 500
                && values.allSatisfy {
                    valid(
                        $0,
                        depth: depth + 1,
                        maximumStringBytes: maximumStringBytes
                    )
                }
        case .object(let values):
            return values.count <= 200 && values.allSatisfy { key, value in
                let canonical = key
                    .lowercased()
                    .filter { $0.isLetter || $0.isNumber }
                return !key.isEmpty
                    && key.utf8.count <= 64
                    && key.allSatisfy {
                        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".")
                    }
                    && !forbiddenKeys.contains(canonical)
                    && valid(
                        value,
                        depth: depth + 1,
                        maximumStringBytes: maximumStringBytes
                    )
            }
        }
    }

    private static func opaque(_ value: String, minimum: Int, maximum: Int) -> Bool {
        (minimum...maximum).contains(value.count)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// A rejection intentionally has no operation enum: the host may not know it.

struct BighelpLinkWorkspaceContext: Decodable, Equatable, Sendable {
    let sessionID: String
    let available: Bool
    let snapshot: SessionContextSnapshot?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: BighelpLinkSessionEventKey.self)
        func key(_ name: String) -> BighelpLinkSessionEventKey {
            BighelpLinkSessionEventKey(stringValue: name)!
        }
        guard Set(container.allKeys.map(\.stringValue)) == ["sessionId", "available", "snapshot"] else {
            throw BighelpLinkWireError.invalidValue
        }
        sessionID = try container.decode(String.self, forKey: key("sessionId"))
        available = try container.decode(Bool.self, forKey: key("available"))
        guard BighelpLinkSessionCoordinate.isValid(sessionID) else {
            throw BighelpLinkWireError.invalidValue
        }
        if available {
            let value = try BighelpLinkSessionEventValidation.context(
                from: container.superDecoder(forKey: key("snapshot"))
            )
            guard value.sessionId == sessionID else { throw BighelpLinkWireError.invalidValue }
            snapshot = value
        } else {
            guard try container.decodeNil(forKey: key("snapshot")) else {
                throw BighelpLinkWireError.invalidValue
            }
            snapshot = nil
        }
    }
}

struct BighelpLinkWorkspaceResult: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Equatable, Sendable {
        case completed
        case failed
        case conflict
    }

    let requestID: String
    let operation: BighelpLinkWorkspaceOperation
    let status: Status
    let payload: [String: BighelpJSONValue]
    let capabilities: BighelpLinkWorkspaceCapabilities?
    let context: BighelpLinkWorkspaceContext?
    let code: String?
    let message: String?
    let sentAt: Int

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let required = Set([
            "version", "type", "requestId", "operation", "status", "payload", "sentAt",
        ])
        let optional = Set(["code", "message", "capabilities", "context"])
        let keys = Set(container.allKeys.map(\.stringValue))
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw BighelpLinkWireError.invalidValue
        }
        func key(_ value: String) -> AnyKey { AnyKey(stringValue: value)! }
        guard
            try container.decode(Int.self, forKey: key("version")) == 1,
            try container.decode(String.self, forKey: key("type")) == "workspace.result"
        else { throw BighelpLinkWireError.invalidValue }
        requestID = try container.decode(String.self, forKey: key("requestId"))
        operation = try container.decode(
            BighelpLinkWorkspaceOperation.self,
            forKey: key("operation")
        )
        status = try container.decode(Status.self, forKey: key("status"))
        payload = try container.decode(
            [String: BighelpJSONValue].self,
            forKey: key("payload")
        )
        capabilities = try container.decodeIfPresent(
            BighelpLinkWorkspaceCapabilities.self, forKey: key("capabilities")
        )
        context = container.contains(key("context"))
            ? try container.decode(BighelpLinkWorkspaceContext.self, forKey: key("context"))
            : nil
        if context != nil, operation != .sessionHistory || status != .completed {
            throw BighelpLinkWireError.invalidValue
        }
        code = try container.decodeIfPresent(String.self, forKey: key("code"))
        message = try container.decodeIfPresent(String.self, forKey: key("message"))
        sentAt = try container.decode(Int.self, forKey: key("sentAt"))
        guard
            (16...128).contains(requestID.count),
            !requestID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            sentAt > 0,
            (code == nil) == (message == nil),
            code.map({
                !$0.isEmpty && $0.count <= 80 && $0.allSatisfy {
                    $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
                }
            }) ?? true,
            message.map({
                !$0.isEmpty
                    && $0.utf8.count <= 2_000
                    && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }) ?? true,
            let encoded = try? JSONEncoder().encode(BighelpJSONValue.object(payload)),
            encoded.count <= BighelpLinkWorkspacePayloadLimits.resultBytes(for: operation)
        else { throw BighelpLinkWireError.invalidValue }
    }
}

private struct BighelpLinkSessionEventKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private enum BighelpLinkSessionEventValidation {
    static func label(_ value: String, maximum: Int) -> Bool {
        BighelpLinkPickerValidation.label(value, maximum: maximum) != nil
    }

    static func key(_ value: String) -> BighelpLinkSessionEventKey {
        BighelpLinkSessionEventKey(stringValue: value)!
    }

    static func header(
        _ container: KeyedDecodingContainer<BighelpLinkSessionEventKey>,
        type: String,
        keys: Set<String>
    ) throws -> String {
        guard
            Set(container.allKeys.map(\.stringValue)) == keys,
            try container.decode(Int.self, forKey: key("version")) == 1,
            try container.decode(String.self, forKey: key("type")) == type
        else { throw BighelpLinkWireError.invalidValue }
        let sessionID = try container.decode(String.self, forKey: key("sessionId"))
        guard BighelpLinkSessionCoordinate.isValid(sessionID) else {
            throw BighelpLinkWireError.invalidValue
        }
        return sessionID
    }

    static func context(from decoder: any Decoder) throws -> SessionContextSnapshot {
        let container = try decoder.container(keyedBy: BighelpLinkSessionEventKey.self)
        let contextKeys: Set<String> = [
            "version", "type", "sessionId", "model", "contextUsed", "contextMax",
            "contextPercent", "compressions", "isCompacting", "updatedAt",
        ]
        // Token accounting and the streaming title are additive. Older Hermes
        // plugins omit them, so the strict key-set check unions only the
        // optional keys this envelope actually carries.
        let optionalKeys = [
            "title", "inputTokens", "outputTokens", "cachedTokens", "totalTokens",
            "sessionInputTokens", "sessionOutputTokens", "sessionCachedTokens", "sessionTotalTokens",
            "sessionIncludesSubagents",
        ]
            .filter { container.contains(key($0)) }
        let sessionID = try header(
            container,
            type: "session.context",
            keys: contextKeys.union(optionalKeys)
        )
        let title = try container.decodeIfPresent(String.self, forKey: key("title"))
        let model = try container.decode(String.self, forKey: key("model"))
        let contextUsed = try container.decode(Int.self, forKey: key("contextUsed"))
        let contextMax = try container.decode(Int.self, forKey: key("contextMax"))
        let contextPercent = try container.decode(Int.self, forKey: key("contextPercent"))
        let compressions = try container.decode(Int.self, forKey: key("compressions"))
        let isCompacting = try container.decode(Bool.self, forKey: key("isCompacting"))
        let updatedAt = try container.decode(Int.self, forKey: key("updatedAt"))
        let inputTokens = try container.decodeIfPresent(Int.self, forKey: key("inputTokens"))
        let outputTokens = try container.decodeIfPresent(Int.self, forKey: key("outputTokens"))
        let cachedTokens = try container.decodeIfPresent(Int.self, forKey: key("cachedTokens"))
        let totalTokens = try container.decodeIfPresent(Int.self, forKey: key("totalTokens"))
        let sessionInputTokens = try container.decodeIfPresent(Int.self, forKey: key("sessionInputTokens"))
        let sessionOutputTokens = try container.decodeIfPresent(Int.self, forKey: key("sessionOutputTokens"))
        let sessionCachedTokens = try container.decodeIfPresent(Int.self, forKey: key("sessionCachedTokens"))
        let sessionTotalTokens = try container.decodeIfPresent(Int.self, forKey: key("sessionTotalTokens"))
        let sessionIncludesSubagents = try container.decodeIfPresent(Bool.self, forKey: key("sessionIncludesSubagents"))
        let tokenAccountingIsValid = [
            inputTokens, outputTokens, cachedTokens, totalTokens,
            sessionInputTokens, sessionOutputTokens, sessionCachedTokens, sessionTotalTokens,
        ]
            .allSatisfy({ candidate in
                guard let candidate else { return true }
                return candidate >= 0
            })
        guard
            title.map({ label($0, maximum: 240) }) ?? true,
            label(model, maximum: 160),
            contextUsed >= 0,
            contextMax > 0,
            (0...100).contains(contextPercent),
            compressions >= 0,
            updatedAt > 0,
            tokenAccountingIsValid
        else { throw BighelpLinkWireError.invalidValue }
        return SessionContextSnapshot(
            sessionId: sessionID,
            title: title,
            model: model,
            contextUsed: contextUsed,
            contextMax: contextMax,
            contextPercent: contextPercent,
            compressions: compressions,
            isCompacting: isCompacting,
            updatedAt: updatedAt,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedTokens: cachedTokens,
            totalTokens: totalTokens,
            sessionInputTokens: sessionInputTokens,
            sessionOutputTokens: sessionOutputTokens,
            sessionCachedTokens: sessionCachedTokens,
            sessionTotalTokens: sessionTotalTokens,
            sessionIncludesSubagents: sessionIncludesSubagents
        )
    }

}
