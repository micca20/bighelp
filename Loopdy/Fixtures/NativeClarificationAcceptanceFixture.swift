#if DEBUG
import Foundation
import SwiftUI

/// Offline UI qualification of the real native chat and attention sheet.
/// No credentials, network, provider invocation, or production host state.
@MainActor
struct NativeClarificationAcceptanceFixtureView: View {
    @State private var fixture: NativeClarificationAcceptanceFixture?
    @State private var error: String?

    var body: some View {
        Group {
            if let fixture {
                VStack(spacing: 0) {
                    Text(fixture.rpc.receipt)
                        .font(.caption2)
                        .accessibilityIdentifier("native-clarify-fixture.receipt")
                    DirectHermesChatView(chat: fixture.chat, store: fixture.store)
                }
            } else if let error {
                Text(error).accessibilityIdentifier("native-clarify-fixture.error")
            } else {
                ProgressView("Preparing offline clarification")
            }
        }
        .task {
            guard fixture == nil else { return }
            do {
                let value = try NativeClarificationAcceptanceFixture(
                    batch: !ProcessInfo.processInfo.arguments.contains("-test-native-clarify-single")
                )
                try await value.chat.client.recover(epoch: "fixture-epoch")
                fixture = value
            } catch {
                self.error = "Offline clarification setup failed"
            }
        }
        .onDisappear { fixture?.close() }
    }
}

@MainActor
private final class NativeClarificationAcceptanceFixture {
    let root: URL
    let rpc: NativeClarificationAcceptanceRPC
    let chat: DirectHermesChat
    let store: DirectHermesWorkspaceStore

    init(batch: Bool) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "native-clarify-ui-" + UUID().uuidString)
        rpc = NativeClarificationAcceptanceRPC(batch: batch)
        let drafts = DirectHermesDraftStore(root: root)
        store = DirectHermesWorkspaceStore(vault: EmptyClarificationVault(), drafts: drafts)
        let client = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: "offline-clarification", profile: "fixture-profile",
            runtimeID: "fixture-runtime", storedID: "fixture-stored", title: "Clarification UI",
            epoch: "fixture-epoch", drafts: drafts
        )
        let model = ChatModel(conversationID: client.conversationID, client: client,
                              initialItems: [], initialDraft: "Preserve my independent composer draft")
        client.model = model
        chat = DirectHermesChat(id: client.conversationID, client: client, model: model)
    }

    func close() {
        chat.client.suspend()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Observable
private final class NativeClarificationAcceptanceRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var receipt = "No clarification submitted"
    private let batch: Bool
    private var answers: [(String, String)] = []
    private var ordinarySubmissions = 0

    init(batch: Bool) { self.batch = batch }

    func request(_ method: String, params: [String: LoopdyJSONValue]) async throws -> LoopdyJSONValue {
        guard params["session_id"]?.string == "fixture-runtime" else {
            throw DirectHermesError.identityChanged
        }
        switch method {
        case "session.events.since":
            return .object(["epoch": .string("fixture-epoch"), "latest_seq": .integer(0),
                            "truncated": .boolean(false), "events": .array([]), "count": .integer(0)])
        case "session.activate":
            return .object([
                "session_id": .string("fixture-runtime"), "stored_session_id": .string("fixture-stored"),
                "running": .boolean(false), "messages": .array([]),
                "pending_clarify": .object(prompt)
            ])
        case "session.control.read":
            return .object(["control": .object(["goal": .null, "loop": .null, "heartbeat": .null,
                                                "revision": .string("fixture"), "updated_at": .integer(0)])])
        case "subagent.list": return .object(["subagents": .array([])])
        case "clarify.respond":
            guard params["request_id"]?.string == "c1a21f00",
                  params["profile"]?.string == "fixture-profile",
                  let answer = params["answer"]?.string, !answer.isEmpty else {
                throw DirectHermesError.invalidResponse
            }
            let questionID = batch ? params["question_id"]?.string : "q0"
            guard questionID == "q\(answers.count)", answers.count < (batch ? 2 : 1) else {
                throw DirectHermesError.invalidResponse
            }
            answers.append((questionID!, answer))
            let remaining = (answers.count..<(batch ? 2 : 1)).map { LoopdyJSONValue.string("q\($0)") }
            receipt = answers.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
                + "; submissions=\(ordinarySubmissions)"
            return .object(["status": .string("ok"), "remaining": .array(remaining)])
        case "prompt.submit":
            ordinarySubmissions += 1
            receipt = "Unexpected ordinary submission: \(ordinarySubmissions)"
            throw DirectHermesError.invalidResponse
        default: throw DirectHermesError.invalidResponse
        }
    }

    private var prompt: [String: LoopdyJSONValue] {
        let question = "Which release channel should receive this build after the remaining checks have passed?"
        let choices: LoopdyJSONValue = .array([.string("TestFlight"), .string("App Store"), .string("Hold release")])
        if !batch {
            return ["request_id": .string("c1a21f00"), "question": .string(question), "choices": choices]
        }
        return ["request_id": .string("c1a21f00"), "questions": .array([
            .object(["qid": .string("q0"), "question": .string(question), "choices": choices]),
            .object(["qid": .string("q1"), "question": .string("What should the release notes say?"), "choices": .null])
        ])]
    }

    func disconnect() async {}
}

@MainActor
private final class EmptyClarificationVault: DirectHermesCredentialVault {
    func load() throws -> DirectHermesSavedConnection? { nil }
    func save(_ connection: DirectHermesSavedConnection) throws { throw DirectHermesError.invalidResponse }
    func delete() throws {}
}
#endif
