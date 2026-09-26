import AppIntents
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Bighelp

struct BighelpAppIntentContractTests {
    /// Waiting for a reply must never require opening bighelp.
    @Test func chatIntentRunsInTheBackgroundWithoutOpeningTheApp() {
        #expect(SendLoopdyChatIntent.openAppWhenRun == false)
        if #available(iOS 26.0, *) {
            #expect(SendLoopdyChatIntent.supportedModes == [.background])
        }
    }

    @Test func shortcutEntitiesKeepStableHermesCoordinatesAndReasoningMappings() {
        let agent = LoopdyShortcutAgentEntity(
            BighelpShortcutAgent(
                id: "finance",
                name: "Finley",
                role: "Finance",
                isDefault: false
            )
        )
        let model = LoopdyShortcutModelEntity(
            BighelpShortcutModel(
                providerID: "openai",
                providerName: "OpenAI",
                modelID: "gpt-5.6"
            )
        )

        #expect(agent.id == "finance")
        #expect(agent.domain.id == "finance")
        #expect(model.id == "openai:gpt-5.6")
        #expect(model.domain.providerID == "openai")
        #expect(model.domain.modelID == "gpt-5.6")
        #expect(LoopdyShortcutReasoning.automatic.domain == .automatic)
        #expect(LoopdyShortcutReasoning.high.domain == .high)
        #expect(LoopdyShortcutReasoning.ultra.domain == .ultra)
    }

    @Test func intentFilesBecomeValidatedChatAttachmentsWithImageAndFileKinds() throws {
        let image = IntentFile(
            data: Data(repeating: 1, count: 128),
            filename: "reference.png",
            type: .png
        )
        let file = IntentFile(
            data: Data("notes".utf8),
            filename: "notes.txt",
            type: .plainText
        )

        let attachments = try BighelpShortcutAttachmentBuilder.make(
            images: [image],
            files: [file]
        )

        #expect(attachments.count == 2)
        #expect(attachments.map(\.fileName) == ["reference.png", "notes.txt"])
        #expect(attachments.map(\.kind) == [.image, .file])
        #expect(Set(attachments.map(\.id)).count == 2)
    }
}
