import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ChatInterimRepliesTests {
    private let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery"))

    private func human(_ id: String) -> ChatTranscriptEntry {
        .message(TimelineItem(id: id, role: .human, sender: .user(snapshot: .init(name: "You")),
                              content: .message("Question"), metadata: .init()))
    }

    private func reply(_ id: String, _ text: String = "Reply") -> ChatTranscriptEntry {
        .message(TimelineItem(id: id, role: .assistant, sender: agent, content: .message(text), metadata: .init()))
    }

    private func work(_ id: String) -> ChatTranscriptEntry {
        .activity(ChatActivityTurn(id: id, events: [ChatActivityEvent(
            eventID: id, sessionID: "s", turnID: "t", kind: .tool, lifecycle: .succeeded,
            title: "Tool", summary: nil, detail: nil, occurredAt: 1)]))
    }

    private func interimIDs(_ entries: [ChatTranscriptEntry]) -> [String] {
        entries.compactMap { entry in
            guard case .message(let item) = entry, item.metadata.isInterimReply else { return nil }
            return item.id
        }
    }

    @Test func inAFinishedTurnOnlyTheLastReplyIsTheAnswer() {
        let entries = [human("q"), reply("a"), work("w1"), reply("b"), work("w2"), reply("answer"), work("w3")]
        let marked = ChatInterimReplies.marking(entries, isSending: false, isBotMode: false)
        #expect(interimIDs(marked) == ["a", "b"])
    }

    @Test func whileReplyingAMessageTurnsInterimOnceMoreWorkFollows() {
        let streaming = [human("q1"), reply("done"), human("q2"), reply("a"), work("w"), reply("latest")]
        #expect(interimIDs(ChatInterimReplies.marking(streaming, isSending: true, isBotMode: false)) == ["a"])
        let working = [human("q"), reply("a"), work("w")]
        #expect(interimIDs(ChatInterimReplies.marking(working, isSending: true, isBotMode: false)) == ["a"])
    }

    @Test func earlierTurnsAndOtherContentKeepTheirLook() {
        let entries = [human("q1"), reply("first answer"), human("q2"), reply("empty", "  "), work("w"), reply("second answer")]
        #expect(interimIDs(ChatInterimReplies.marking(entries, isSending: false, isBotMode: false)).isEmpty)
    }

    @Test func plainMessagesInARowAreAllAnswers() {
        let entries = [human("q"), reply("a"), reply("b"), work("w"), reply("c"), reply("d")]
        // Only a message the agent kept working after is interim.
        #expect(interimIDs(ChatInterimReplies.marking(entries, isSending: false, isBotMode: false)) == ["a", "b"])
        #expect(interimIDs(ChatInterimReplies.marking([human("q"), reply("a"), reply("b")], isSending: true, isBotMode: false)).isEmpty)
    }

    @Test func roomRepliesAreEachAgentsAnswer() {
        let entries = [human("q"), reply("a"), work("w"), reply("b")]
        #expect(interimIDs(ChatInterimReplies.marking(entries, isSending: false, isBotMode: true)).isEmpty)
    }

    @Test func theInterimMarkIsNeverSaved() throws {
        guard case .message(let item) = reply("a") else { return }
        let data = try JSONEncoder().encode(item.markedInterim())
        let decoded = try JSONDecoder().decode(TimelineItem.self, from: data)
        #expect(!decoded.metadata.isInterimReply)
        #expect(decoded == item)
    }
}
