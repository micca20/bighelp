import Foundation

struct DirectHermesDurableReactionSnapshot: Equatable, Sendable {
    let reactionsByRowID: [Int: DirectHermesMessageReaction]
}

/// Decodes only durable numeric-row reactions. Missing numeric IDs or missing
/// durable reaction metadata make a response non-authoritative rather than
/// inviting text, position, or timestamp correlation. A complete, fully
/// addressed response with no reactions is an authoritative clear.
enum DirectHermesReactionHistoryDecoder {
    struct HTTPAccumulator {
        private var lastRowID: Int?
        private var isAuthoritative = true
        private var reactionsByRowID: [Int: DirectHermesMessageReaction] = [:]

        mutating func consume(_ messages: [LoopdyJSONValue]) throws {
            for value in messages {
                guard let row = value.object,
                      let rowID = row["id"]?.integer, rowID >= 0,
                      lastRowID.map({ rowID > $0 }) ?? true,
                      let role = row["role"]?.string else {
                    throw DirectHermesError.invalidResponse
                }
                lastRowID = rowID
                guard role == DirectHermesReactionRole.user.rawValue
                        || role == DirectHermesReactionRole.assistant.rawValue else { continue }

                // Older HTTP projections did not expose this sidecar. Such a
                // page can still hydrate canonical chat elsewhere, but cannot
                // prove that an empty reaction set authoritatively clears live
                // reaction state.
                guard let metadataValue = row["display_metadata"] else {
                    isAuthoritative = false
                    continue
                }
                let metadata: [String: LoopdyJSONValue]
                if metadataValue == .null {
                    metadata = [:]
                } else if let object = metadataValue.object {
                    metadata = object
                } else {
                    throw DirectHermesError.invalidResponse
                }
                guard let reactionValue = metadata["reactions"], reactionValue != .null else { continue }
                guard let reactions = reactionValue.array, reactions.count <= 1_024 else {
                    throw DirectHermesError.invalidResponse
                }
                let decoded = try DirectHermesReactionHistoryDecoder.decodeReaction(
                    rowID: rowID,
                    role: role,
                    reactions: reactions
                )
                if !decoded.reactions.isEmpty {
                    guard reactionsByRowID.count < 4_096 || reactionsByRowID[rowID] != nil else {
                        throw DirectHermesError.invalidResponse
                    }
                    reactionsByRowID[rowID] = decoded
                }
            }
        }

        func snapshot() -> DirectHermesDurableReactionSnapshot? {
            guard isAuthoritative else { return nil }
            return DirectHermesDurableReactionSnapshot(reactionsByRowID: reactionsByRowID)
        }
    }

    static func decode(_ response: LoopdyJSONValue) throws -> DirectHermesDurableReactionSnapshot? {
        guard let object = response.object,
              Set(object.keys) == ["count", "messages"],
              let count = object["count"]?.integer, count >= 0,
              let messages = object["messages"]?.array,
              count == messages.count,
              messages.count <= 1_000_000 else {
            throw DirectHermesError.invalidResponse
        }
        return try decode(messages: messages)
    }

    static func decode(messages: [LoopdyJSONValue]) throws -> DirectHermesDurableReactionSnapshot? {
        var seenRows = Set<Int>()
        var reactionsByRowID: [Int: DirectHermesMessageReaction] = [:]

        for value in messages {
            guard let row = value.object, let role = row["role"]?.string else {
                throw DirectHermesError.invalidResponse
            }
            guard role == DirectHermesReactionRole.user.rawValue
                    || role == DirectHermesReactionRole.assistant.rawValue else { continue }
            guard let rowID = row["row_id"]?.integer, rowID >= 0 else {
                // Older stock gateways omitted the only durable address. Keep
                // existing live state rather than guessing a bubble identity.
                return nil
            }
            guard seenRows.insert(rowID).inserted else {
                throw DirectHermesError.invalidResponse
            }

            let metadata: [String: LoopdyJSONValue]
            if let value = row["display_metadata"], value != .null {
                guard let object = value.object else { throw DirectHermesError.invalidResponse }
                metadata = object
            } else {
                metadata = [:]
            }
            guard let reactionValue = metadata["reactions"], reactionValue != .null else { continue }
            guard let reactions = reactionValue.array, reactions.count <= 1_024 else {
                throw DirectHermesError.invalidResponse
            }
            let decoded = try decodeReaction(rowID: rowID, role: role, reactions: reactions)
            if !decoded.reactions.isEmpty {
                reactionsByRowID[rowID] = decoded
            }
        }

        return DirectHermesDurableReactionSnapshot(reactionsByRowID: reactionsByRowID)
    }

