import Foundation

/// Phone-owned protocol. The legacy enrollment codec is intentionally not used by this lane.
/// No credentials, URLs, keys, device enrollment or arbitrary remote method names cross it.
enum WatchPhoneLinkState: String, Codable, Sendable {
    case unavailable, signedOut, connecting, connected
}

struct WatchCompanionState: Codable, Equatable, Sendable {
    let authorityID: UUID
    let revision: UInt64
    let offerID: UUID
    let phoneLink: WatchPhoneLinkState
    let content: WatchCompanionSnapshot

    var isFresh: Bool {
        let age = Date().timeIntervalSince(content.generatedAt)
        return age >= -30 && age < 120
    }
}

enum WatchCompanionAction: Codable, Equatable, Sendable {
    case selectSession(String)
    case dismissUpdate(String)
    case respond(itemID: String, text: String)
    case approve(requestID: String, decision: WatchApprovalDecision)
    case voice(sessionID: String, text: String)

    var targetID: String {
        switch self {
        case .selectSession(let id), .dismissUpdate(let id): id
        case .respond(let id, _), .approve(let id, _), .voice(let id, _): id
        }
    }

    func validate() throws {
        try WatchCompanionWire.require(targetID, bytes: 180)
        switch self {
        case .respond(_, let text), .voice(_, let text):
            try WatchCompanionWire.require(text, bytes: 10_000)
        default: break
        }
    }
}

struct WatchCompanionActionRequest: Codable, Equatable, Sendable {
    let id: UUID
    let authorityID: UUID
    let offerID: UUID
    let createdAt: Date
    let action: WatchCompanionAction
}

struct WatchCompanionReceipt: Codable, Equatable, Sendable, Identifiable {
    enum Phase: String, Codable, Sendable {
        /// Persisted before starting a side effect; NEVER equivalent to committed.
        case pending, committed, rejected, unconfirmed
    }
    let id: UUID
    let authorityID: UUID
    let targetID: String
    let phase: Phase
    let message: String
    let completedAt: Date
    var voice: WatchVoiceResult? = nil

    var isTerminal: Bool { phase != .pending }
}

enum WatchCompanionPacket: Codable, Sendable {
    case refresh(UUID, reconnect: Bool)
    case snapshot(WatchCompanionState)
    case action(WatchCompanionActionRequest)
    case status(requestID: UUID, authorityID: UUID)
    case receipt(WatchCompanionReceipt)
}

/// Objective-C WatchConnectivity callbacks may enter on a utility queue.
/// Construct them outside actor isolation, decode to Sendable values there,
/// then explicitly hop to the UI actor. A Task inside an actor-inferred
/// callback is too late: Swift checks the callback's executor on entry.
enum WatchCompanionCallbacks {
    nonisolated static func reply(_ deliver: @escaping @MainActor @Sendable (WatchCompanionPacket?) -> Void) -> @Sendable ([String: Any]) -> Void {
        { message in
            let packet = try? WatchCompanionWire.decode(message)
            Task { @MainActor in deliver(packet) }
        }
    }

    nonisolated static func failure(_ deliver: @escaping @MainActor @Sendable (WatchCompanionPacket?) -> Void) -> @Sendable (any Error) -> Void {
        { _ in Task { @MainActor in deliver(nil) } }
    }

    nonisolated static func textInput(_ deliver: @escaping @MainActor @Sendable (String?) -> Void) -> @Sendable ([Any]?) -> Void {
        { values in
            let text = values?.first as? String
            Task { @MainActor in deliver(text) }
        }
    }
}

enum WatchCompanionWire {
    static let key = "loopdy.companion.v2"
    static let maximumBytes = 60_000
    private struct Envelope: Codable {
        let version: Int
        let packet: WatchCompanionPacket
    }

    static func encode(_ packet: WatchCompanionPacket) throws -> [String: Any] {
        try validate(packet)
        let data = try PropertyListEncoder().encode(Envelope(version: 2, packet: packet))
        guard data.count <= maximumBytes else { throw WatchCompanionValidationError.fieldTooLong }
        return [key: data]
    }

    static func decode(_ dictionary: [String: Any]) throws -> WatchCompanionPacket {
        guard Set(dictionary.keys) == [key], let data = dictionary[key] as? Data,
              data.count <= maximumBytes else { throw WatchCompanionValidationError.invalidPayload }
        let envelope = try PropertyListDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 2 else { throw WatchCompanionValidationError.invalidPayload }
        try validate(envelope.packet)
        return envelope.packet
    }

    private static func validate(_ packet: WatchCompanionPacket) throws {
        switch packet {
        case .refresh, .status: break
        case .snapshot(let state):
            _ = try state.content.validated()
            guard state.revision > 0 else { throw WatchCompanionValidationError.invalidPayload }
        case .action(let request):
            try request.action.validate()
            guard request.createdAt.timeIntervalSince1970.isFinite else {
                throw WatchCompanionValidationError.invalidPayload
            }
        case .receipt(let receipt):
            try require(receipt.targetID, bytes: 180)
            try require(receipt.message, bytes: 240)
            if let voice = receipt.voice {
                guard receipt.phase == .committed, voice.attemptID == receipt.id.uuidString,
                      voice.errorMessage == nil else { throw WatchCompanionValidationError.invalidPayload }
                try require(voice.speaker, bytes: 120)
                try require(voice.text, bytes: 1_200)
            }
        }
    }

    static func require(_ text: String, bytes: Int) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= bytes, !text.contains("\0") else {
            throw WatchCompanionValidationError.invalidPayload
        }
    }

    static func bounded(_ text: String, bytes: Int) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
    }
}
