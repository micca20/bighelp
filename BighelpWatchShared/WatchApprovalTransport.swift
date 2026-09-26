import Foundation

enum WatchApprovalDecision: String, Codable, CaseIterable, Equatable, Sendable {
    case once
    case session
    case always
    case deny

    var buttonTitle: String {
        switch self {
        case .once: "Approve Once"
        case .session: "Approve Session"
        case .always: "Always Approve"
        case .deny: "Deny"
        }
    }
}

enum WatchApprovalConfirmationPolicy {
    static func requiresConfirmation(for decision: WatchApprovalDecision) -> Bool {
        decision == .session || decision == .always
    }
}

enum WatchApprovalValidationError: Error, Equatable {
    case missingField
    case fieldTooLong
    case invalidDecisions
    case invalidPayload
}

struct WatchApprovalRequest: Codable, Equatable, Sendable {
    let requestID: String
    let action: String
    let requester: String
    let vendor: String
    let amount: String
    let dueDate: String
    let category: String
    let consequence: String
    let allowedDecisions: [WatchApprovalDecision]
    var policy: String? = nil
    var expiresAt: Date? = nil
    var eventID: String? = nil
    var sessionID: String? = nil
    var agentID: String? = nil

    func validated() throws -> Self {
        for value in [policy, eventID, sessionID, agentID].compactMap({ $0 }) {
            guard value.utf8.count <= 500, !value.contains("\0") else {
                throw WatchApprovalValidationError.fieldTooLong
            }
        }
        guard expiresAt?.timeIntervalSince1970.isFinite != false else {
            throw WatchApprovalValidationError.invalidPayload
        }
        let required = [requestID, action, requester]
        guard required.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw WatchApprovalValidationError.missingField
        }
        guard requestID.utf8.count <= 128,
              action.utf8.count <= 240,
              requester.utf8.count <= 120,
              vendor.utf8.count <= 120,
              amount.utf8.count <= 80,
              dueDate.utf8.count <= 80,
              category.utf8.count <= 80,
              consequence.utf8.count <= 320,
              [requestID, action, requester, vendor, amount, dueDate, category, consequence].allSatisfy({ !$0.contains("\0") })
        else { throw WatchApprovalValidationError.fieldTooLong }
        guard !allowedDecisions.isEmpty,
              allowedDecisions.count <= WatchApprovalDecision.allCases.count,
              Set(allowedDecisions).count == allowedDecisions.count
        else { throw WatchApprovalValidationError.invalidDecisions }
        return self
    }
}

enum WatchApprovalContextUpdate: Equatable, Sendable {
    case request(WatchApprovalRequest)
    case clear
}

struct WatchApprovalAttempt: Equatable, Sendable {
    let requestID: String
    let decision: WatchApprovalDecision
    let attemptID: String

    func matches(
        requestID: String,
        decision: WatchApprovalDecision,
        attemptID: String
    ) -> Bool {
        self.requestID == requestID
            && self.decision == decision
            && self.attemptID == attemptID
    }
}

struct WatchApprovalDecisionMessage: Codable, Equatable, Sendable {
    let requestID: String
    let decision: WatchApprovalDecision
    let attemptID: String

    func validated() throws -> Self {
        guard !requestID.isEmpty, !attemptID.isEmpty else {
            throw WatchApprovalValidationError.missingField
        }
        guard requestID.count <= 128, attemptID.count <= 128 else {
            throw WatchApprovalValidationError.fieldTooLong
        }
        return self
    }
}

enum WatchApprovalDecisionResult: Codable, Equatable, Sendable {
    case succeeded(requestID: String, decision: WatchApprovalDecision)
    case failed(requestID: String, decision: WatchApprovalDecision, message: String)
}

enum WatchApprovalCodec {
    static let payloadKey = "approvalPayload"
    private static let clearKey = "approvalClear"
    private static let maximumPayloadBytes = 8_192

    static func encodeRequestContext(_ request: WatchApprovalRequest) throws -> [String: Any] {
        [payloadKey: try encode(try request.validated())]
    }

    static func decodeRequestContext(_ context: [String: Any]) throws -> WatchApprovalRequest {
        try decode(WatchApprovalRequest.self, from: context).validated()
    }

    static func encodeClearContext() -> [String: Any] {
        [clearKey: true]
    }

    static func decodeContextUpdate(_ context: [String: Any]) throws -> WatchApprovalContextUpdate {
        if Set(context.keys) == [clearKey], context[clearKey] as? Bool == true {
            return .clear
        }
        guard Set(context.keys) == [payloadKey] else {
            throw WatchApprovalValidationError.invalidPayload
        }
        return .request(try decodeRequestContext(context))
    }

    static func encodeDecisionMessage(_ message: WatchApprovalDecisionMessage) throws -> [String: Any] {
        [payloadKey: try encode(try message.validated())]
    }

    static func decodeDecisionMessage(_ message: [String: Any]) throws -> WatchApprovalDecisionMessage {
        try decode(WatchApprovalDecisionMessage.self, from: message).validated()
    }

    static func encodeDecisionResult(_ result: WatchApprovalDecisionResult) throws -> [String: Any] {
        [payloadKey: try encode(result)]
    }

    static func decodeDecisionResult(_ message: [String: Any]) throws -> WatchApprovalDecisionResult {
        try decode(WatchApprovalDecisionResult.self, from: message)
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let data = try PropertyListEncoder().encode(value)
        guard data.count <= maximumPayloadBytes else {
            throw WatchApprovalValidationError.invalidPayload
        }
        return data
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from container: [String: Any]
    ) throws -> Value {
        guard container.count == 1,
              let data = container[payloadKey] as? Data,
              data.count <= maximumPayloadBytes
        else { throw WatchApprovalValidationError.invalidPayload }
        return try PropertyListDecoder().decode(type, from: data)
    }
}
