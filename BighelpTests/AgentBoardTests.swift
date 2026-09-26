import Foundation
import Testing
@testable import Bighelp

@MainActor
struct AgentBoardTests {
    @Test func runningToolPicksTheAvatarReaction() {
        let expected: [String: AgentActivityKind] = [
            "terminal": .coding, "execute_code": .coding, "patch": .coding,
            "web_search": .web, "web_extract": .web, "browser_navigate": .web,
            "image_generate": .images, "vision_analyze": .seeing,
            "memory": .memory, "session_search": .memory, "skill_view": .memory,
            "cronjob": .scheduling, "delegate_task": .delegating,
            "read_file": .files, "write_file": .files, "search_files": .files,
            "send_message": .messaging, "text_to_speech": .messaging,
            "bighelp_board": .publishing, "clarify": .waiting, "todo": .tools,
        ]
        for (tool, kind) in expected {
            #expect(AgentActivityKind(toolName: tool) == kind, "\(tool)")
        }
        #expect(AgentActivityKind(category: "coding") == .coding)
        #expect(AgentActivityKind(category: "something-new") == .tools)
    }

    @Test func everyWorkingStateHasAMoveTheAvatarsKnow() {
        for kind in AgentActivityKind.allCases where kind != .idle {
            let mood = kind.moodID
            #expect(mood.map(BuddyPose.moods.contains) == true, "\(kind) → \(mood ?? "nil")")
            #expect(!kind.label.isEmpty)
        }
        #expect(AgentActivityKind.idle.moodID == nil)
        #expect(!AgentActivityKind.idle.isWorking && !AgentActivityKind.done.isWorking)
        #expect(AgentActivityKind.images.isWorking)
    }