    private static func decodeReaction(
        rowID: Int,
        role: String,
        reactions: [LoopdyJSONValue]
    ) throws -> DirectHermesMessageReaction {
        let event = DirectHermesEvent(
            type: "message.reaction",
            sessionID: nil,
            payload: [
                "row_id": .integer(rowID),
                "role": .string(role),
                "reactions": .array(reactions),
            ],
            sequence: nil
        )
        return try DirectHermesMessageReaction(event: event)
    }
}

/// Reads stock session messages through bounded authenticated HTTP pages. It
/// never uses the normal websocket frame budget and publishes no snapshot until
/// every page and every durable row address has been validated.
@MainActor
enum DirectHermesReactionHistoryLoader {
    static let pageSize = 100
    static let maximumPageResponseBytes = 512 * 1_024

    static func load(
        http: any DirectHermesAuthenticatedHTTP,
        storedSessionID: String,
        profileID: String,
        remainsOwned: @escaping @MainActor () -> Bool
    ) async throws -> DirectHermesDurableReactionSnapshot? {
        let sessionID = try pathComponent(storedSessionID)
        guard !profileID.isEmpty, profileID.utf8.count <= 512,
              profileID == profileID.trimmingCharacters(in: .whitespacesAndNewlines),
              !profileID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DirectHermesError.invalidResponse
        }

        var offset = 0
        var resolvedSessionID: String?
        var accumulator = DirectHermesReactionHistoryDecoder.HTTPAccumulator()
        while true {
            try Task.checkCancellation()
            guard remainsOwned() else { throw DirectHermesError.notConnected }
            let response = try await http.request(.init(
                path: "/api/sessions/\(sessionID)/messages",
                method: .get,
                query: [
                    .init(name: "profile", value: profileID),
                    .init(name: "limit", value: String(pageSize)),
                    .init(name: "offset", value: String(offset)),
                    .init(name: "order", value: "oldest"),
                ],
                maximumResponseBytes: maximumPageResponseBytes
            ))
            guard remainsOwned() else { throw DirectHermesError.notConnected }
            let page = try decodePage(response, expectedOffset: offset,
                expectedSessionID: storedSessionID, expectedProfileID: profileID)
            if let resolvedSessionID {
                guard Data(resolvedSessionID.utf8) == Data(page.sessionID.utf8) else {
                    throw DirectHermesError.invalidResponse
                }
            } else {
                resolvedSessionID = page.sessionID
            }
            try accumulator.consume(page.messages)
            guard page.returned == pageSize else { return accumulator.snapshot() }
            let next = offset.addingReportingOverflow(page.returned)
            guard !next.overflow, next.partialValue > offset else {
                throw DirectHermesError.invalidResponse
            }
            offset = next.partialValue
        }
    }

    private struct Page {
        let sessionID: String
        let messages: [LoopdyJSONValue]
        let returned: Int
    }

    private static func decodePage(
        _ response: LoopdyJSONValue,
        expectedOffset: Int,
        expectedSessionID: String,
        expectedProfileID: String
    ) throws -> Page {
        guard let object = response.object,
              let sessionID = object["session_id"]?.string,
              Data(sessionID.utf8) == Data(expectedSessionID.utf8),
              let profileID = object["profile"]?.string,
              Data(profileID.utf8) == Data(expectedProfileID.utf8),
              !sessionID.isEmpty, sessionID.utf8.count <= 512,
              !sessionID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let messages = object["messages"]?.array,
              let pagination = object["pagination"]?.object,
              Set(pagination.keys) == ["limit", "offset", "order", "returned"],
              pagination["limit"]?.integer == pageSize,
              pagination["offset"]?.integer == expectedOffset,
              pagination["order"]?.string == "oldest",
              let returned = pagination["returned"]?.integer,
              (0...pageSize).contains(returned),
              messages.count == returned else {
            throw DirectHermesError.invalidResponse
        }
        return Page(sessionID: sessionID, messages: messages, returned: returned)
    }

    private static func pathComponent(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 512,
              value != ".", value != "..", !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DirectHermesError.invalidResponse
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty, !encoded.contains("/") else {
            throw DirectHermesError.invalidResponse
        }
        return encoded
    }
}
