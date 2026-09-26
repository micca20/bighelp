import Foundation

enum BighelpLinkUserMessageBehavior: String, Codable, Equatable, Sendable {
    case steer
    case queue
    case interrupt
}

struct BighelpLinkUserMessage: Codable, Equatable, Sendable {
    let version = 1
    let type = "user.message"
    let messageID: String
    let sessionID: String
    let agentID: String
    /// Optional correlation supplied by newer bighelp Link hosts. Older hosts
    /// identify assistant streaming by the documented session/agent fields.
    let turnID: String?
    let actorID: String
    let actorName: String
    let deviceName: String
    let text: String
    let attachments: [BighelpLinkAttachmentReference]
    let behavior: BighelpLinkUserMessageBehavior?
    let sentAt: Int

    enum CodingKeys: String, CodingKey {
        case version
        case type
        case messageID = "messageId"
        case sessionID = "sessionId"
        case agentID = "agentId"
        case turnID = "turnId"
        case actorID = "actorId"
        case actorName
        case deviceName
        case text
        case attachments
        case behavior
        case sentAt
    }

    init(
        messageID: String,
        sessionID: String,
        agentID: String,
        turnID: String? = nil,
        actorID: String,
        actorName: String,
        deviceName: String,
        text: String,
        attachments: [BighelpLinkAttachmentReference] = [],
        behavior: BighelpLinkUserMessageBehavior? = nil,
        sentAt: Int
    ) {
        self.messageID = messageID
        self.sessionID = sessionID
        self.agentID = agentID
        self.turnID = turnID
        self.actorID = actorID
        self.actorName = actorName
        self.deviceName = deviceName
        self.text = text
        self.attachments = attachments
        self.behavior = behavior
        self.sentAt = sentAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            try container.decode(Int.self, forKey: .version) == 1,
            try container.decode(String.self, forKey: .type) == "user.message"
        else { throw BighelpLinkWireError.invalidValue }
        messageID = try container.decode(String.self, forKey: .messageID)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        agentID = try container.decode(String.self, forKey: .agentID)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        actorID = try container.decode(String.self, forKey: .actorID)
        actorName = try container.decode(String.self, forKey: .actorName)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decodeIfPresent(
            [BighelpLinkAttachmentReference].self,
            forKey: .attachments
        ) ?? []
        behavior = try container.decodeIfPresent(
            BighelpLinkUserMessageBehavior.self,
            forKey: .behavior
        )
        guard
            attachments.count <= 10,
            turnID == nil || (
                (8...180).contains(turnID!.count)
                    && turnID!.allSatisfy {
                        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
                    }
            )
        else { throw BighelpLinkWireError.invalidValue }
        sentAt = try container.decode(Int.self, forKey: .sentAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(type, forKey: .type)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(agentID, forKey: .agentID)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encode(actorID, forKey: .actorID)
        try container.encode(actorName, forKey: .actorName)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(text, forKey: .text)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(behavior, forKey: .behavior)
        try container.encode(sentAt, forKey: .sentAt)
    }
}

struct BighelpLinkAssistantMessage: Decodable, Equatable, Sendable {
    enum Delivery: String, Sendable {
        case draft
        case final
    }

    let messageID: String
    let requestID: String?
    let sessionID: String
    let turnID: String?
    let agentID: String
    let agentName: String
    let text: String
    let sentAt: Int
    let delivery: Delivery
    let draftID: Int?

    private init(
        messageID: String,
        requestID: String?,
        sessionID: String,
        turnID: String?,
        agentID: String,
        agentName: String,
        text: String,
        sentAt: Int,
        delivery: Delivery,
        draftID: Int?
    ) {
        self.messageID = messageID
        self.requestID = requestID
        self.sessionID = sessionID
        self.turnID = turnID
        self.agentID = agentID
        self.agentName = agentName
        self.text = text
        self.sentAt = sentAt
        self.delivery = delivery
        self.draftID = draftID
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case messageID = "messageId"
        case requestID = "requestId"
        case sessionID = "sessionId"
        case turnID = "turnId"
        case agentID = "agentId"
        case agentName
        case text
        case sentAt
        case delivery
        case draftID = "draftId"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var value: [String: Any] = [
            "version": try container.decode(Int.self, forKey: .version),
            "type": try container.decode(String.self, forKey: .type),
            "messageId": try container.decode(String.self, forKey: .messageID),
            "sessionId": try container.decode(String.self, forKey: .sessionID),
            "agentId": try container.decode(String.self, forKey: .agentID),
            "agentName": try container.decode(String.self, forKey: .agentName),
            "text": try container.decode(String.self, forKey: .text),
            "sentAt": try container.decode(Int.self, forKey: .sentAt),
            "delivery": try container.decode(String.self, forKey: .delivery),
            "draftId": try container.decodeIfPresent(Int.self, forKey: .draftID) as Any,
        ]
        if let requestID = try container.decodeIfPresent(String.self, forKey: .requestID) {
            value["requestId"] = requestID
        }
        if let turnID = try container.decodeIfPresent(String.self, forKey: .turnID) {
            value["turnId"] = turnID
        }
        self = try Self.decode(value)
    }

    static func decode(_ value: [String: Any]) throws -> BighelpLinkAssistantMessage {
        guard
            value["version"] as? Int == 1,
            value["type"] as? String == "assistant.message",
            let messageID = opaque(value["messageId"], minimum: 16, maximum: 128),
            (value["requestId"] == nil || opaque(value["requestId"], minimum: 16, maximum: 128) != nil),
            let sessionID = BighelpLinkSessionCoordinate.decode(value["sessionId"]),
            (value["turnId"] == nil || opaque(value["turnId"], minimum: 8, maximum: 180) != nil),
            let agentID = opaque(value["agentId"], minimum: 1, maximum: 96),
            let agentName = label(value["agentName"], maximum: 80),
            let text = value["text"] as? String,
            !text.isEmpty,
            text.count <= 100_000,
            !text.contains("\0"),
            let sentAt = value["sentAt"] as? Int,
            sentAt > 0,
            let rawDelivery = value["delivery"] as? String,
            let delivery = Delivery(rawValue: rawDelivery)
        else { throw BighelpLinkWireError.invalidValue }
        let draftID = value["draftId"] as? Int
        guard
            (delivery == .draft && (draftID ?? 0) > 0) ||
                (delivery == .final && draftID == nil)
        else { throw BighelpLinkWireError.invalidValue }
        return BighelpLinkAssistantMessage(
            messageID: messageID,
            requestID: opaque(value["requestId"], minimum: 16, maximum: 128),
            sessionID: sessionID,
            turnID: opaque(value["turnId"], minimum: 8, maximum: 180),
            agentID: agentID,
            agentName: agentName,
            text: text,
            sentAt: sentAt,
            delivery: delivery,
            draftID: draftID
        )
    }

    private static func opaque(_ value: Any?, minimum: Int, maximum: Int) -> String? {
        guard
            let value = value as? String,
            BighelpLinkPickerValidation.opaque(value, minimum: minimum, maximum: maximum)
        else { return nil }
        return value
    }

    private static func label(_ value: Any?, maximum: Int) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty, normalized == value.trimmingCharacters(in: .whitespacesAndNewlines), normalized.count <= maximum else {
            return nil
        }
        return normalized
    }
}
