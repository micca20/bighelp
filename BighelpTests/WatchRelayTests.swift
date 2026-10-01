import Foundation
import Testing
@testable import Bighelp

/// The Watch's side door into bighelp on the iPhone: what crosses, how big it
/// can get, and what the Watch is shown.
struct WatchRelayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func requestsAndRepliesCrossIntact() throws {
        let request = WatchRequest.send(WatchOutgoing(id: UUID(), sessionID: "s1", agentID: nil, text: "Book the table"))
        let encoded = try WatchWire.encode(request, key: WatchWire.requestKey)
        #expect(try WatchWire.decode(WatchRequest.self, key: WatchWire.requestKey, from: encoded) == request)

        let reply = WatchReply.chat(WatchChat(sessionID: "s1", title: "Dinner", agentName: "Mina Shah", messages: [
            WatchMessage(id: "m1", isYou: true, text: "Book the table", at: now),
        ], isWorking: true))
        let payload = WatchRelay.payload(for: reply)
        #expect(try WatchWire.decode(WatchReply.self, key: WatchWire.replyKey, from: payload) == reply)
    }

    @Test func oversizedOrOddMessagesAreRefused() throws {
        let long = WatchRequest.answer(needID: "n1", text: String(repeating: "a", count: 10_001))
        let encoded = try WatchWire.encode(long, key: WatchWire.requestKey)
        #expect(throws: WatchWireError.invalid) {
            try WatchWire.decode(WatchRequest.self, key: WatchWire.requestKey, from: encoded)
        }
        let blank = try WatchWire.encode(WatchRequest.chat(sessionID: "  "), key: WatchWire.requestKey)
        #expect(throws: WatchWireError.invalid) {
            try WatchWire.decode(WatchRequest.self, key: WatchWire.requestKey, from: blank)
        }
        // Another key, or extra keys, are someone else's message.
        #expect(throws: WatchWireError.invalid) {
            try WatchWire.decode(WatchRequest.self, key: WatchWire.replyKey, from: encoded)
        }
    }

    @Test func aTooBigReplyIsCutToFit() throws {
        // A full board of long items is more than one Watch message holds.
        // Every text differs: a property list stores repeated strings once.
        func text(_ index: Int, _ bytes: Int) -> String {
            String("\(index)-".appending(String(repeating: "\(index % 10)", count: bytes)).prefix(bytes))
        }
        let items = (0..<WatchLimits.boardItems).map {
            WatchBoardItem(id: "i\($0)", title: text($0, WatchLimits.title), body: text($0 + 100, WatchLimits.body),
                           icon: "💡", status: "", note: text($0 + 200, WatchLimits.preview), createdAt: now,
                           isUnread: false)
        }
        #expect(throws: WatchWireError.tooLarge) { try WatchWire.encode(WatchReply.board(items), key: WatchWire.replyKey) }
        let payload = WatchRelay.payload(for: .board(items))
        guard case .board(let kept) = try WatchWire.decode(WatchReply.self, key: WatchWire.replyKey, from: payload) else {
            Issue.record("Expected a board")
            return
        }
        #expect(!kept.isEmpty && kept.count < items.count)
        #expect(kept.first?.id == "i0", "The newest items are the ones kept")
    }

    @Test func needsShowApprovalsAndSimpleQuestions() {
        let items = [
            DashboardAttentionItem(
                id: "native.approval.a1", title: "Run a command", detail: "rm -rf build", urgency: .needsReview,
                approvalID: "a1", sessionID: "s1", agentID: "finance",
                interaction: .approval(DashboardApprovalRequest(eventID: "native.approval.a1", approvalID: "a1",
                                                                allowedDecisions: [.deny, .once, .always],
                                                                expiresAt: now.addingTimeInterval(60))),
                createdAt: now),
            DashboardAttentionItem(
                id: "q1", title: "Mina has a question", detail: "", urgency: .important, sessionID: "s2", agentID: "travel",
                interaction: .clarification(DashboardClarificationRequest(
                    eventID: "q1", requestID: "r1", sessionID: "s2", question: "Which date?",
                    choices: ["Friday", "Saturday"], allowsCustomResponse: true, isMultiSelect: false, expiresAt: nil)),
                createdAt: now.addingTimeInterval(-60)),
            DashboardAttentionItem(
                id: "q2", title: "Pick several", detail: "", urgency: .important, sessionID: "s3",
                interaction: .clarification(DashboardClarificationRequest(
                    eventID: "q2", requestID: "r2", sessionID: "s3", question: "Which ones?",
                    choices: ["A", "B"], allowsCustomResponse: false, isMultiSelect: true, expiresAt: nil)),
                createdAt: now.addingTimeInterval(-120)),
            DashboardAttentionItem(
                id: "old", title: "Expired", detail: "", urgency: .needsReview, approvalID: "a0",
                interaction: .approval(DashboardApprovalRequest(eventID: "old", approvalID: "a0", allowedDecisions: [.once],
                                                                expiresAt: now.addingTimeInterval(-1))),
                createdAt: now),
        ]
        let needs = WatchRelayProjection.needs(items, agentNames: ["finance": "Avery Park", "travel": "Mina Shah"], now: now)
        #expect(needs.map(\.id) == ["native.approval.a1", "q1", "q2"], "Expired approvals don't show")

        let approval = needs[0]
        #expect(approval.decisions == [.once, .always, .deny], "Only what Hermes offered, in a steady order")
        #expect(approval.agentName == "Avery Park")
        #expect(approval.link == .approval("a1", title: "Run a command"), "Opens the approval itself on the phone")

        #expect(needs[1].choices == ["Friday", "Saturday"] && needs[1].allowsTyping && !needs[1].answerOnPhone)
        #expect(needs[1].link?.url == "loopdy://chat/s2")
        #expect(needs[2].answerOnPhone && needs[2].choices.isEmpty, "Several answers at once go to the phone")
    }

    @Test func chatsAreDirectAndNewestFirst() {
        let summaries = [
            SessionSummary(id: "old", kind: .direct, agentIDs: ["finance"], title: "Budget", preview: "Done",
                           updatedAt: now.addingTimeInterval(-600)),
            SessionSummary(id: "room", kind: .botMode, agentIDs: ["finance", "travel"], title: "Team", preview: "Hi",
                           updatedAt: now),
            SessionSummary(id: "new", kind: .direct, agentIDs: ["travel"], title: "", preview: "Looking",
                           updatedAt: now.addingTimeInterval(-60)),
        ]
        let chats = WatchRelayProjection.chats(summaries, agentNames: ["finance": "Avery Park", "travel": "Mina Shah"]) {
            $0 == "new"
        }
        #expect(chats.map(\.id) == ["new", "old"], "Group rooms stay on the phone")
        #expect(chats[0].title == "New chat" && chats[0].agentName == "Mina Shah" && chats[0].isWorking)
    }

    @Test func aChatShowsWordsNotMarkersOrTools() {
        func item(_ id: String, _ role: TimelineRole, _ content: TimelineContent) -> TimelineItem {
            TimelineItem(id: id, role: role,
                         sender: role == .human ? .user(snapshot: .init(name: "You"))
                                                : .agent(id: "finance", snapshot: .init(name: "Avery Park")),
                         content: content, metadata: .init(delivery: "Sent"))
        }
        let record = SessionRecord(id: "s1", kind: .direct, agentIDs: ["finance"], title: "Budget")
        let items = [
            item("1", .human, .message("Total it up")),
            item("2", .assistant, .message("NO_REPLY")),
            item("3", .assistant, .message("  It's $2,400.  ")),
            item("4", .assistant, .message(String(repeating: "x", count: 3_000))),
        ]
        let chat = WatchRelayProjection.chat(record, items: items, isWorking: false, agentNames: ["finance": "Avery Park"])
        #expect(chat.messages.map(\.id) == ["1", "3", "4"])
        #expect(chat.messages[1].text == "It's $2,400.")
        #expect(chat.messages[2].text.utf8.count <= WatchLimits.message && chat.messages[2].text.hasSuffix("…"))
        #expect(chat.agentName == "Avery Park")
    }

    @Test func boardsKeepOneKindAndPutOpenGoalsFirst() {
        let items = [
            AgentBoardItem(id: "g-done", kind: .goal, title: "Launch", status: "done", createdAt: now),
            AgentBoardItem(id: "g-open", kind: .goal, title: "Save for the trip", status: "active",
                           createdAt: now.addingTimeInterval(-86_400)),
            AgentBoardItem(id: "f1", kind: .feed, title: "Sign-ups doubled", createdAt: now),
            AgentBoardItem(id: "g-hidden", kind: .goal, title: "Hidden", dismissed: true, createdAt: now),
        ]
        #expect(WatchRelayProjection.board(items, kind: .goals).map(\.id) == ["g-open", "g-done"])
        #expect(WatchRelayProjection.board(items, kind: .feed).map(\.id) == ["f1"])
        #expect(WatchRelayProjection.board(items, kind: .ideas).isEmpty)
    }

    @Test func onlyBighelpsOwnLinksOpenOnThePhone() {
        #expect(WatchRelayProjection.openableURL("loopdy://chat/s1") != nil)
        #expect(WatchRelayProjection.openableURL(WatchPhoneLink.board(.ideas, agentID: "travel", title: "").url) != nil)
        #expect(WatchRelayProjection.openableURL("https://example.com") == nil)
        #expect(WatchRelayProjection.openableURL("loopdy://nowhere/at/all") == nil)
    }

    @Test func watchLinksOpenTheRightPlace() {
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://approval/a1")!) == .approval(id: "a1"))
        #expect(BighelpIncomingURLRoute.parse(URL(string: WatchPhoneLink.board(.goals, agentID: "travel", title: "").url)!)
                == .agent(tab: "goals", agentID: "travel"))
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://agent/feed")!) == .agent(tab: "feed"))
        #expect(WatchOpenRequest.url(in: [WatchOpenRequest.urlKey: "loopdy://chat/s1"])?.absoluteString == "loopdy://chat/s1")
        #expect(WatchOpenRequest.url(in: [WatchOpenRequest.urlKey: "https://example.com"]) == nil)
    }

    @Test func hostKeysAreStableAndSayNothing() {
        let host = UUID()
        #expect(WatchRelay.hostKey(for: host) == WatchRelay.hostKey(for: host))
        #expect(WatchRelay.hostKey(for: host) != WatchRelay.hostKey(for: UUID()))
        #expect(!WatchRelay.hostKey(for: host).contains(host.uuidString.lowercased().prefix(8)))
        #expect(WatchRelay.hostKey(for: nil).isEmpty)
    }
}
