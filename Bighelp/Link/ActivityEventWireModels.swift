import Foundation

struct BighelpLinkActivityEvent: Decodable, Equatable, Sendable {
    let chatEvent: ChatActivityEvent
    /// Newer hosts may include the emitting agent. It is optional to preserve
    /// the existing Hermes activity.event contract.
    let agentID: String?

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) { return nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        let required = Set([
            "version", "type", "eventId", "sessionId", "turnId", "kind",
            "lifecycle", "title", "occurredAt",
        ])
        let optional = Set([
            "summary", "detail", "arguments", "result", "durationMs", "toolCallId", "toolName", "subagentId",
            "botRunId", "memberId", "fromMemberId", "agentId",
        ])
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw BighelpLinkWireError.invalidValue
        }
        func key(_ name: String) -> AnyKey { AnyKey(stringValue: name)! }
        var value: [String: Any] = [
            "version": try container.decode(Int.self, forKey: key("version")),
            "type": try container.decode(String.self, forKey: key("type")),
            "eventId": try container.decode(String.self, forKey: key("eventId")),
            "sessionId": try container.decode(String.self, forKey: key("sessionId")),
            "turnId": try container.decode(String.self, forKey: key("turnId")),
            "kind": try container.decode(String.self, forKey: key("kind")),
            "lifecycle": try container.decode(String.self, forKey: key("lifecycle")),
            "title": try container.decode(String.self, forKey: key("title")),
            "occurredAt": try container.decode(Int.self, forKey: key("occurredAt")),
        ]
        for name in ["summary", "detail", "arguments", "result", "toolCallId", "toolName", "subagentId", "botRunId", "memberId", "fromMemberId", "agentId"] {
            if let decoded = try container.decodeIfPresent(String.self, forKey: key(name)) {
                value[name] = decoded
            }
        }
        if let duration = try container.decodeIfPresent(Int.self, forKey: key("durationMs")) {
            value["durationMs"] = duration
        }
        self = try Self.decode(value)
    }

    static func decode(_ value: [String: Any]) throws -> BighelpLinkActivityEvent {
        let required = Set([
            "version", "type", "eventId", "sessionId", "turnId", "kind",
            "lifecycle", "title", "occurredAt",
        ])
        let optional = Set([
            "summary", "detail", "arguments", "result", "durationMs", "toolCallId", "toolName", "subagentId",
            "botRunId", "memberId", "fromMemberId", "agentId",
        ])
        let keys = Set(value.keys)
        guard
            required.isSubset(of: keys),
            keys.isSubset(of: required.union(optional)),
            value["version"] as? Int == 1,
            value["type"] as? String == "activity.event",
            let eventID = opaque(value["eventId"], minimum: 16, maximum: 128),
            let sessionID = BighelpLinkSessionCoordinate.decode(value["sessionId"]),
            let turnID = opaque(value["turnId"], minimum: 8, maximum: 180),
            let rawKind = value["kind"] as? String,
            let kind = ChatActivityKind(rawValue: rawKind),
            let rawLifecycle = value["lifecycle"] as? String,
            let lifecycle = ChatActivityLifecycle(rawValue: rawLifecycle),
            lifecycle != .recorded,
            let title = label(value["title"], maximum: 80),
            let occurredAt = value["occurredAt"] as? Int,
            occurredAt > 0
        else { throw BighelpLinkWireError.invalidValue }
        let summary = try optionalLabel(value, key: "summary", maximum: 500)
        let detail = try optionalLabel(value, key: "detail", maximum: 1_000)
        let arguments = try optionalDetail(value, key: "arguments", maximum: 65_536)
        let result = try optionalDetail(value, key: "result", maximum: 65_536)
        let duration: Int?
        if value.keys.contains("durationMs") {
            guard let decoded = value["durationMs"] as? Int else {
                throw BighelpLinkWireError.invalidValue
            }
            duration = decoded
        } else {
            duration = nil
        }
        guard duration == nil || (0...86_400_000).contains(duration!) else {
            throw BighelpLinkWireError.invalidValue
        }
        let toolCallID = try optionalOpaque(value, key: "toolCallId", maximum: 180)
        let toolName = try optionalOpaque(value, key: "toolName", maximum: 80)
        let subagentID = try optionalOpaque(value, key: "subagentId", maximum: 180)
        let botRunID = try optionalOpaque(value, key: "botRunId", maximum: 180)
        let memberID = try optionalOpaque(value, key: "memberId", maximum: 96)
        let fromMemberID = try optionalOpaque(value, key: "fromMemberId", maximum: 96)
        let agentID = try optionalOpaque(value, key: "agentId", maximum: 96)
        let collaborationDetailIsBounded = kind != .botHandoff
            || [arguments, result].compactMap { $0 }.allSatisfy { $0.utf8.count <= 64_000 }
        let hasValidIdentity = switch kind {
        case .reasoning:
            toolCallID == nil && toolName == nil && subagentID == nil && botRunID == nil && memberID == nil && fromMemberID == nil && arguments == nil && result == nil
        case .tool:
            toolCallID != nil && subagentID == nil && botRunID == nil && memberID == nil && fromMemberID == nil
        case .subagent:
            toolCallID == nil && toolName == nil && subagentID != nil && botRunID == nil && memberID == nil && fromMemberID == nil && arguments == nil && result == nil
        case .botHandoff:
            toolCallID == nil && toolName == nil && subagentID == nil && botRunID != nil && memberID != nil
        }
        guard hasValidIdentity, collaborationDetailIsBounded else {
            throw BighelpLinkWireError.invalidValue
        }
        return BighelpLinkActivityEvent(
            chatEvent: ChatActivityEvent(
                eventID: eventID,
                sessionID: sessionID,
                turnID: turnID,
                kind: kind,
                lifecycle: lifecycle,
                title: title,
                summary: summary,
                detail: detail,
                occurredAt: occurredAt,
                durationMilliseconds: duration,
                toolCallID: toolCallID,
                toolName: toolName,
                arguments: arguments,
                result: result,
                subagentID: subagentID,
                botRunID: botRunID,
                memberID: memberID,
                fromMemberID: fromMemberID
            ),
            agentID: agentID
        )
    }

    private init(chatEvent: ChatActivityEvent, agentID: String?) {
        self.chatEvent = chatEvent
        self.agentID = agentID
    }

    private static func opaque(_ value: Any?, minimum: Int, maximum: Int) -> String? {
        guard
            let value = value as? String,
            BighelpLinkPickerValidation.opaque(value, minimum: minimum, maximum: maximum)
        else { return nil }
        return value
    }

    private static func optionalOpaque(
        _ value: [String: Any],
        key: String,
        maximum: Int
    ) throws -> String? {
        guard value.keys.contains(key) else { return nil }
        guard let decoded = opaque(value[key], minimum: 1, maximum: maximum) else {
            throw BighelpLinkWireError.invalidValue
        }
        return decoded
    }

    private static func optionalLabel(
        _ value: [String: Any],
        key: String,
        maximum: Int
    ) throws -> String? {
        guard value.keys.contains(key) else { return nil }
        guard let decoded = label(value[key], maximum: maximum) else {
            throw BighelpLinkWireError.invalidValue
        }
        return decoded
    }

    private static func optionalDetail(
        _ value: [String: Any],
        key: String,
        maximum: Int
    ) throws -> String? {
        guard value.keys.contains(key) else { return nil }
        guard
            let decoded = value[key] as? String,
            !decoded.isEmpty,
            decoded.count <= maximum,
            !decoded.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) && $0.value != 10 && $0.value != 9
            })
        else { throw BighelpLinkWireError.invalidValue }
        return decoded
    }

    private static func label(_ value: Any?, maximum: Int) -> String? {
        guard let value = value as? String else { return nil }
        return BighelpLinkPickerValidation.label(value, maximum: maximum)
    }
}
