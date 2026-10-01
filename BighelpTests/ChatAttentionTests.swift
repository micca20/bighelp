import Foundation
import Testing
@testable import Bighelp

/// A question or approval pops up by itself once, when it arrives with the
/// chat in front. Closing it answers nothing, and it never pops up again on
/// its own; the bar above the chat reopens it.
struct ChatAttentionPopupTests {
    @Test func aNewRequestPopsUpOnceAndClosingItDoesNotBringItBack() {
        var popups = ChatAttentionPopups()
        let popsUp = popups.shouldPopUp(waiting: ["a"], canPopUp: true, isOpen: false)
        #expect(popsUp)
        // Closed with Later: still waiting, not popped again.
        let popsAgain = popups.shouldPopUp(waiting: ["a"], canPopUp: true, isOpen: false)
        #expect(!popsAgain)
        let newOnePops = popups.shouldPopUp(waiting: ["a", "b"], canPopUp: true, isOpen: false)
        #expect(newOnePops)
    }

    @Test func aRequestArrivingWhileItsOpenIsAlreadyShown() {
        var popups = ChatAttentionPopups()
        let popsUp = popups.shouldPopUp(waiting: ["a"], canPopUp: true, isOpen: false)
        #expect(popsUp)
        let popsWhileOpen = popups.shouldPopUp(waiting: ["a", "b"], canPopUp: false, isOpen: true)
        #expect(!popsWhileOpen)
        let popsAfterClosing = popups.shouldPopUp(waiting: ["a", "b"], canPopUp: true, isOpen: false)
        #expect(!popsAfterClosing)
    }

    @Test func aRequestWaitsForTheChatToComeToTheFront() {
        var popups = ChatAttentionPopups()
        let popsBehindSomething = popups.shouldPopUp(waiting: ["a"], canPopUp: false, isOpen: false)
        #expect(!popsBehindSomething)
        let popsInFront = popups.shouldPopUp(waiting: ["a"], canPopUp: true, isOpen: false)
        #expect(popsInFront)
    }

    @Test func anEmptyDraftIsntKept() {
        #expect(DirectHermesPromptAnswerDraft(ownWords: "  ", selections: [0: [], 1: []]).isEmpty)
        #expect(!DirectHermesPromptAnswerDraft(ownWords: "", selections: [0: [1]]).isEmpty)
        #expect(!DirectHermesPromptAnswerDraft(ownWords: "Ship it", selections: [:]).isEmpty)
    }
}

/// A request that arrives while its chat isn't on screen gets one alert, and
/// tapping it opens that chat.
struct BighelpPromptAlertTests {
    @Test func eachRequestIsNewOnce() {
        var ledger = BighelpPromptAlertLedger()
        let first = ledger.arrivals(["a", "b"])
        #expect(first == ["a", "b"])
        let again = ledger.arrivals(["a", "b"])
        #expect(again.isEmpty)
        let next = ledger.arrivals(["b", "c"])
        #expect(next == ["c"])
    }

    @Test func onlyAChatYoureNotLookingAtGetsAnAlert() {
        let visible: Set = ["chat-1"]
        #expect(!BighelpPromptAlertLedger.needsAlert(conversationID: "chat-1", visibleChats: visible, appIsActive: true))
        #expect(BighelpPromptAlertLedger.needsAlert(conversationID: "chat-2", visibleChats: visible, appIsActive: true))
        #expect(BighelpPromptAlertLedger.needsAlert(conversationID: "chat-1", visibleChats: visible, appIsActive: false))
    }

    @Test func theAlertOpensItsChat() throws {
        let id = "native-session-v1:scope-1:ZGVtbw:c2Vzc2lvbi0x"
        let url = try #require(BighelpPromptAlertLink.url(conversationID: id))
        #expect(BighelpIncomingURLRoute.parse(url) == .chat(sessionID: id))
        #expect(BighelpPromptAlertLink.url(in: [BighelpPromptAlertLink.userInfoKey: url.absoluteString]) == url)
        #expect(BighelpPromptAlertLink.url(in: [BighelpPromptAlertLink.userInfoKey: "loopdy://tasks"]) == nil)
        #expect(BighelpPromptAlertLink.url(in: [:]) == nil)
    }
}
