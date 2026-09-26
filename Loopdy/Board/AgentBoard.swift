import Foundation
import Observation

// MARK: - What the agent is doing

/// What an agent is doing right now, from the tool it is running. Drives the
/// live avatar's reaction and the Activity list's icons. Mirrors the plugin's
/// `agent_board.tool_category` names.
enum AgentActivityKind: String, CaseIterable, Sendable {
    case idle, thinking, replying, coding, web, images, seeing, memory, scheduling
    case delegating, files, messaging, publishing, tools, waiting, done, failed

    /// Same rules as the Dynamic Island (`LoopdyActivityPose`), one source.
    init(toolName: String) {
        self = AgentActivityKind(rawValue: LoopdyActivityPose(tool: toolName).rawValue) ?? .tools
    }

    var pose: LoopdyActivityPose { LoopdyActivityPose(rawValue: rawValue) ?? .tools }

    /// The plugin's stored category names.
    init(category: String) {
        self = AgentActivityKind(rawValue: category) ?? .tools
    }

    var label: String {
        switch self {
        case .idle: "Here for you"
        case .thinking: "Thinking"
        case .replying: "Replying"
        case .coding: "Writing code"
        case .web: "Browsing the web"
        case .images: "Making images"
        case .seeing: "Taking a look"
        case .memory: "Remembering"
        case .scheduling: "Scheduling"
        case .delegating: "Working with helpers"
        case .files: "Working with files"
        case .messaging: "Sending a message"
        case .publishing: "Posting an update"
        case .tools: "Using tools"
        case .waiting: "Needs you"
        case .done: "All done"
        case .failed: "Hit a snag"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "circle"
        case .thinking: "sparkles"
        case .replying: "text.bubble"
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .web: "globe"
        case .images: "paintbrush.pointed"
        case .seeing: "eye"
        case .memory: "brain"
        case .scheduling: "calendar.badge.clock"
        case .delegating: "person.2"
        case .files: "doc.text"
        case .messaging: "paperplane"
        case .publishing: "pin"
        case .tools: "wrench.and.screwdriver"
        case .waiting: "hand.raised"
        case .done: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// The character mood for this activity.
    var moodID: String? {
        switch self {
        case .idle: nil
        case .thinking: "thinking"
        case .replying: "bounce"
        case .coding: "scan"
        case .web: "lookAround"
        case .images: "excited"
        case .seeing: "curious"
        case .memory: "nod"
        case .scheduling: "alert"
        case .delegating: "dance"
        case .files: "peek"
        case .messaging: "bounce"
        case .publishing: "happy"
        case .tools: "squint"
        case .waiting: "alert"
        case .done: "happy"
        case .failed: "sad"
        }
    }

    var isWorking: Bool { ![.idle, .done, .failed].contains(self) }
}

// MARK: - Board items

struct AgentBoardItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case feed, idea, goal }
    enum Picture: Equatable, Sendable {
        case remote(URL)
        case stored(index: Int)
    }
    struct Link: Equatable, Sendable {
        let url: URL
        let title: String
    }

    let id: String
    let kind: Kind
    var title: String
    var body: String
    var icon: String
    var section: String
    var status: String
    var note: String
    var links: [Link]
    var pictures: [Picture]
    var source: String
    var liked: Bool
    var dismissed: Bool
    var createdAt: Date
    var updatedAt: Date

    var isDone: Bool { status == "done" }
    var isTracking: Bool { section == "tracking" }

    init(id: String, kind: Kind, title: String, body: String = "", icon: String = "", section: String = "",
         status: String = "", note: String = "", links: [Link] = [], pictures: [Picture] = [],
         source: String = "", liked: Bool = false, dismissed: Bool = false,
         createdAt: Date = .now, updatedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.body = body; self.icon = icon
        self.section = section; self.status = status; self.note = note; self.links = links
        self.pictures = pictures; self.source = source; self.liked = liked; self.dismissed = dismissed
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }

