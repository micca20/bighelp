import CoreGraphics
import Testing
@testable import Loopdy

@Suite
struct IMessageChatPresentationTests {
    @Test func reactionBadgesStayCompactAndOverlapTheBubbleEdge() {
        #expect(NativeMessageReactionLayoutMetrics.visualHeight < LoopdyTokens.hitTarget)
        #expect(NativeMessageReactionLayoutMetrics.visualHeight >= 20)
        #expect(NativeMessageReactionLayoutMetrics.attachmentOverlap > 0)
        #expect(
            NativeMessageReactionLayoutMetrics.attachmentOverlap
                < NativeMessageReactionLayoutMetrics.visualHeight
        )
    }

    @Test func proseBubblesUseConversationalWidths() {
        #expect(
            LoopdyV3MessagePresentation.maximumWidthFraction(
                role: .human,
                hasRichContent: false
            ) == 0.84
        )
        #expect(
            LoopdyV3MessagePresentation.maximumWidthFraction(
                role: .assistant,
                hasRichContent: false
            ) == 0.92
        )
    }

    @Test func richCardsRetainTheWiderChatCanvas() {
        #expect(
            LoopdyV3MessagePresentation.maximumWidthFraction(
                role: .assistant,
                hasRichContent: true
            ) == 0.94
        )
    }

    @Test func bubbleGeometryKeepsOnlyTheSpeakerSideTight() {
        #expect(LoopdyV3MessagePresentation.bubbleRadius > LoopdyV3MessagePresentation.tailRadius)
        #expect(LoopdyV3MessagePresentation.tailRadius >= 6)
    }

    @Test func iPadMessageWidthRemainsReadable() {
        let outgoing = ChatBubbleLayoutMetrics.maximumWidth(
            containerWidth: 1_024,
            maximumWidthFraction: LoopdyV3MessagePresentation.outgoingMaximumWidthFraction
        )
        let incoming = ChatBubbleLayoutMetrics.maximumWidth(
            containerWidth: 1_024,
            maximumWidthFraction: LoopdyV3MessagePresentation.incomingMaximumWidthFraction
        )
        let rich = ChatBubbleLayoutMetrics.maximumWidth(
            containerWidth: 1_024,
            maximumWidthFraction: LoopdyV3MessagePresentation.richContentMaximumWidthFraction
        )

        #expect(outgoing <= ChatBubbleLayoutMetrics.maximumAbsoluteWidth)
        #expect(incoming <= ChatBubbleLayoutMetrics.maximumAbsoluteWidth)
        #expect(rich <= ChatBubbleLayoutMetrics.maximumAbsoluteWidth)
        #expect(outgoing <= incoming)
        #expect(incoming <= rich)
    }
}
