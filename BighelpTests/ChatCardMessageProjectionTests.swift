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

    /// Issue #18: while a card streams, its code never shows; a loader holds its place.
    @Test func aCardStillStreamingIsALoaderNotCode() {
        let partial = "Here's the forecast.\n\n```loopdy-card\n{\"schema\":\"loopdy.generative_ui\",\"vers"
        let streaming = ChatCardMessageProjection(source: partial, role: .assistant, isStreaming: true)
        #expect(streaming.segments.count == 2)
        #expect(streaming.segments.last == .pendingCard)
        #expect(!streaming.visibleText.contains("schema"))
        #expect(streaming.visibleText.contains("Here's the forecast."))
    }

    @Test(arguments: ["```", "```loo", "```loopdy-car"])
    func aFenceSplitAcrossChunksHidesItsHalfTypedMarker(marker: String) {
        let projection = ChatCardMessageProjection(source: fence + "\n\nAnd one more:\n" + marker,
                                                   role: .assistant, isStreaming: true)
        #expect(projection.cardIDs.count == 1)
        #expect(!projection.visibleText.contains("```"))
        if marker != "```" { #expect(projection.segments.last == .pendingCard) }
    }

    @Test func ordinaryCodeStillStreamsAsCode() {
        let projection = ChatCardMessageProjection(source: "Try this:\n```swift\nlet x = 1", role: .assistant,
                                                   isStreaming: true)
        #expect(!projection.segments.contains(.pendingCard))
        #expect(projection.visibleText.contains("let x = 1"))
    }

    /// A finished message whose card never closed, or isn't valid, says so
    /// plainly instead of leaving a loader or raw card code.
    @Test(arguments: [false, true])
    func aCardThatNeverFinishedSaysSo(closed: Bool) {
        let source = "Forecast:\n```loopdy-card\n{\"schema\":\"loopdy.generative_ui\",\"vers" + (closed ? "\n```" : "")
        let projection = ChatCardMessageProjection(source: source, role: .assistant)
        #expect(projection.segments.last == .unavailableCard)
        #expect(!projection.visibleText.contains("schema"))
    }

    @Test func severalCardsAndTheOneStillComingKeepTheirOrder() {
        let projection = ChatCardMessageProjection(source: fence + "\nBetween\n" + fence.replacingOccurrences(
            of: "Fixture", with: "Second").replacingOccurrences(of: "Retained card", with: "Other")
            + "\n```loopdy-card\n{", role: .assistant, isStreaming: true)
        let kinds = projection.segments.map { segment -> String in
            switch segment {
            case .card: "card"
            case .pendingCard: "pending"
            case .markdown: "text"
            default: "other"
            }
        }
        #expect(kinds == ["card", "text", "card", "pending"])
    }
}

private extension ChatCardMessageProjection {
    var visibleText: String {
        segments.compactMap { if case .markdown(let document) = $0 { document.visiblePlainText } else { nil } }
            .joined(separator: "\n")
    }
}