    init(json value: LoopdyJSONValue) throws {
        guard let object = value.object, let id = object["id"]?.string, !id.isEmpty,
              let kind = object["kind"]?.string.flatMap(Kind.init(rawValue:)),
              let title = object["title"]?.string else { throw WorkspaceClientError.invalidResponse }
        let links: [Link] = (object["links"]?.array ?? []).compactMap { link in
            guard let url = link.object?["url"]?.string.flatMap(URL.init(string:)),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return Link(url: url, title: link.object?["title"]?.string ?? "")
        }
        let pictures: [Picture] = (object["images"]?.array ?? []).compactMap { image in
            if let url = image.object?["url"]?.string.flatMap(URL.init(string:)), url.scheme?.lowercased() == "https" {
                return .remote(url)
            }
            if let index = image.object?["index"]?.integer, (0..<6).contains(index) { return .stored(index: index) }
            return nil
        }
        func date(_ key: String) -> Date {
            Date(timeIntervalSince1970: TimeInterval(object[key]?.integer ?? 0))
        }
        self.init(id: id, kind: kind, title: title, body: object["body"]?.string ?? "",
                  icon: object["icon"]?.string ?? "", section: object["section"]?.string ?? "",
                  status: object["status"]?.string ?? "", note: object["note"]?.string ?? "",
                  links: links, pictures: pictures, source: object["source"]?.string ?? "",
                  liked: object["liked"]?.boolean ?? false, dismissed: object["dismissed"]?.boolean ?? false,
                  createdAt: date("createdAt"), updatedAt: date("updatedAt"))
    }
}

struct AgentActivityEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let sessionID: String
    let title: String
    let request: String
    let summary: String
    let kind: AgentActivityKind
    let outcome: String
    let createdAt: Date

    /// Hermes' session title reads best; the request is the fallback.
    var headline: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (request.isEmpty ? kind.label : request) : trimmed
    }

    init(id: Int, sessionID: String, title: String, request: String, summary: String,
         kind: AgentActivityKind, outcome: String, createdAt: Date) {
        self.id = id; self.sessionID = sessionID; self.title = title; self.request = request
        self.summary = summary; self.kind = kind; self.outcome = outcome; self.createdAt = createdAt
    }

    init(json value: LoopdyJSONValue) throws {
        guard let object = value.object, let id = object["id"]?.integer else { throw WorkspaceClientError.invalidResponse }
        self.init(id: id, sessionID: object["sessionId"]?.string ?? "", title: object["title"]?.string ?? "",
                  request: object["request"]?.string ?? "", summary: object["summary"]?.string ?? "",
                  kind: AgentActivityKind(category: object["category"]?.string ?? ""),
                  outcome: object["outcome"]?.string ?? "done",
                  createdAt: Date(timeIntervalSince1970: TimeInterval(object["createdAt"]?.integer ?? 0)))
    }
}

struct AgentApprovalEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let sessionTitle: String
    let description: String
    let command: String
    let choice: String
    let createdAt: Date

    var decisionLabel: String {
        switch choice {
        case "always": "Always allowed"
        case "session": "Allowed for this chat"
        case "once": "Allowed once"
        case "deny": "Denied"
        case "timeout", "transport_timeout": "Timed out"
        default: choice.hasPrefix("transport_") ? "Not answered" : "Answered"
        }
    }

    var wasAllowed: Bool { ["always", "session", "once"].contains(choice) }

    init(id: Int, sessionTitle: String, description: String, command: String, choice: String, createdAt: Date) {
        self.id = id; self.sessionTitle = sessionTitle; self.description = description
        self.command = command; self.choice = choice; self.createdAt = createdAt
    }

    init(json value: LoopdyJSONValue) throws {
        guard let object = value.object, let id = object["id"]?.integer else { throw WorkspaceClientError.invalidResponse }
        self.init(id: id, sessionTitle: object["sessionTitle"]?.string ?? "",
                  description: object["description"]?.string ?? "", command: object["command"]?.string ?? "",
                  choice: object["choice"]?.string ?? "",
                  createdAt: Date(timeIntervalSince1970: TimeInterval(object["createdAt"]?.integer ?? 0)))
    }
}

/// SOUL and memory text for the Identity tab's cards.
struct AgentIdentityDocuments: Equatable, Sendable {
    struct Document: Equatable, Sendable {
        var text: String
        var updatedAt: Date?
        var truncated: Bool

        init(text: String = "", updatedAt: Date? = nil, truncated: Bool = false) {
            self.text = text; self.updatedAt = updatedAt; self.truncated = truncated
        }

