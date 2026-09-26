import Foundation

enum WatchCompanionValidationError: Error, Equatable {
    case missingField
    case fieldTooLong
    case tooManyItems
    case invalidPayload
}

struct WatchWeatherSummary: Codable, Equatable, Sendable {
    let city: String
    let temperature: Int
    let condition: String
    let systemImage: String
}

struct WatchInboxItem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case update
        case clarification
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let agentName: String
    let agentRole: String
    let createdAt: Date
    let choices: [String]
    let allowsCustomResponse: Bool
    var phoneActionReason: String? = nil
    var expiresAt: Date? = nil
    var canDismiss: Bool = false
    var requestID: String? = nil
    var sessionID: String? = nil
    var agentID: String? = nil
}

struct WatchSessionSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let agentName: String
    let preview: String
    let updatedAt: Date
    let isActive: Bool
}

struct WatchTranscriptItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let speaker: String
    let text: String
    let timestamp: Date
    let isUser: Bool
}

struct WatchVoiceResult: Codable, Equatable, Sendable {
    let attemptID: String
    let speaker: String
    let text: String
    let errorMessage: String?
}

struct WatchCompanionSnapshot: Codable, Equatable, Sendable {
    let generatedAt: Date
    let weather: WatchWeatherSummary?
    let inbox: [WatchInboxItem]
    let approvals: [WatchApprovalRequest]
    let sessions: [WatchSessionSummary]
    let selectedSessionID: String?
    let transcript: [WatchTranscriptItem]
    var voiceResult: WatchVoiceResult? = nil

    func validated() throws -> Self {
        guard generatedAt.timeIntervalSince1970.isFinite,
              Set(inbox.map(\.id)).count == inbox.count,
              Set(approvals.map(\.requestID)).count == approvals.count,
              Set(sessions.map(\.id)).count == sessions.count,
              Set(transcript.map(\.id)).count == transcript.count else {
            throw WatchCompanionValidationError.invalidPayload
        }
        guard inbox.count <= 12, approvals.count <= 8, sessions.count <= 16,
              transcript.count <= 16 else {
            throw WatchCompanionValidationError.tooManyItems
        }
        try inbox.forEach { item in
            guard item.createdAt.timeIntervalSince1970.isFinite else { throw WatchCompanionValidationError.invalidPayload }
            try Self.require(item.id, maximum: 180)
            try Self.require(item.title, maximum: 160)
            try Self.require(item.detail, maximum: 600)
            try Self.require(item.agentName, maximum: 120)
            try Self.optional(item.agentRole, maximum: 120)
            if let reason = item.phoneActionReason { try Self.require(reason, maximum: 240) }
            for coordinate in [item.requestID, item.sessionID, item.agentID].compactMap({ $0 }) {
                try Self.require(coordinate, maximum: 180)
            }
            guard item.expiresAt?.timeIntervalSince1970.isFinite != false else {
                throw WatchCompanionValidationError.invalidPayload
            }
            guard item.choices.count <= 4 else { throw WatchCompanionValidationError.tooManyItems }
            try item.choices.forEach { try Self.require($0, maximum: 500) }
        }
        try approvals.forEach { _ = try $0.validated() }
        try sessions.forEach { session in
            guard session.updatedAt.timeIntervalSince1970.isFinite else { throw WatchCompanionValidationError.invalidPayload }
            try Self.require(session.id, maximum: 180)
            try Self.require(session.title, maximum: 180)
            try Self.require(session.agentName, maximum: 120)
            try Self.optional(session.preview, maximum: 400)
        }
        if let selectedSessionID {
            try Self.require(selectedSessionID, maximum: 180)
            guard sessions.contains(where: { $0.id == selectedSessionID }) else {
                throw WatchCompanionValidationError.invalidPayload
            }
        } else if !transcript.isEmpty {
            throw WatchCompanionValidationError.invalidPayload
        }
        try transcript.forEach { item in
            guard item.timestamp.timeIntervalSince1970.isFinite else { throw WatchCompanionValidationError.invalidPayload }
            try Self.require(item.id, maximum: 180)
            try Self.require(item.speaker, maximum: 120)
            try Self.require(item.text, maximum: 1_200)
        }
        if let weather {
            try Self.require(weather.city, maximum: 120)
            try Self.require(weather.condition, maximum: 120)
            try Self.require(weather.systemImage, maximum: 80)
            guard (-200...200).contains(weather.temperature) else {
                throw WatchCompanionValidationError.invalidPayload
            }
        }
        if let voiceResult {
            try Self.require(voiceResult.attemptID, maximum: 128)
            try Self.require(voiceResult.speaker, maximum: 120)
            try Self.optional(voiceResult.text, maximum: 1_200)
            if let errorMessage = voiceResult.errorMessage {
                try Self.require(errorMessage, maximum: 240)
            } else if voiceResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw WatchCompanionValidationError.missingField
            }
        }
        return self
    }

    fileprivate static func require(_ value: String, maximum: Int) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw WatchCompanionValidationError.missingField }
        try optional(value, maximum: maximum)
    }

    fileprivate static func optional(_ value: String, maximum: Int) throws {
        guard value.utf8.count <= maximum, !value.contains("\0") else {
            throw WatchCompanionValidationError.fieldTooLong
        }
    }
}

