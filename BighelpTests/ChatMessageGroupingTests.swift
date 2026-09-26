import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ChatMessageGroupingTests {
    private func message(_ id: String, _ role: TimelineRole) -> ChatCanvasRow {
        let sender: TimelineSender = role == .human
            ? .user(snapshot: .init(name: "Sam"))
            : .agent(id: "juno", snapshot: .init(name: "Juno"))
        return .transcript(.entry(.message(TimelineItem(
            id: id, role: role, sender: sender, content: .message("text \(id)"), metadata: .init(delivery: nil)
        ))))
    }

    @Test func onlyTheLastBubbleInASameSenderRunKeepsItsTail() {
        let rows = [
            message("u1", .human), message("u2", .human), message("u3", .human),
            message("a1", .assistant), message("a2", .assistant),
            message("u4", .human), .bottom
        ]
        let grouped = ChatView.groupedMessageRowIDs(rows)
        #expect(grouped == Set([rows[0].id, rows[1].id, rows[3].id]))
    }

    @Test func nonMessageRowsBreakAGroup() {
        let rows = [message("u1", .human), .divider("Bot Mode started"), message("u2", .human)]
        #expect(ChatView.groupedMessageRowIDs(rows).isEmpty)
    }
}
