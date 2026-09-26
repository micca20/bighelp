import CryptoKit
import Foundation

struct LoopdyLinkVoiceSpeakRequest: Encodable, Equatable, Sendable {
    let version = 1
    let type = "voice.speak.request"
    let requestID: String
    let sessionID: String
    let agentID: String
    let text: String
    let speed: Float
    let sentAt: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case requestID = "requestId"
        case sessionID = "sessionId"
        case agentID = "agentId"
        case text
        case speed
        case sentAt
    }
}

struct LoopdyLinkVoiceAudioChunk: Decodable, Equatable, Sendable {
    static let maximumChunkBytes = 90 * 1_024
    static let maximumAudioBytes = 8 * 1_024 * 1_024
    static let maximumChunkCount = 92

    let requestID: String
    let sessionID: String
    let agentID: String
    let index: Int
    let count: Int
    let mimeType: String
    let provider: String
    let totalBytes: Int
    let sha256: String
    let audio: Data
    let sentAt: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case requestID = "requestId"
        case sessionID = "sessionId"
        case agentID = "agentId"
        case index
        case count
        case mimeType
        case provider
        case totalBytes
        case sha256
        case audio
        case sentAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value: [String: Any] = [
            "version": try container.decode(Int.self, forKey: .version),
            "type": try container.decode(String.self, forKey: .type),
            "requestId": try container.decode(String.self, forKey: .requestID),
            "sessionId": try container.decode(String.self, forKey: .sessionID),
            "agentId": try container.decode(String.self, forKey: .agentID),
            "index": try container.decode(Int.self, forKey: .index),
            "count": try container.decode(Int.self, forKey: .count),
            "mimeType": try container.decode(String.self, forKey: .mimeType),
            "provider": try container.decode(String.self, forKey: .provider),
            "totalBytes": try container.decode(Int.self, forKey: .totalBytes),
            "sha256": try container.decode(String.self, forKey: .sha256),
            "audio": try container.decode(String.self, forKey: .audio),
            "sentAt": try container.decode(Int.self, forKey: .sentAt),
        ]
        self = try Self.decode(value)
    }

    static func decode(_ value: [String: Any]) throws -> LoopdyLinkVoiceAudioChunk {
        guard
            value["version"] as? Int == 1,
            value["type"] as? String == "voice.speak.chunk",
            let requestID = opaque(value["requestId"], minimum: 16, maximum: 128),
            let sessionID = LoopdyLinkSessionCoordinate.decode(value["sessionId"]),
            let agentID = opaque(value["agentId"], minimum: 1, maximum: 96),
            let index = value["index"] as? Int,
            let count = value["count"] as? Int,
            count > 0,
            count <= maximumChunkCount,
            index >= 0,
            index < count,
            let mimeType = value["mimeType"] as? String,
            ["audio/mpeg", "audio/ogg", "audio/wav", "audio/flac"].contains(mimeType),
            let provider = label(value["provider"], maximum: 80),
            let totalBytes = value["totalBytes"] as? Int,
            totalBytes > 0,
            totalBytes <= maximumAudioBytes,
            let sha256 = value["sha256"] as? String,
            let digest = try? LoopdyLinkBase64URL.decode(sha256),
            digest.count == SHA256.Digest.byteCount,
            let encodedAudio = value["audio"] as? String,
            let audio = try? LoopdyLinkBase64URL.decode(encodedAudio),
            !audio.isEmpty,
            audio.count <= maximumChunkBytes,
            let sentAt = value["sentAt"] as? Int,
            sentAt > 0
        else { throw LoopdyLinkWireError.invalidValue }
        return LoopdyLinkVoiceAudioChunk(
            requestID: requestID,
            sessionID: sessionID,
            agentID: agentID,
            index: index,
            count: count,
            mimeType: mimeType,
            provider: provider,
            totalBytes: totalBytes,
            sha256: sha256,
            audio: audio,
            sentAt: sentAt
        )
    }

    private init(
        requestID: String,
        sessionID: String,
        agentID: String,
        index: Int,
        count: Int,
        mimeType: String,
        provider: String,
        totalBytes: Int,
        sha256: String,
        audio: Data,
        sentAt: Int
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.agentID = agentID
        self.index = index
        self.count = count
        self.mimeType = mimeType
        self.provider = provider
        self.totalBytes = totalBytes
        self.sha256 = sha256
        self.audio = audio
        self.sentAt = sentAt
    }

    private static func opaque(_ value: Any?, minimum: Int, maximum: Int) -> String? {
        guard
            let value = value as? String,
            LoopdyLinkPickerValidation.opaque(value, minimum: minimum, maximum: maximum)
        else { return nil }
        return value
    }

    private static func label(_ value: Any?, maximum: Int) -> String? {
        guard let value = value as? String else { return nil }
        return LoopdyLinkPickerValidation.label(value, maximum: maximum)
    }
}
