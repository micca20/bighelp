import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesPromptStoreTests {
    @Test func approvalSurfacesAndAnswersOnlyTheOfferedScope() async throws {
        let identity = NSObject()
        let connection = scope(identity)
        let store = DirectHermesPromptStore()
        store.beginConnection(connection)
        defer { store.retireConnection(connection) }
        try store.bind(profile: "alpha", runtimeID: "runtime", visibleSessionID: "chat", connection: connection)
        let request = DirectHermesServerRequest(id: "outer-id", method: "approval", params: [
            "session_id": .string("runtime"), "request_id": .string("domain-id"),
            "command": .string("Run fixture checks"), "choices": .array([.string("once"), .string("deny")]),
        ])
        try store.setContract(.serverRequests, legacy: [], hostIdentity: "host", profile: "alpha",
                              runtimeID: "runtime", visibleSessionID: "chat")
        let task = Task { await store.handle(request, connection: connection) }
        for _ in 0..<100 where store.dashboardApprovals().isEmpty { await Task.yield() }
        let prompt = try #require(store.prompts(hostIdentity: "host", profile: "alpha", runtimeID: "runtime", visibleSessionID: "chat").first)
        #expect(prompt.wireID == "outer-id" && prompt.domainRequestID == "domain-id")
        #expect(prompt.approval?.choices == [.once, .deny])
        #expect(throws: DirectHermesWorkspaceError.self) { try store.answerApproval(prompt, decision: .always) }
        try store.answerApproval(prompt, decision: .once)
        #expect(await task.value == .result(.object(["choice": .string("once"), "all": .boolean(false)])))
        #expect(store.dashboardApprovals().isEmpty)
    }

    /// Hermes 0.21.5 sends `choices: null` for open questions; newer fields must not
    /// turn the card into an instant blank answer.
    @Test func clarificationWaitsForTheAnswerDespiteNullsAndUnknownFields() async throws {
        let identity = NSObject()
        let connection = scope(identity)
        let store = DirectHermesPromptStore()
        store.beginConnection(connection)
        defer { store.retireConnection(connection) }
        try store.bind(profile: "alpha", runtimeID: "runtime", visibleSessionID: "chat", connection: connection)
        try store.setContract(.serverRequests, legacy: [], hostIdentity: "host", profile: "alpha",
                              runtimeID: "runtime", visibleSessionID: "chat")
        let request = DirectHermesServerRequest(id: "ask", method: "clarify", params: [
            "session_id": .string("runtime"), "question": .string("Which city?"),
            "choices": .null, "multi_select": .null, "questions": .null, "timeout_s": .integer(300),
        ])
        let task = Task { await store.handle(request, connection: connection) }
        for _ in 0..<100 where store.prompts(hostIdentity: "host", profile: "alpha", runtimeID: "runtime",
                                             visibleSessionID: "chat").isEmpty { await Task.yield() }
        let prompt = try #require(store.prompts(hostIdentity: "host", profile: "alpha", runtimeID: "runtime",
                                                visibleSessionID: "chat").first)
        #expect(prompt.kind == .clarification)
        try store.answerClarification(prompt, answer: "Austin")
        #expect(await task.value == .result(.object(["answer": .string("Austin")])))
    }

    @Test func approvalWithAnUnknownChoiceStillAsks() async throws {
        let identity = NSObject()
        let connection = scope(identity)
        let store = DirectHermesPromptStore()
        store.beginConnection(connection)
        defer { store.retireConnection(connection) }
        try store.bind(profile: "alpha", runtimeID: "runtime", visibleSessionID: "chat", connection: connection)
        try store.setContract(.serverRequests, legacy: [], hostIdentity: "host", profile: "alpha",
                              runtimeID: "runtime", visibleSessionID: "chat")
        let request = DirectHermesServerRequest(id: "approve", method: "approval", params: [
            "session_id": .string("runtime"), "request_id": .string("domain"), "command": .string("rm -rf build"),
            "choices": .array([.string("once"), .string("future-choice"), .string("deny")]),
        ])
        let task = Task { await store.handle(request, connection: connection) }
        for _ in 0..<100 where store.dashboardApprovals().isEmpty { await Task.yield() }
        let prompt = try #require(store.prompts(hostIdentity: "host", profile: "alpha", runtimeID: "runtime",
                                                visibleSessionID: "chat").first)
        #expect(prompt.approval?.choices == [.once, .deny])
        try store.answerApproval(prompt, decision: .deny)
        #expect(await task.value == .result(.object(["choice": .string("deny"), "all": .boolean(false)])))
    }

    @Test func batchClarificationRetainsLockedAnswerAndRespondsOnce() async throws {
        let identity = NSObject()
        let connection = scope(identity)
        let store = DirectHermesPromptStore()
        store.beginConnection(connection)
        defer { store.retireConnection(connection) }
        try store.bind(profile: "alpha", runtimeID: "runtime", visibleSessionID: "chat", connection: connection)
        let request = DirectHermesServerRequest(id: "batch", method: "clarify", params: [
            "session_id": .string("runtime"), "questions": .array([
                .object(["qid": .string("a"), "question": .string("Channel?"), "choices": .array([.string("Internal")])]),
                .object(["qid": .string("b"), "question": .string("Notes?")]),
            ]), "answers": .object(["a": .string("Internal")]),
        ])
        try store.setContract(.serverRequests, legacy: [], hostIdentity: "host", profile: "alpha",
                              runtimeID: "runtime", visibleSessionID: "chat")
        let task = Task { await store.handle(request, connection: connection) }
        for _ in 0..<100 where store.dashboardClarifications().isEmpty { await Task.yield() }
        let prompt = try #require(store.prompts(hostIdentity: "host", profile: "alpha", runtimeID: "runtime", visibleSessionID: "chat").first)
        #expect(prompt.isBatch)
        #expect(prompt.clarification?.questions.first?.lockedAnswer == "Internal")
        #expect(throws: DirectHermesWorkspaceError.self) {
            try store.answerClarification(prompt, answers: ["a": "Changed", "b": "Ready"])
        }
        try store.answerClarification(prompt, answers: ["a": "Internal", "b": "Ready"])
        #expect(await task.value == .result(.object(["answers": .object(["a": .string("Internal"), "b": .string("Ready")])])))
        #expect(store.dashboardClarifications().isEmpty)
    }

    @Test func cancellationNeverApprovesAndLateAnswersAreRejected() async throws {
        let identity = NSObject()
        let connection = scope(identity)
        let store = DirectHermesPromptStore()
        store.beginConnection(connection)
        defer { store.retireConnection(connection) }
        try store.bind(profile: "alpha", runtimeID: "runtime", visibleSessionID: "chat", connection: connection)
        let request = DirectHermesServerRequest(id: "cancel", method: "clarify", params: ["session_id": .string("runtime"), "question": .string("Proceed?")])
        try store.setContract(.serverRequests, legacy: [], hostIdentity: "host", profile: "alpha",
                              runtimeID: "runtime", visibleSessionID: "chat")
        let task = Task { await store.handle(request, connection: connection) }
        for _ in 0..<100 where store.dashboardClarifications().isEmpty { await Task.yield() }
        let prompt = try #require(store.prompts(hostIdentity: "host", profile: "alpha", runtimeID: "runtime", visibleSessionID: "chat").first)
        store.acceptCancellation(.init(id: "cancel", method: "clarify", reason: "expired"), connection: connection)
        #expect(throws: DirectHermesWorkspaceError.self) { try store.answerClarification(prompt, answer: "Yes") }
        guard case .error = await task.value else { Issue.record("Cancelled request produced a result"); return }
        #expect(store.dashboardClarifications().isEmpty)
    }

    private func scope(_ identity: NSObject) -> DirectHermesPromptConnection {
        .init(owner: UUID(), principalIdentity: "host", clientIdentity: ObjectIdentifier(identity),
              transportGeneration: .init(UUID()))
    }
}
