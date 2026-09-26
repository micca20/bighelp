import Foundation
import Testing
@testable import Loopdy

@MainActor
struct AttachmentCapabilityTests {
    @Test func anAttachmentWithoutCaptionCanBeSent() async throws {
        let client = ConversationFixtureClient()
        let model = ChatModel(conversationID: "attachment-only", client: client, initialItems: [])
        let file = try attachment()
        try model.addDraftAttachment(file)
        #expect(model.draft.isEmpty)
        #expect(model.canSend, "A selected file is message content even without a caption")
        await model.send()
        #expect(client.receivedAttachments == [file])
        #expect(model.items.first?.attachments == [file])
        #expect(model.draftAttachments.isEmpty)
    }

    @Test func attachmentPayloadChoosesSendInIdleAndActiveComposers() {
        #expect(ChatComposerPrimaryAction.resolve(draft: "", hasAttachments: true) == .send)
        #expect(ChatComposerPrimaryAction.resolve(draft: "", isTurnActive: true, hasAttachments: true) == .send)
        #expect(ChatComposerPrimaryAction.resolve(draft: "", isTurnActive: true, hasAttachments: false) == .stop)
    }

    @Test func retainedAttachmentCannotEnableSendForTextOnlyReplacement() throws {
        let model = ChatModel(conversationID: "capability-change", client: ConversationFixtureClient(),
                              agentID: "default", initialItems: [], initialDraft: "Caption")
        let file = try attachment()
        try model.addDraftAttachment(file)
        model.reassignDirectAgent(to: "other", client: TextOnlyClient(), runtimeControls: nil, slashCommandCatalog: nil)
        #expect(!model.canSend)
        #expect(model.draftAttachments == [file])
        #expect(model.draft == "Caption")
    }

    @Test func nonconformingClientDoesNotAdvertiseOrAcceptAttachments() throws {
        let client = TextOnlyClient()
        let model = ChatModel(conversationID: "unsupported-attachments", client: client, initialItems: [])
        #expect(model.supportedAttachmentKinds.isEmpty)
        #expect(throws: ChatAttachmentError.unsupportedClient) {
            try model.addDraftAttachment(attachment())
        }
        #expect(model.draftAttachments.isEmpty)
        #expect(client.textCalls == 0)
    }

    @Test(arguments: [false, true])
    func retainedFilesCannotFallThroughToTextOnlyAfterClientReplacement(streaming: Bool) async throws {
        let initial = ConversationFixtureClient()
        let client = streaming ? StreamingTextOnlyClient() : TextOnlyClient()
        let model = ChatModel(conversationID: "attachment-owner-change", client: initial,
                              agentID: "default", initialItems: [], initialDraft: "Keep my caption")
        let file = try attachment()
        try model.addDraftAttachment(file)
        model.reassignDirectAgent(to: "other", client: client, runtimeControls: nil, slashCommandCatalog: nil)
        #expect(model.supportedAttachmentKinds.isEmpty)
        await model.send()
        #expect(client.textCalls == 0)
        #expect((client as? StreamingTextOnlyClient)?.streamCalls ?? 0 == 0)
        #expect(model.draft == "Keep my caption")
        #expect(model.draftAttachments == [file])
        #expect(model.items.isEmpty)
        #expect(model.failureMessage == ChatAttachmentError.unsupportedClient.localizedDescription)
    }

    @Test func textOnlyClientsStillSendOrdinaryText() async {
        let client = TextOnlyClient()
        let model = ChatModel(conversationID: "ordinary-text", client: client, initialItems: [], initialDraft: "Hello")
        await model.send()
        #expect(client.textCalls == 1)
    }

    @Test func fixtureDeclaresAndRecordsAttachments() async throws {
        let client = ConversationFixtureClient()
        let model = ChatModel(conversationID: "fixture-attachment", client: client, initialItems: [], initialDraft: "Caption")
        let file = try attachment()
        try model.addDraftAttachment(file)
        await model.send()
        #expect(client.receivedAttachments == [file])
        #expect(model.items.first?.attachments == [file])
    }

    private func attachment() throws -> ChatAttachment {
        try ChatAttachment(id: "attachment_capability_fixture", fileName: "context.txt",
                           mimeType: "text/plain", data: Data("context".utf8))
    }

    @MainActor
    private class TextOnlyClient: ConversationClient {
        var textCalls = 0
        func send(message: String, conversationID: String) async throws -> ConversationResponse {
            textCalls += 1
            return ConversationResponse(items: [])
        }
        func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
    }

    @MainActor
    private final class StreamingTextOnlyClient: TextOnlyClient, StreamingConversationClient {
        var streamCalls = 0
        func send(message: String, conversationID: String,
                  onDraft: @escaping (TimelineItem) -> Void) async throws -> ConversationResponse {
            streamCalls += 1
            return ConversationResponse(items: [])
        }
    }
}
