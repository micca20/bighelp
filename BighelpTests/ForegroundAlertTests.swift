import BuzzKit
import Foundation
import Testing
@testable import Bighelp

/// Nothing for the chat you're looking at. Alerts for the open chat used to
/// show anyway: an alert without its chat reference couldn't be matched.
@MainActor
@Suite(.serialized)
struct ForegroundAlertTests {
    private final class QuietRPC: DirectHermesRPC {
        var onEvent: ((DirectHermesEvent) -> Void)?
        func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            throw DirectHermesError.invalidResponse
        }
        func disconnect() async {}
    }

    @MainActor private struct OpenChat {
        let model: ChatModel
        let client: DirectHermesConversationClient
        let root: URL

        func close() {
            BighelpVisibleChats.shared.disappeared(model)
            client.suspend()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func open(profile: String, stored: String) throws -> OpenChat {
        let root = FileManager.default.temporaryDirectory.appending(path: "foreground-alerts-" + UUID().uuidString)
        let client = try DirectHermesConversationClient(
            rpc: QuietRPC(), hostIdentity: "fixture-host", profile: profile, runtimeID: "runtime-" + stored,
            storedID: stored, title: "Chat", epoch: "epoch", drafts: .init(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client)
        BighelpVisibleChats.shared.appeared(model)
        return OpenChat(model: model, client: client, root: root)
    }

    @Test func theOpenChatsAlertsAreQuietAndOtherChatsStillShow() throws {
        let chat = try open(profile: "default", stored: "saved-a")
        defer { chat.close() }
        let open = ManagedNotificationValidation.sessionReference(profile: "default", session: "saved-a")
        let other = ManagedNotificationValidation.sessionReference(profile: "default", session: "saved-b")
        #expect(BighelpVisibleChats.shared.isShowing(chat: open, agent: "default"))
        #expect(!BighelpVisibleChats.shared.isShowing(chat: other, agent: "default"), "Another chat's reply still shows")
    }

    @Test func anAlertWithoutAChatIsQuietWhileItsAgentsChatIsBusy() throws {
        let chat = try open(profile: "default", stored: "saved-c")
        defer { chat.close() }
        let now = Date()
        #expect(!BighelpVisibleChats.shared.isShowing(chat: nil, agent: "default", now: now), "An idle chat claims nothing")

        chat.model.isSending = true
        #expect(BighelpVisibleChats.shared.isShowing(chat: nil, agent: "default", now: now))
        #expect(!BighelpVisibleChats.shared.isShowing(chat: nil, agent: "someone-else", now: now))

        chat.model.isSending = false
        #expect(BighelpVisibleChats.shared.isShowing(chat: nil, agent: "default", now: Date()), "The reply that just finished")
        #expect(!BighelpVisibleChats.shared.isShowing(
            chat: nil, agent: "default", now: Date().addingTimeInterval(BighelpVisibleChats.recentTurnWindow + 1)))
    }

    @Test func aClosedChatIsntOnScreen() throws {
        let chat = try open(profile: "default", stored: "saved-d")
        chat.close()
        let reference = ManagedNotificationValidation.sessionReference(profile: "default", session: "saved-d")
        #expect(!BighelpVisibleChats.shared.isShowing(chat: reference, agent: "default"))
    }

    @Test func theAgentComesFromSealedOrRichPushData() {
        let sealed: [String: JSONValue] = ["loopdy": .object(["agent": .object(["id": .string("default")])])]
        let rich: [String: JSONValue] = ["loopdy": .object(["profile": .string("juno")])]
        #expect(BighelpBuzzKitPresentation.agent(sealed) == "default")
        #expect(BighelpBuzzKitPresentation.agent(rich) == "juno")
        #expect(BighelpNotificationGrouping.agent(of: ["loopdy": ["agent": ["id": "default"]]]) == "default")
    }
}
