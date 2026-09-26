import Foundation
import Testing
@testable import Bighelp

struct ChatCardMessageProjectionTests {
    private var fence: String {
        "```loopdy-card\n{\"schema\":\"loopdy.generative_ui\",\"version\":1,\"component\":\"summary\",\"title\":\"Fixture\",\"body\":\"Retained card\"}\n```"
    }

    @Test func assistantCardPreservesSurroundingProseAndUserCodeStaysCode() {
        let source = "Before\n\n" + fence + "\n\nAfter"
        let assistant = ChatCardMessageProjection(source: source, role: .assistant)
        #expect(assistant.segments.count == 3)
        #expect(assistant.cardIDs.count == 1)
        #expect(ChatCardMessageProjection(source: source, role: .human).cardIDs.isEmpty)
    }

    @Test func incompleteAndNestedExampleFencesDoNotBecomeInteractiveCards() {
        #expect(ChatCardMessageProjection(source: String(fence.dropLast(3)), role: .assistant).cardIDs.isEmpty)
        for enclosing in ["````", "~~~"] {
            let source = enclosing + "text\n" + fence + "\n" + enclosing
            #expect(ChatCardMessageProjection(source: source, role: .assistant).cardIDs.isEmpty)
        }
    }
}