    @Test func boardItemsKeepOnlySafeLinksAndPictures() throws {
        let json: BighelpJSONValue = .object([
            "id": .string("feed-1"), "kind": .string("feed"), "title": .string("Fares dropped"),
            "body": .string("Now $412"), "icon": .string("✈️"), "liked": .boolean(true),
            "createdAt": .integer(1_790_000_000), "updatedAt": .integer(1_790_000_100),
            "links": .array([
                .object(["url": .string("https://example.com/a"), "title": .string("Book")]),
                .object(["url": .string("javascript:alert(1)")]),
                .object(["url": .string("file:///etc/passwd")]),
            ]),
            "images": .array([
                .object(["url": .string("https://example.com/p.jpg")]),
                .object(["url": .string("http://example.com/plain.jpg")]),
                .object(["index": .integer(0)]),
                .object(["index": .integer(9)]),
            ]),
        ])
        let item = try AgentBoardItem(json: json)
        #expect(item.kind == .feed && item.liked && item.title == "Fares dropped")
        #expect(item.links.map(\.url.absoluteString) == ["https://example.com/a"])
        #expect(item.pictures == [.remote(URL(string: "https://example.com/p.jpg")!), .stored(index: 0)])
        #expect(item.createdAt == Date(timeIntervalSince1970: 1_790_000_000))

        #expect(throws: (any Error).self) { try AgentBoardItem(json: .object(["kind": .string("feed"), "title": .string("x")])) }
        #expect(throws: (any Error).self) {
            try AgentBoardItem(json: .object(["id": .string("a"), "kind": .string("poster"), "title": .string("x")]))
        }
    }

    @Test func likesShowAtOnceAndRollBackWhenHermesRefuses() async {
        let client = FakeBoardClient(items: [AgentBoardItem(id: "a", kind: .feed, title: "One")])
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.load(agentID: "default")
        #expect(store.state == .loaded && store.feed.count == 1)

        await store.setLiked(store.feed[0], true)
        #expect(store.feed[0].liked)

        client.failsUpdates = true
        await store.setLiked(store.feed[0], false)
        #expect(store.feed[0].liked, "A refused change must roll back")

        client.failsUpdates = false
        await store.dismiss(store.feed[0])
        #expect(store.feed.isEmpty)
    }

    @Test func goalsToggleDoneAndANewConnectionClearsTheBoard() async {
        let client = FakeBoardClient(items: [
            AgentBoardItem(id: "g", kind: .goal, title: "Sleep", section: "goal", status: "active"),
            AgentBoardItem(id: "t", kind: .goal, title: "Groceries", section: "tracking", status: "active"),
            AgentBoardItem(id: "i", kind: .idea, title: "Cheaper plan"),
        ])
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.load(agentID: "default")
        #expect(store.goals.count == 2 && store.ideas.count == 1)
        #expect(store.goals.filter(\.isTracking).map(\.id) == ["t"])

        await store.setDone(store.goals.first { $0.id == "g" }!, true)
        #expect(store.goals.first { $0.id == "g" }?.isDone == true)
        #expect(client.updates.last?.status == "done")

        store.configure(client: nil)
        #expect(store.items.isEmpty && store.state == .unavailable && !store.isAvailable)
        await store.load(agentID: "default")
        #expect(store.state == .unavailable)
    }

    @Test func profileHistoryLoadsEvenWithoutIdentityFiles() async {
        let client = FakeBoardClient(items: [])
        client.failsIdentity = true
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.loadLogs(agentID: "default")
        #expect(store.logState == .loaded)
        #expect(store.activity.map(\.title) == ["Checked the porch"])
        #expect(store.identity == nil)
    }

    @Test func feedGroupsByPartOfDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        func at(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
        }
        let now = at(25, 21)
        #expect(BoardTimeBucket.title(for: at(25, 19), now: now, calendar: calendar) == "This evening")
        #expect(BoardTimeBucket.title(for: at(25, 8), now: now, calendar: calendar) == "This morning")
        #expect(BoardTimeBucket.title(for: at(25, 2), now: now, calendar: calendar) == "Tonight")
        #expect(BoardTimeBucket.title(for: at(24, 14), now: now, calendar: calendar) == "Yesterday afternoon")
    }

    @Test func silentAnswersToReactionsLeaveNoBubble() {
        func reply(_ text: String, streaming: Bool = false) -> TimelineItem {
            TimelineItem(id: "a", role: .assistant, sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                         content: .message(text),
                         metadata: .init(source: "Direct Hermes", delivery: streaming ? "Streaming" : "Received"))
        }
        #expect(ChatSilentReply.hides(reply("[SILENT]")))
        #expect(ChatSilentReply.hides(reply("  no_reply\n")))
        #expect(ChatSilentReply.hides(reply("[SIL", streaming: true)))
        #expect(!ChatSilentReply.hides(reply("[SIL")))
        #expect(!ChatSilentReply.hides(reply("Silent films are great.")))
        #expect(!ChatSilentReply.hides(reply("[Link](https://example.com)", streaming: true)))

        let note = ChatReactionNote.text(emoji: "❤️", message: String(repeating: "word ", count: 80))
        #expect(note.hasPrefix("[The user reacted ❤️ to your message: \""))
        #expect(note.contains("…\"]"))
        #expect(note.hasSuffix("respond with exactly [SILENT]."))
    }

    @Test func islandAndAvatarShareOneActivityVocabulary() {
        for kind in AgentActivityKind.allCases {
            #expect(kind.pose.rawValue == kind.rawValue)
            #expect(kind.pose.symbolName == kind.systemImage)
            #expect(kind.pose.label == kind.label)
        }
        #expect(BighelpActivityPose(phase: .usingTool, tool: "coding") == .coding)
        #expect(BighelpActivityPose(phase: .usingTool, tool: "browser_navigate") == .web)
        #expect(BighelpActivityPose(phase: .usingTool, tool: nil) == .tools)
        #expect(BighelpActivityPose(phase: .responding, tool: "terminal") == .replying)
    }

    @Test func boardTextWaitsForTheNextNewChatOnly() {
        let state = AppState()
        state.pendingComposerText = "About my goal"
        #expect(state.consumeComposerText() == "About my goal")
        #expect(state.consumeComposerText() == nil)
        state.pendingComposerText = "Left over"
        state.resetForHostBoundary()
        #expect(state.pendingComposerText == nil)
    }
}

@MainActor
private final class FakeBoardClient: AgentBoardClient {
    var items: [AgentBoardItem]
    var failsUpdates = false
    var failsIdentity = false
    private(set) var updates: [(id: String, liked: Bool?, dismissed: Bool?, status: String?)] = []

    init(items: [AgentBoardItem]) { self.items = items }

    func items(agentID: String) async throws -> [AgentBoardItem] { items }

    func update(agentID: String, itemID: String, liked: Bool?, dismissed: Bool?, status: String?) async throws
        -> AgentBoardItem {
        if failsUpdates { throw WorkspaceClientError.invalidRequest }
        updates.append((itemID, liked, dismissed, status))
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { throw WorkspaceClientError.invalidRequest }
        if let liked { items[index].liked = liked }
        if let dismissed { items[index].dismissed = dismissed }
        if let status { items[index].status = status }
        return items[index]
    }

    func picture(agentID: String, itemID: String, index: Int) async throws -> Data { Data() }

    func activity(agentID: String) async throws -> [AgentActivityEntry] {
        [AgentActivityEntry(id: 1, sessionID: "s", title: "Checked the porch", request: "", summary: "",
                            kind: .seeing, outcome: "done", createdAt: .now)]
    }

    func approvals(agentID: String) async throws -> [AgentApprovalEntry] { [] }

    func identity(agentID: String) async throws -> AgentIdentityDocuments {
        if failsIdentity { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
        return AgentIdentityDocuments(soul: .init(), memory: .init(), user: .init())
    }
}
