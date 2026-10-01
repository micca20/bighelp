import Foundation

// What the Watch and iPhone say to each other. The Watch is a remote for the
// phone: the phone does all the talking to the host, so no credentials, host
// addresses or keys ever cross. Everything is bounded and checked on arrival.

/// Something the Watch asks the iPhone for.
enum WatchRequest: Codable, Equatable, Sendable {
    /// Needs, recent chats and agents, for the home screen.
    case home
    /// The latest messages in one chat.
    case chat(sessionID: String)
    /// A message to a chat, or to a new chat with an agent.
    case send(WatchOutgoing)
    /// One agent's Feed, Ideas or Goals.
    case board(agentID: String, kind: WatchBoardKind)
    /// An answer to an approval.
    case decide(needID: String, decision: WatchDecision)
    /// An answer to an agent's question.
    case answer(needID: String, text: String)
    /// "Open on iPhone".
    case open(WatchPhoneLink)
}

/// The iPhone's answer to one request.
enum WatchReply: Codable, Equatable, Sendable {
    case home(WatchHome)
    case chat(WatchChat)
    /// The message reached the chat; the reply follows as a push.
    case sent(sessionID: String)
    case board([WatchBoardItem])
    case done
    /// Plain words for the person, never a raw error.
    case failed(String)
}

/// Sent by the iPhone without being asked.
enum WatchPush: Codable, Equatable, Sendable {
    /// A turn started from the Watch finished; fetch the chat.
    case replyReady(sessionID: String)
}

struct WatchOutgoing: Codable, Equatable, Sendable {
    /// Lets the iPhone ignore a repeat of the same message.
    let id: UUID
    /// Nil starts a new chat with `agentID`.
    let sessionID: String?
    let agentID: String?
    let text: String
}

struct WatchAgent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let role: String
}

struct WatchHome: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case ready
        /// No computer is set up on the iPhone yet.
        case noHost
        /// The computer didn't answer.
        case unreachable
    }

    var status: Status
    /// Changes with the host, so the Watch forgets another host's chats.
    var hostKey: String
    var agents: [WatchAgent]
    var homeAgentID: String?
    var needs: [WatchNeed]
    var chats: [WatchChatSummary]
    var generatedAt: Date

    static func unavailable(_ status: Status) -> Self {
        Self(status: status, hostKey: "", agents: [], homeAgentID: nil, needs: [], chats: [], generatedAt: .now)
    }
}

struct WatchChatSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let agentID: String?
    let agentName: String
    let preview: String
    let updatedAt: Date
    let isWorking: Bool
}

struct WatchMessage: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let isYou: Bool
    let text: String
    let at: Date
}

struct WatchChat: Codable, Equatable, Sendable {
    let sessionID: String
    let title: String
    let agentName: String
    let messages: [WatchMessage]
    let isWorking: Bool
}

enum WatchDecision: String, Codable, CaseIterable, Equatable, Sendable {
    case once, session, always, deny

    var title: String {
        switch self {
        case .once: "Approve"
        case .session: "Approve for this chat"
        case .always: "Always approve"
        case .deny: "Deny"
        }
    }

    /// Wider approvals ask again before they're sent.
    var needsConfirmation: Bool { self == .session || self == .always }
}

/// An approval or question waiting on the person.
struct WatchNeed: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case approval, question }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let agentName: String
    let sessionID: String?
    let createdAt: Date
    /// Approvals: what Hermes offered.
    let decisions: [WatchDecision]
    /// Questions: the agent's suggested answers.
    let choices: [String]
    let allowsTyping: Bool
    /// Too big or complex for the Watch (several questions, many choices).
    let answerOnPhone: Bool
    /// Where "Open on iPhone" goes.
    let link: WatchPhoneLink?
}

enum WatchBoardKind: String, Codable, CaseIterable, Sendable {
    case feed, ideas, goals

    var title: String {
        switch self {
        case .feed: "Feed"
        case .ideas: "Ideas"
        case .goals: "Goals"
        }
    }
}

struct WatchBoardItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let body: String
    let icon: String
    /// Goals: "done", "active"…
    let status: String
    let note: String
    let createdAt: Date
    let isUnread: Bool
}

/// Where "Open on iPhone" goes: one of bighelp's own links.
struct WatchPhoneLink: Codable, Hashable, Sendable {
    /// The Watch offers what it shows to the iPhone through Handoff too.
    static let handoffActivityType = "app.loopdy.mobile.open"

    let url: String
    let title: String

    static func chat(_ sessionID: String, title: String) -> Self {
        Self(url: "loopdy://chat/\(Self.escaped(sessionID))", title: title)
    }

    static func approval(_ id: String, title: String) -> Self {
        Self(url: "loopdy://approval/\(Self.escaped(id))", title: title)
    }

    static func board(_ kind: WatchBoardKind, agentID: String, title: String) -> Self {
        Self(url: "loopdy://agent/\(kind.rawValue)?agent=\(Self.escaped(agentID))", title: title)
    }

    private static func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&=")))
            ?? value
    }
}

enum WatchWireError: Error, Equatable {
    case invalid
    case tooLarge
}

/// Property-list envelopes over WatchConnectivity (the system encrypts the
/// link between paired devices). One key per direction, bounded size.
enum WatchWire {
    static let requestKey = "bighelp.watch.v3.request"
    static let replyKey = "bighelp.watch.v3.reply"
    static let pushKey = "bighelp.watch.v3.push"
    /// WatchConnectivity allows about 64 KB per message.
    static let maximumBytes = 60_000

    static func encode<Value: Encodable>(_ value: Value, key: String) throws -> [String: Any] {
        let data = try PropertyListEncoder().encode(value)
        guard data.count <= maximumBytes else { throw WatchWireError.tooLarge }
        return [key: data]
    }