        init(json value: LoopdyJSONValue?) {
            let object = value?.object ?? [:]
            let seconds = object["updatedAt"]?.integer ?? 0
            self.init(text: object["text"]?.string ?? "",
                      updatedAt: seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil,
                      truncated: object["truncated"]?.boolean ?? false)
        }
    }

    var soul: Document
    var memory: Document
    var user: Document
}

// MARK: - Clients

@MainActor
protocol AgentBoardClient: AnyObject {
    func items(agentID: String) async throws -> [AgentBoardItem]
    func update(agentID: String, itemID: String, liked: Bool?, dismissed: Bool?, status: String?) async throws -> AgentBoardItem
    func picture(agentID: String, itemID: String, index: Int) async throws -> Data
    func activity(agentID: String) async throws -> [AgentActivityEntry]
    func approvals(agentID: String) async throws -> [AgentApprovalEntry]
    func identity(agentID: String) async throws -> AgentIdentityDocuments
}

/// The bighelp plugin's `native-agent-board-v1` routes.
@MainActor
final class DirectHermesAgentBoardClient: AgentBoardClient {
    private let workspace: any WorkspaceOperationPerforming
    private let owner: WorkspaceOwner

    init(workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner) {
        self.workspace = workspace
        self.owner = owner
    }

    private func perform(_ operation: WorkspaceOperation, _ payload: [String: LoopdyJSONValue]) async throws
        -> [String: LoopdyJSONValue] {
        guard workspace.owner == owner else { throw WorkspaceClientError.ownerChanged }
        return try await workspace.perform(operation, payload: payload, owner: owner)
    }

    func items(agentID: String) async throws -> [AgentBoardItem] {
        let result = try await perform(.boardList, ["agentId": .string(agentID), "limit": .integer(200)])
        return try (result["items"]?.array ?? []).map(AgentBoardItem.init(json:))
    }

    func update(agentID: String, itemID: String, liked: Bool?, dismissed: Bool?, status: String?) async throws
        -> AgentBoardItem {
        var payload: [String: LoopdyJSONValue] = ["agentId": .string(agentID), "itemId": .string(itemID)]
        if let liked { payload["liked"] = .boolean(liked) }
        if let dismissed { payload["dismissed"] = .boolean(dismissed) }
        if let status { payload["status"] = .string(status) }
        let result = try await perform(.boardUpdate, payload)
        guard let item = result["item"] else { throw WorkspaceClientError.invalidResponse }
        return try AgentBoardItem(json: item)
    }

    func picture(agentID: String, itemID: String, index: Int) async throws -> Data {
        let result = try await perform(.boardMedia, ["agentId": .string(agentID), "itemId": .string(itemID),
                                                     "index": .integer(index)])
        guard let encoded = result["data"]?.string, let data = Data(base64Encoded: encoded) else {
            throw WorkspaceClientError.invalidResponse
        }
        return data
    }

    func activity(agentID: String) async throws -> [AgentActivityEntry] {
        let result = try await perform(.boardActivity, ["agentId": .string(agentID), "limit": .integer(100)])
        return try (result["activity"]?.array ?? []).map(AgentActivityEntry.init(json:))
    }

    func approvals(agentID: String) async throws -> [AgentApprovalEntry] {
        let result = try await perform(.boardApprovals, ["agentId": .string(agentID), "limit": .integer(100)])
        return try (result["approvals"]?.array ?? []).map(AgentApprovalEntry.init(json:))
    }

    func identity(agentID: String) async throws -> AgentIdentityDocuments {
        let result = try await perform(.boardIdentity, ["agentId": .string(agentID)])
        return AgentIdentityDocuments(soul: .init(json: result["soul"]), memory: .init(json: result["memory"]),
                                      user: .init(json: result["user"]))
    }
}

// MARK: - Store

@MainActor
@Observable
final class AgentBoardStore {
    enum LoadState: Equatable { case idle, loading, loaded, unavailable, failed(String) }

