import CryptoKit
import Foundation

enum WatchPendingFrameReconciliation {
    enum Disposition: Equatable {
        case send
        case accepted
    }

    static func disposition(
        pendingSequence: Int,
        pendingFrameID: String,
        serverSequence: Int,
        serverFrameID: String?
    ) throws -> Disposition {
        guard pendingSequence > 0,
              serverSequence >= 0,
              !pendingFrameID.isEmpty else {
            throw WatchCompanionValidationError.invalidPayload
        }
        if pendingSequence == serverSequence + 1 { return .send }
        if pendingSequence == serverSequence,
           pendingFrameID == serverFrameID {
            return .accepted
        }
        throw WatchCompanionValidationError.invalidPayload
    }
}

enum WatchLinkJSON: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case array([WatchLinkJSON])
    case object([String: WatchLinkJSON])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([WatchLinkJSON].self) { self = .array(value) }
        else if let value = try? container.decode([String: WatchLinkJSON].self) { self = .object(value) }
        else { throw WatchCompanionValidationError.invalidPayload }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int? {
        switch self {
        case .integer(let value): value
        case .number(let value) where value.rounded() == value: Int(value)
        default: nil
        }
    }
    var number: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }
    var boolean: Bool? { if case .boolean(let value) = self { value } else { nil } }
    var array: [WatchLinkJSON]? { if case .array(let value) = self { value } else { nil } }
    var object: [String: WatchLinkJSON]? { if case .object(let value) = self { value } else { nil } }
}

struct WatchLinkWorkspaceRequest: Encodable, Sendable {
    let version = 1
    let type = "workspace.request"
    let requestID: String
    let operation: String
    let payload: [String: WatchLinkJSON]
    let sentAt: Int

    enum CodingKeys: String, CodingKey {
        case version, type, operation, payload, sentAt
        case requestID = "requestId"
    }
}

struct WatchLinkWorkspaceResult: Decodable, Sendable {
    let version: Int
    let type: String
    let requestID: String
    let operation: String
    let status: String
    let payload: [String: WatchLinkJSON]
    let code: String?
    let message: String?
    let sentAt: Int

    enum CodingKeys: String, CodingKey {
        case version, type, operation, status, payload, code, message, sentAt
        case requestID = "requestId"
    }
}

struct WatchLinkUserMessage: Encodable, Sendable {
    let version = 1
    let type = "user.message"
    let messageID: String
    let sessionID: String
    let agentID: String
    let turnID: String
    let actorID: String
    let actorName: String
    let deviceName: String
    let text: String
    let attachments: [String] = []
    let sentAt: Int

    enum CodingKeys: String, CodingKey {
        case version, type, actorName, deviceName, text, attachments, sentAt
        case messageID = "messageId"
        case sessionID = "sessionId"
        case agentID = "agentId"
        case turnID = "turnId"
        case actorID = "actorId"
    }
}

struct WatchLinkAssistantMessage: Decodable, Sendable {
    let version: Int
    let type: String
    let messageID: String
    let requestID: String?
    let sessionID: String
    let turnID: String?
    let agentID: String
    let agentName: String
    let text: String
    let sentAt: Int
    let delivery: String

    enum CodingKeys: String, CodingKey {
        case version, type, agentName, text, sentAt, delivery
        case messageID = "messageId"
        case requestID = "requestId"
        case sessionID = "sessionId"
        case turnID = "turnId"
        case agentID = "agentId"
    }
}

struct WatchLinkVoiceRequest: Encodable, Sendable {
    let version = 1
    let type = "voice.speak.request"
    let requestID: String
    let sessionID: String
    let agentID: String
    let text: String
    let speed: Float = 1
    let sentAt: Int

    enum CodingKeys: String, CodingKey {
        case version, type, text, speed, sentAt
        case requestID = "requestId"
        case sessionID = "sessionId"
        case agentID = "agentId"
    }
}

struct WatchLinkVoiceChunk: Decodable, Sendable {
    let version: Int
    let type: String
    let requestID: String
    let sessionID: String
    let agentID: String
    let index: Int
    let count: Int
    let mimeType: String
    let provider: String
    let totalBytes: Int
    let sha256: String
    let audio: String
    let sentAt: Int

    enum CodingKeys: String, CodingKey {
        case version, type, index, count, mimeType, provider, totalBytes, sha256, audio, sentAt
        case requestID = "requestId"
        case sessionID = "sessionId"
        case agentID = "agentId"
    }
}

struct WatchLinkVoiceFailure: Decodable, Sendable {
    let version: Int
    let type: String
    let requestID: String
    let sessionID: String
    let agentID: String
    let code: String
    let message: String
    let sentAt: Int
    enum CodingKeys: String, CodingKey {
        case version, type, code, message, sentAt
        case requestID = "requestId"
        case sessionID = "sessionId"
        case agentID = "agentId"
    }
}

enum WatchLinkInboundPayload: Decodable, Sendable {
    case assistant(WatchLinkAssistantMessage)
    case workspace(WatchLinkWorkspaceResult)
    case voiceChunk(WatchLinkVoiceChunk)
    case voiceFailure(WatchLinkVoiceFailure)
    case ignored

    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        switch try container.decode(String.self, forKey: .type) {
        case "assistant.message": self = .assistant(try .init(from: decoder))
        case "workspace.result": self = .workspace(try .init(from: decoder))
        case "voice.speak.chunk": self = .voiceChunk(try .init(from: decoder))
        case "voice.speak.error": self = .voiceFailure(try .init(from: decoder))
        default: self = .ignored
        }
    }
}

struct WatchLinkEncryptedFrame: Codable, Sendable {
    let version: Int
    let type: String
    let id: String
    let senderDeviceID: String
    let senderEpoch: Int
    let sequence: Int
    let ack: Int
    let ciphertext: String

    enum CodingKeys: String, CodingKey {
        case version, type, id, senderEpoch, sequence, ack, ciphertext
        case senderDeviceID = "senderDeviceId"
    }
}

struct WatchLinkSocketReady: Decodable, Sendable {
    let deviceID: String
    let authorizationEpoch: Int
    let lastInboundSequence: Int
    let lastInboundFrameID: String?
    let lastAcknowledgedSequence: Int

    enum CodingKeys: String, CodingKey {
        case authorizationEpoch, lastInboundSequence, lastAcknowledgedSequence
        case deviceID = "deviceId"
        case lastInboundFrameID = "lastInboundFrameId"
    }
}

struct WatchLinkAccepted: Decodable, Sendable {
    let id: String
    let sequence: Int
}

struct WatchLinkReceipt: Encodable, Sendable {
    let version = 1
    let type = "receipt"
    let deviceID: String
    let frameID: String
    let sourceDeviceID: String
    let sequence: Int

    enum CodingKeys: String, CodingKey {
        case version, type, sequence
        case deviceID = "deviceId"
        case frameID = "frameId"
        case sourceDeviceID = "sourceDeviceId"
    }
}