    static func decode<Value: Decodable & WatchChecked>(_ type: Value.Type, key: String,
                                                       from dictionary: [String: Any]) throws -> Value {
        guard dictionary.count == 1, let data = dictionary[key] as? Data,
              data.count <= maximumBytes else { throw WatchWireError.invalid }
        let value = try PropertyListDecoder().decode(type, from: data)
        guard value.isWellFormed else { throw WatchWireError.invalid }
        return value
    }

    /// At most `bytes` of UTF-8, cut on a character boundary.
    static func bounded(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        for character in text {
            guard result.utf8.count + character.utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
    }
}

/// Every value that crosses is checked for size before it's used.
protocol WatchChecked {
    var isWellFormed: Bool { get }
}

private extension String {
    func fits(_ bytes: Int, allowEmpty: Bool = true) -> Bool {
        utf8.count <= bytes && !contains("\0") && (allowEmpty || !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private extension Date {
    var isSane: Bool { timeIntervalSince1970.isFinite }
}

enum WatchLimits {
    static let id = 240
    static let title = 200
    static let name = 120
    static let preview = 400
    static let message = 2_000
    static let detail = 1_200
    static let body = 1_500
    static let outgoing = 10_000
    static let messages = 24
    static let chats = 20
    static let needs = 12
    static let agents = 16
    static let boardItems = 30
    static let choices = 4
}

extension WatchRequest: WatchChecked {
    var isWellFormed: Bool {
        switch self {
        case .home: true
        case .chat(let id): id.fits(WatchLimits.id, allowEmpty: false)
        case .send(let outgoing):
            outgoing.text.fits(WatchLimits.outgoing, allowEmpty: false)
                && (outgoing.sessionID?.fits(WatchLimits.id, allowEmpty: false) ?? true)
                && (outgoing.agentID?.fits(WatchLimits.id, allowEmpty: false) ?? true)
        case .board(let agentID, _): agentID.fits(WatchLimits.id, allowEmpty: false)
        case .decide(let id, _): id.fits(WatchLimits.id, allowEmpty: false)
        case .answer(let id, let text):
            id.fits(WatchLimits.id, allowEmpty: false) && text.fits(WatchLimits.outgoing, allowEmpty: false)
        case .open(let link):
            link.url.fits(1_024, allowEmpty: false) && link.title.fits(WatchLimits.title)
        }
    }
}

extension WatchReply: WatchChecked {
    var isWellFormed: Bool {
        switch self {
        case .home(let home): home.isWellFormed
        case .chat(let chat): chat.isWellFormed
        case .sent(let id): id.fits(WatchLimits.id, allowEmpty: false)
        case .board(let items): items.count <= WatchLimits.boardItems && items.allSatisfy(\.isWellFormed)
        case .done: true
        case .failed(let text): text.fits(400)
        }
    }
}

extension WatchPush: WatchChecked {
    var isWellFormed: Bool {
        switch self {
        case .replyReady(let id): id.fits(WatchLimits.id, allowEmpty: false)
        }
    }
}

extension WatchHome: WatchChecked {
    var isWellFormed: Bool {
        generatedAt.isSane && hostKey.fits(128)
            && agents.count <= WatchLimits.agents && Set(agents.map(\.id)).count == agents.count
            && agents.allSatisfy { $0.id.fits(WatchLimits.id, allowEmpty: false) && $0.name.fits(WatchLimits.name) && $0.role.fits(WatchLimits.name) }
            && (homeAgentID?.fits(WatchLimits.id) ?? true)
            && needs.count <= WatchLimits.needs && Set(needs.map(\.id)).count == needs.count
            && needs.allSatisfy(\.isWellFormed)
            && chats.count <= WatchLimits.chats && Set(chats.map(\.id)).count == chats.count
            && chats.allSatisfy(\.isWellFormed)
    }
}

extension WatchChatSummary: WatchChecked {
    var isWellFormed: Bool {
        id.fits(WatchLimits.id, allowEmpty: false) && title.fits(WatchLimits.title)
            && (agentID?.fits(WatchLimits.id) ?? true) && agentName.fits(WatchLimits.name)
            && preview.fits(WatchLimits.preview) && updatedAt.isSane
    }
}

extension WatchChat: WatchChecked {
    var isWellFormed: Bool {
        sessionID.fits(WatchLimits.id, allowEmpty: false) && title.fits(WatchLimits.title)
            && agentName.fits(WatchLimits.name) && messages.count <= WatchLimits.messages
            && Set(messages.map(\.id)).count == messages.count
            && messages.allSatisfy { $0.id.fits(WatchLimits.id, allowEmpty: false) && $0.text.fits(WatchLimits.message) && $0.at.isSane }
    }
}

extension WatchNeed: WatchChecked {
    var isWellFormed: Bool {
        id.fits(WatchLimits.id, allowEmpty: false) && title.fits(WatchLimits.title)
            && detail.fits(WatchLimits.detail) && agentName.fits(WatchLimits.name)
            && (sessionID?.fits(WatchLimits.id) ?? true) && createdAt.isSane
            && decisions.count <= WatchDecision.allCases.count && Set(decisions).count == decisions.count
            && choices.count <= WatchLimits.choices && choices.allSatisfy { $0.fits(500, allowEmpty: false) }
            && (link.map { $0.url.fits(1_024, allowEmpty: false) && $0.title.fits(WatchLimits.title) } ?? true)
    }
}

extension WatchBoardItem: WatchChecked {
    var isWellFormed: Bool {
        id.fits(WatchLimits.id, allowEmpty: false) && title.fits(WatchLimits.title)
            && body.fits(WatchLimits.body) && icon.fits(64) && status.fits(64) && note.fits(WatchLimits.preview)
            && createdAt.isSane
    }
}
