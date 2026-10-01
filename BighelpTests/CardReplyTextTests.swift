import Foundation
import Testing
@testable import Bighelp

/// A card's answer reads the same to the person and the agent: labels, not IDs.
@MainActor
struct CardReplyTextTests {
    @Test func formAnswersUseLabelsAndSkipBlankOptionalFields() {
        let options = [(id: "den", label: "Denver"), (id: "slc", label: "Salt Lake City")]
        let reply = CardReplyText.form(title: "Trip details", answers: [
            .init(label: "Where to", text: CardReplyText.value(.string("den"), kind: "select", options: options)),
            .init(label: "Also visit", text: CardReplyText.value(.array([.string("slc"), .string("den")]),
                                                                  kind: "multi_select", options: options)),
            .init(label: "Flexible", text: CardReplyText.value(.boolean(false), kind: "toggle", options: [])),
            .init(label: "Nights", text: CardReplyText.value(.integer(3), kind: "integer", options: [])),
            .init(label: "Budget", text: CardReplyText.value(.number(1250.5), kind: "decimal", options: [])),
            .init(label: "Notes", text: CardReplyText.value(.string("Window seat\nNo red-eyes"), kind: "textarea", options: [])),
            .init(label: "Promo code", text: CardReplyText.value(nil, kind: "text", options: [])),
        ])
        #expect(reply == """
        My answers to “Trip details”:
        - Where to: Denver
        - Also visit: Salt Lake City, Denver
        - Flexible: No
        - Nights: 3
        - Budget: 1250.5
        - Notes: Window seat
          No red-eyes
        """)
    }

    @Test func datesAreWrittenOut() {
        let text = CardReplyText.value(.string("2026-10-04"), kind: "date", options: [])
        #expect(!text.contains("2026-10-04"))
        #expect(text.contains("2026"))
    }

    @Test func aFormLeftBlankStillSaysSo() {
        #expect(CardReplyText.form(title: "Feedback", answers: [.init(label: "Comments", text: " ")])
            == "My answers to “Feedback”:\n- (I left everything blank.)")
    }

    @Test func pickedOptionsSendTheAgentsOwnWordsOnePerLine() {
        #expect(CardReplyText.selection(["Book the 9:40 flight.", "  ", "Add a hotel near the venue."])
            == "Book the 9:40 flight.\nAdd a hotel near the venue.")
    }

    // MARK: The card's handler

    private func handler(sends: Bool, sent: @escaping (String) -> Void = { _ in },
                         current: Bool = true, store: BighelpCardInteractionStore) -> ChatCardInteractionHandler {
        let scope = ChatCardInteractionScope(authorityID: "host", profileID: "agent", conversationID: "chat")
        return ChatCardInteractionHandler(
            scope: scope, store: store, currentDraft: { "" }, stageComposer: { _, _ in },
            sendReply: { text in sent(text); return sends },
            currentScope: { current ? scope : nil }
        )
    }

    private func freshStore() -> BighelpCardInteractionStore {
        BighelpCardInteractionStore(defaults: UserDefaults(suiteName: "card-reply-tests-\(UUID().uuidString)")!)
    }

    @Test func aSentReplyIsRememberedForTheCard() throws {
        let store = freshStore()
        var sent: [String] = []
        let handler = handler(sends: true, sent: { sent.append($0) }, store: store)
        let identity = ChatCardInteractionIdentity(scope: handler.scope, messageID: "m1", cardID: "c1")

        try handler.reply("Option B", for: identity)

        #expect(sent == ["Option B"])
        #expect(store.reply(for: identity) == "Option B")
        #expect(store.reply(for: .init(scope: handler.scope, messageID: "m1", cardID: "other")) == nil)
    }

    @Test func aReplyTheChatCantSendIsNotRemembered() {
        let store = freshStore()
        let handler = handler(sends: false, store: store)
        let identity = ChatCardInteractionIdentity(scope: handler.scope, messageID: "m1", cardID: "c1")

        #expect(throws: ChatCardInteractionError.self) { try handler.reply("Option B", for: identity) }
        #expect(store.reply(for: identity) == nil)
    }

    @Test func aCardFromAnotherChatCantReply() {
        var sent: [String] = []
        let store = freshStore()
        let handler = handler(sends: true, sent: { sent.append($0) }, current: false, store: store)
        let identity = ChatCardInteractionIdentity(scope: handler.scope, messageID: "m1", cardID: "c1")

        #expect(throws: ChatCardInteractionError.self) { try handler.reply("Option B", for: identity) }
        #expect(sent.isEmpty)
    }
}
