import CryptoKit
import Foundation

struct LoopdyLinkSessionForkRequest: Encodable, Equatable, Sendable {
    let version = 1
    let type = "session.fork.request"
    let requestID: String
    let sourceSessionID: String
    let forkSessionID: String
    let agentID: String
    let actorID: String
    let actorName: String
    let deviceName: String
    let userTurn: Int
    let checkpointRole: SessionForkCheckpointRole
    let checkpointDigest: String
    let title: String
    let sentAt: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case requestID = "requestId"
        case sourceSessionID = "sourceSessionId"
        case forkSessionID = "forkSessionId"
        case agentID = "agentId"
        case actorID = "actorId"
        case actorName
        case deviceName
        case userTurn
        case checkpointRole
        case checkpointDigest
        case title
        case sentAt
    }

    init(
        requestID: String,
        sourceSessionID: String,
        forkSessionID: String,
        agentID: String,
        actorID: String,
        actorName: String,
        deviceName: String,
        checkpoint: SessionForkCheckpoint,
        title: String,
        sentAt: Int
    ) throws {
        guard
            LoopdyLinkPickerValidation.opaque(requestID, minimum: 16, maximum: 128),
            LoopdyLinkSessionCoordinate.isValid(sourceSessionID),
            LoopdyLinkSessionCoordinate.isValid(forkSessionID),
            LoopdyLinkPickerValidation.opaque(agentID, minimum: 1, maximum: 96),
            LoopdyLinkPickerValidation.opaque(actorID, minimum: 1, maximum: 96),
            LoopdyLinkPickerValidation.label(actorName, maximum: 80) != nil,
            LoopdyLinkPickerValidation.label(deviceName, maximum: 96) != nil,
            checkpoint.userTurn > 0,
            (try? LoopdyLinkBase64URL.decode(checkpoint.contentDigest).count) == SHA256.Digest.byteCount,
            LoopdyLinkPickerValidation.label(title, maximum: 240) != nil,
            sentAt > 0
        else { throw LoopdyLinkWireError.invalidValue }
        self.requestID = requestID
        self.sourceSessionID = sourceSessionID
        self.forkSessionID = forkSessionID
        self.agentID = agentID
        self.actorID = actorID
        self.actorName = actorName
        self.deviceName = deviceName
        userTurn = checkpoint.userTurn
        checkpointRole = checkpoint.role
        checkpointDigest = checkpoint.contentDigest
        self.title = title
        self.sentAt = sentAt
    }
}

struct LoopdyLinkSessionForkResult: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Equatable, Sendable {
        case completed
        case failed
        case conflict
    }

    let requestID: String
    let sourceSessionID: String
    let forkSessionID: String
    let status: Status
    let title: String
    let message: String
    let sentAt: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case type
        case requestID = "requestId"
        case sourceSessionID = "sourceSessionId"
        case forkSessionID = "forkSessionId"
        case status
        case title
        case message
        case sentAt
    }

    init(from decoder: any Decoder) throws {
        let keys = try LoopdyLinkPickerValidation.keys(from: decoder)
        guard keys == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw LoopdyLinkWireError.invalidValue
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            try container.decode(Int.self, forKey: .version) == 1,
            try container.decode(String.self, forKey: .type) == "session.fork.result"
        else { throw LoopdyLinkWireError.invalidValue }
        requestID = try container.decode(String.self, forKey: .requestID)
        sourceSessionID = try container.decode(String.self, forKey: .sourceSessionID)
        forkSessionID = try container.decode(String.self, forKey: .forkSessionID)
        status = try container.decode(Status.self, forKey: .status)
        title = try container.decode(String.self, forKey: .title)
        message = try container.decode(String.self, forKey: .message)
        sentAt = try container.decode(Int.self, forKey: .sentAt)
        guard
            LoopdyLinkPickerValidation.opaque(requestID, minimum: 16, maximum: 128),
            LoopdyLinkSessionCoordinate.isValid(sourceSessionID),
            LoopdyLinkSessionCoordinate.isValid(forkSessionID),
            LoopdyLinkPickerValidation.label(title, maximum: 240) != nil,
            LoopdyLinkPickerValidation.label(message, maximum: 2_000) != nil,
            sentAt > 0
        else { throw LoopdyLinkWireError.invalidValue }
    }
}

struct LoopdyLinkSlashCommandCatalogRequest: Encodable, Equatable, Sendable {
    let version = 1
    let type = "commands.catalog.request"
    let requestID: String
    let sessionID: String
    let agentID: String
    let sentAt: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case requestID = "requestId"
        case sessionID = "sessionId"
        case agentID = "agentId"
        case sentAt
    }

    init(requestID: String, sessionID: String, agentID: String, sentAt: Int) throws {
        guard
            LoopdyLinkPickerValidation.opaque(requestID, minimum: 16, maximum: 128),
            LoopdyLinkSessionCoordinate.isValid(sessionID),
            LoopdyLinkPickerValidation.opaque(agentID, minimum: 1, maximum: 96),
            sentAt > 0
        else { throw LoopdyLinkWireError.invalidValue }
        self.requestID = requestID
        self.sessionID = sessionID
        self.agentID = agentID
        self.sentAt = sentAt
    }
}

struct LoopdyLinkSlashCommandCatalog: Decodable, Equatable, Sendable {
    let requestID: String
    let sessionID: String
    let agentID: String
    let commands: [SlashCommandDescriptor]
    let sentAt: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case type
        case requestID = "requestId"
        case sessionID = "sessionId"
        case agentID = "agentId"
        case commands
        case sentAt
    }

    init(from decoder: any Decoder) throws {
        let keys = try LoopdyLinkPickerValidation.keys(from: decoder)
        guard keys == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw LoopdyLinkWireError.invalidValue
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            try container.decode(Int.self, forKey: .version) == 1,
            try container.decode(String.self, forKey: .type) == "commands.catalog"
        else { throw LoopdyLinkWireError.invalidValue }
        requestID = try container.decode(String.self, forKey: .requestID)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        agentID = try container.decode(String.self, forKey: .agentID)
        commands = try container.decode([SlashCommandDescriptor].self, forKey: .commands)
        sentAt = try container.decode(Int.self, forKey: .sentAt)
        let names = commands.map(\.name)
        guard
            LoopdyLinkPickerValidation.opaque(requestID, minimum: 16, maximum: 128),
            LoopdyLinkSessionCoordinate.isValid(sessionID),
            LoopdyLinkPickerValidation.opaque(agentID, minimum: 1, maximum: 96),
            commands.count <= 1_000,
            Set(names).count == names.count,
            sentAt > 0
        else { throw LoopdyLinkWireError.invalidValue }
    }
}
