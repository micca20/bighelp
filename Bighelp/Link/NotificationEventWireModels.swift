import Foundation

struct BighelpLinkNotificationEvent: Decodable, Equatable, Sendable {
    let eventID: String
    let eventType: String
    let agentID: String
    let agentName: String
    let sessionID: String?
    let title: String
    let body: String
    let card: BighelpCardEnvelope?
    let sentAt: Int

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        let required = Set([
            "version", "type", "eventId", "eventType", "agentId", "agentName",
            "title", "body", "sentAt",
        ])
        guard
            required.isSubset(of: keys),
            keys.isSubset(of: required.union(["sessionId", "card"]))
        else { throw BighelpLinkWireError.invalidValue }
        func key(_ name: String) -> AnyKey { AnyKey(stringValue: name)! }
        guard
            try container.decode(Int.self, forKey: key("version")) == 1,
            try container.decode(String.self, forKey: key("type")) == "notification.event"
        else { throw BighelpLinkWireError.invalidValue }
        let eventID = try container.decode(String.self, forKey: key("eventId"))
        let eventType = try container.decode(String.self, forKey: key("eventType"))
        let agentID = try container.decode(String.self, forKey: key("agentId"))
        let agentName = try container.decode(String.self, forKey: key("agentName"))
        let sessionID = try container.decodeIfPresent(String.self, forKey: key("sessionId"))
        let title = try container.decode(String.self, forKey: key("title"))
        let body = try container.decode(String.self, forKey: key("body"))
        let card: BighelpCardEnvelope?
        do {
            card = try container.decodeIfPresent(
                BighelpCardEnvelope.self,
                forKey: key("card")
            )
        } catch {
            card = nil
        }
        let sentAt = try container.decode(Int.self, forKey: key("sentAt"))
        guard
            Self.coordinate(eventID, maximum: 220),
            Self.eventTypes.contains(eventType),
            BighelpLinkPickerValidation.opaque(agentID, minimum: 1, maximum: 96),
            Self.label(agentName, maximum: 80),
            sessionID.map({ BighelpLinkPickerValidation.opaque($0, minimum: 1, maximum: 180) }) ?? true,
            Self.label(title, maximum: 100),
            Self.label(body, maximum: 800),
            sentAt > 0
        else { throw BighelpLinkWireError.invalidValue }
        self.eventID = eventID
        self.eventType = eventType
        self.agentID = agentID
        self.agentName = agentName
        self.sessionID = sessionID
        self.title = title
        self.body = body
        self.card = card
        self.sentAt = sentAt
    }

    private static func coordinate(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty
            && value.count <= maximum
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.contains(where: { $0.isWhitespace || !$0.isASCII || !$0.isLetter && !$0.isNumber && !"._:-".contains($0) })
    }

    private static func label(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty
            && value.count <= maximum
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static let eventTypes = Set([
        "approval.required", "attention.required", "channel.message",
        "delegation.completed", "delegation.started", "delegation.updated",
        "job.completed", "job.failed", "session.completed", "session.failed",
        "task.updated",
    ])
}
