import Foundation

/// Sample data for tests and screenshots (`-watch-demo`): no iPhone, no host.
/// Names and numbers are made up.
@MainActor
final class WatchDemoPhone: WatchPhoneTalking {
    var onPush: ((WatchPush) -> Void)?
    private var chats: [String: WatchChat]
    private var needs: [WatchNeed]
    private let agents = [
        WatchAgent(id: "finance", name: "Avery Park", role: "Finance"),
        WatchAgent(id: "travel", name: "Mina Shah", role: "Travel"),
        WatchAgent(id: "home", name: "Jordan Lee", role: "Home"),
    ]
    private var created = 0

    init(now: Date = .now) {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        chats = [
            "demo-budget": WatchChat(sessionID: "demo-budget", title: "Launch budget", agentName: "Avery Park", messages: [
                WatchMessage(id: "b1", isYou: true, text: "Can you total the launch costs?", at: ago(42)),
                WatchMessage(id: "b2", isYou: false, text: "It comes to $2,400: ads $1,500, dinner $600 and swag $300. Want me to trim ads?", at: ago(40)),
            ], isWorking: false),
            "demo-trip": WatchChat(sessionID: "demo-trip", title: "Kyoto in April", agentName: "Mina Shah", messages: [
                WatchMessage(id: "t1", isYou: true, text: "Find a quiet ryokan near the river.", at: ago(180)),
                WatchMessage(id: "t2", isYou: false, text: "Three options under $300 a night. The first has a garden bath and walks to Gion.", at: ago(176)),
            ], isWorking: false),
            "demo-sink": WatchChat(sessionID: "demo-sink", title: "Kitchen sink", agentName: "Jordan Lee", messages: [
                WatchMessage(id: "s1", isYou: true, text: "Book a plumber this week.", at: ago(300)),
            ], isWorking: true, activity: "Searching the web…"),
        ]
        needs = [
            WatchNeed(id: "need-publish", kind: .approval, title: "Run a command",
                      detail: "npm publish --tag beta\nPublishes version 2.4.0-beta.1 of the site kit.",
                      agentName: "Avery Park", sessionID: "demo-budget", createdAt: ago(3),
                      decisions: [.once, .session, .deny], choices: [], allowsTyping: false, answerOnPhone: false,
                      link: .approval("publish", title: "Run a command")),
            WatchNeed(id: "need-date", kind: .question, title: "Mina has a question",
                      detail: "Which date works for the launch party?",
                      agentName: "Mina Shah", sessionID: "demo-trip", createdAt: ago(9),
                      decisions: [], choices: ["Friday the 17th", "Saturday the 18th"], allowsTyping: true,
                      answerOnPhone: false, link: .chat("demo-trip", title: "Mina has a question")),
        ]
    }

    func ask(_ request: WatchRequest) async -> WatchReply {
        switch request {
        case .home:
            return .home(WatchHome(
                status: .ready, hostKey: "demo", agents: agents, homeAgentID: "finance", needs: needs,
                chats: chats.values.sorted { ($0.messages.last?.at ?? .distantPast) > ($1.messages.last?.at ?? .distantPast) }
                    .map { chat in
                        WatchChatSummary(id: chat.sessionID, title: chat.title, agentID: nil, agentName: chat.agentName,
                                         preview: chat.messages.last?.text ?? "", updatedAt: chat.messages.last?.at ?? .now,
                                         isWorking: chat.isWorking)
                    },
                generatedAt: .now))
        case .chat(let id):
            guard let chat = chats[id] else { return .failed("That chat isn't on your computer anymore.") }
            return .chat(chat)
        case .send(let outgoing):
            let id: String
            if let sessionID = outgoing.sessionID {
                id = sessionID
            } else {
                created += 1
                id = "demo-new-\(created)"
                let agent = agents.first { $0.id == outgoing.agentID } ?? agents[0]
                chats[id] = WatchChat(sessionID: id, title: "New chat", agentName: agent.name, messages: [], isWorking: false)
            }
            guard let chat = chats[id] else { return .failed("That chat isn't on your computer anymore.") }
            let message = WatchMessage(id: outgoing.id.uuidString, isYou: true, text: outgoing.text, at: .now)
            chats[id] = WatchChat(sessionID: id, title: chat.title, agentName: chat.agentName,
                                  messages: chat.messages + [message], isWorking: true)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.reply(in: id, to: outgoing.text)
            }
            return .sent(sessionID: id)
        case .board(_, let kind):
            return .board(Self.board(kind))
        case .decide(let id, _), .answer(let id, _):
            guard needs.contains(where: { $0.id == id }) else { return .failed("This was already answered or expired.") }
            needs.removeAll { $0.id == id }
            return .done
        case .open:
            return .done
        }
    }

    private func reply(in id: String, to text: String) {
        guard let chat = chats[id] else { return }
        let answer = WatchMessage(id: UUID().uuidString, isYou: false,
                                  text: "On it. I'll start with \"\(text.prefix(40))\" and check back when it's done.", at: .now)
        chats[id] = WatchChat(sessionID: id, title: chat.title, agentName: chat.agentName,
                              messages: chat.messages + [answer], isWorking: false)
        onPush?(.replyReady(sessionID: id))
    }

    private static func board(_ kind: WatchBoardKind) -> [WatchBoardItem] {
        let now = Date.now
        switch kind {
        case .feed:
            return [
                WatchBoardItem(id: "f1", title: "Sign-ups doubled this week", body: "The beta form brought in 184 sign-ups, up from 91 last week. Most came from the launch post.", icon: "📈", status: "", note: "", createdAt: now.addingTimeInterval(-3_600), isUnread: true),
                WatchBoardItem(id: "f2", title: "Card statement is ready", body: "September's statement is $1,284.16, due on the 12th. Nothing unusual stood out.", icon: "💳", status: "", note: "", createdAt: now.addingTimeInterval(-86_400), isUnread: false),
            ]
        case .ideas:
            return [
                WatchBoardItem(id: "i1", title: "Bundle the swag with early orders", body: "Early buyers get stickers and a tote. It uses the leftover swag budget and gives people a reason to order this week.", icon: "💡", status: "", note: "", createdAt: now.addingTimeInterval(-7_200), isUnread: true),
            ]
        case .goals:
            return [
                WatchBoardItem(id: "g1", title: "Save $5,000 for the trip", body: "At $400 a month you reach it by March.", icon: "🎯", status: "active", note: "$3,100 so far", createdAt: now.addingTimeInterval(-864_000), isUnread: false),
                WatchBoardItem(id: "g2", title: "Launch the beta", body: "Site, sign-up form and FAQ are live.", icon: "🚀", status: "done", note: "", createdAt: now.addingTimeInterval(-1_728_000), isUnread: false),
            ]
        }
    }
}