    private(set) var agentID: String?
    private(set) var items: [AgentBoardItem] = []
    private(set) var activity: [AgentActivityEntry] = []
    private(set) var approvals: [AgentApprovalEntry] = []
    private(set) var identity: AgentIdentityDocuments?
    private(set) var state: LoadState = .idle
    private(set) var logState: LoadState = .idle
    /// Why there is no board: no host yet, or the host's plugin predates it.
    private(set) var isDisconnected = false
    private var client: (any AgentBoardClient)?
    private var pictures: [String: Data] = [:]
    private var generation = 0

    var isAvailable: Bool { client != nil }
    var feed: [AgentBoardItem] { items.filter { $0.kind == .feed && !$0.dismissed } }
    var ideas: [AgentBoardItem] { items.filter { $0.kind == .idea && !$0.dismissed } }
    var goals: [AgentBoardItem] { items.filter { $0.kind == .goal && !$0.dismissed } }

    /// A new client (host, account or plugin change) drops everything shown so far.
    func configure(client: (any AgentBoardClient)?, isDisconnected: Bool = false) {
        self.isDisconnected = client == nil && isDisconnected
        guard client !== self.client else { return }
        self.client = client
        generation &+= 1
        items = []; activity = []; approvals = []; pictures = [:]; identity = nil
        state = client == nil ? .unavailable : .idle
        logState = state
        agentID = nil
    }

    func load(agentID: String) async {
        guard let client else { state = .unavailable; return }
        let generation = generation
        if self.agentID != agentID {
            self.agentID = agentID
            items = []; activity = []; approvals = []; identity = nil
        }
        state = .loading
        do {
            let loaded = try await client.items(agentID: agentID)
            guard generation == self.generation, self.agentID == agentID else { return }
            items = loaded
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard generation == self.generation, self.agentID == agentID else { return }
            state = .failed((error as? WorkspaceClientError)?.localizedDescription ?? "Couldn't load this right now.")
        }
    }

    func loadLogs(agentID: String) async {
        guard let client else { logState = .unavailable; return }
        let generation = generation
        logState = .loading
        do {
            let nextActivity = try await client.activity(agentID: agentID)
            let nextApprovals = try await client.approvals(agentID: agentID)
            let nextIdentity = try? await client.identity(agentID: agentID)
            guard generation == self.generation else { return }
            activity = nextActivity
            approvals = nextApprovals
            identity = nextIdentity
            logState = .loaded
        } catch is CancellationError {
        } catch {
            guard generation == self.generation else { return }
            logState = .failed("Couldn't load this agent's history.")
        }
    }

    func setLiked(_ item: AgentBoardItem, _ liked: Bool) async {
        await mutate(item) { $0.liked = liked } send: { client, agent in
            try await client.update(agentID: agent, itemID: item.id, liked: liked, dismissed: nil, status: nil)
        }
    }

    func dismiss(_ item: AgentBoardItem) async {
        await mutate(item) { $0.dismissed = true } send: { client, agent in
            try await client.update(agentID: agent, itemID: item.id, liked: nil, dismissed: true, status: nil)
        }
    }

    func setDone(_ item: AgentBoardItem, _ done: Bool) async {
        await mutate(item) { $0.status = done ? "done" : "active" } send: { client, agent in
            try await client.update(agentID: agent, itemID: item.id, liked: nil, dismissed: nil,
                                    status: done ? "done" : "active")
        }
    }

    func picture(for item: AgentBoardItem, index: Int) async -> Data? {
        let key = "\(item.id)#\(index)"
        if let cached = pictures[key] { return cached }
        guard let client, let agentID else { return nil }
        guard let data = try? await client.picture(agentID: agentID, itemID: item.id, index: index) else { return nil }
        if pictures.count > 60 { pictures.removeAll() }
        pictures[key] = data
        return data
    }

    /// Optimistic: the change shows at once and rolls back if Hermes refuses it.
    private func mutate(
        _ item: AgentBoardItem,
        apply: (inout AgentBoardItem) -> Void,
        send: @MainActor (any AgentBoardClient, String) async throws -> AgentBoardItem
    ) async {
        guard let client, let agentID, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let before = items[index]
        apply(&items[index])
        let generation = generation
        do {
            let confirmed = try await send(client, agentID)
            guard generation == self.generation, let current = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[current] = confirmed
        } catch {
            guard generation == self.generation, let current = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[current] = before
        }
    }
}