enum WatchCompanionCommand: Codable, Equatable, Sendable {
    case refresh
    case enrollDirectClient(WatchBighelpEnrollmentRequest)
    case directEnrollmentReceived(requestID: String)
    case selectSession(id: String)
    case dismissInbox(id: String)
    case respondToClarification(itemID: String, response: String)
    case approval(WatchApprovalDecisionMessage)
    case voiceTurn(sessionID: String, transcript: String, attemptID: String)

    func validated() throws -> Self {
        switch self {
        case .refresh:
            break
        case .enrollDirectClient(let request):
            _ = try WatchBighelpEnrollmentRequest(
                requestID: request.requestID,
                deviceID: request.deviceID,
                publicKeySPKI: request.publicKeySPKI,
                agreementPublicKey: request.agreementPublicKey,
                deviceName: request.deviceName,
                deliveryVersion: request.deliveryVersion
            )
        case .directEnrollmentReceived(let requestID):
            guard (16...128).contains(requestID.count),
                  requestID.allSatisfy({
                    $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
                  }) else {
                throw WatchCompanionValidationError.invalidPayload
            }
        case .selectSession(let id), .dismissInbox(let id):
            try WatchCompanionSnapshot.require(id, maximum: 180)
        case .respondToClarification(let itemID, let response):
            try WatchCompanionSnapshot.require(itemID, maximum: 180)
            try WatchCompanionSnapshot.require(response, maximum: 10_000)
        case .approval(let message):
            _ = try message.validated()
        case .voiceTurn(let sessionID, let transcript, let attemptID):
            try WatchCompanionSnapshot.require(sessionID, maximum: 180)
            try WatchCompanionSnapshot.require(transcript, maximum: 10_000)
            try WatchCompanionSnapshot.require(attemptID, maximum: 128)
        }
        return self
    }
}

enum WatchCompanionReply: Codable, Equatable, Sendable {
    case snapshot(WatchCompanionSnapshot)
    case enrollmentAccepted(requestID: String)
    case directEnrollment(WatchBighelpEnrollmentGrant)
    case approval(
        requestID: String,
        attemptID: String,
        decision: WatchApprovalDecision,
        snapshot: WatchCompanionSnapshot
    )
    case voice(speaker: String, text: String, snapshot: WatchCompanionSnapshot)
    case failed(attemptID: String?, message: String, snapshot: WatchCompanionSnapshot?)
}

private enum WatchCompanionEnvelope: Codable {
    case snapshot(WatchCompanionSnapshot)
    case command(WatchCompanionCommand)
    case reply(WatchCompanionReply)
}

enum WatchCompanionCodec {
    static let payloadKey = "companionPayload"
    private static let maximumPayloadBytes = 60_000

    static func encodeSnapshotContext(_ snapshot: WatchCompanionSnapshot) throws -> [String: Any] {
        [payloadKey: try encode(WatchCompanionEnvelope.snapshot(try snapshot.validated()))]
    }

    static func decodeSnapshotContext(_ context: [String: Any]) throws -> WatchCompanionSnapshot {
        guard case .snapshot(let snapshot) = try decode(context) else {
            throw WatchCompanionValidationError.invalidPayload
        }
        return try snapshot.validated()
    }

    static func encodeCommand(_ command: WatchCompanionCommand) throws -> [String: Any] {
        [payloadKey: try encode(WatchCompanionEnvelope.command(try command.validated()))]
    }

    static func decodeCommand(_ message: [String: Any]) throws -> WatchCompanionCommand {
        guard case .command(let command) = try decode(message) else {
            throw WatchCompanionValidationError.invalidPayload
        }
        return try command.validated()
    }

    static func encodeReply(_ reply: WatchCompanionReply) throws -> [String: Any] {
        [payloadKey: try encode(WatchCompanionEnvelope.reply(reply))]
    }

    static func decodeReply(_ message: [String: Any]) throws -> WatchCompanionReply {
        guard case .reply(let reply) = try decode(message) else {
            throw WatchCompanionValidationError.invalidPayload
        }
        return reply
    }

    private static func encode(_ envelope: WatchCompanionEnvelope) throws -> Data {
        let data = try PropertyListEncoder().encode(envelope)
        guard data.count <= maximumPayloadBytes else {
            throw WatchCompanionValidationError.invalidPayload
        }
        return data
    }

    private static func decode(_ container: [String: Any]) throws -> WatchCompanionEnvelope {
        guard Set(container.keys) == [payloadKey],
              let data = container[payloadKey] as? Data,
              data.count <= maximumPayloadBytes else {
            throw WatchCompanionValidationError.invalidPayload
        }
        do {
            return try PropertyListDecoder().decode(WatchCompanionEnvelope.self, from: data)
        } catch {
            throw WatchCompanionValidationError.invalidPayload
        }
    }
}
