import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesLegacyPromptTests {
    @Test func spinnerPhrasesReplaceTransientLabelWithoutCreatingReasoningCards() async throws {
        let fixture = try LegacyPromptFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        fixture.client.receive(.init(type: "thinking.delta", sessionID: "runtime", payload: ["text": .string("(⌁) measuring burn...")], sequence: 2))
        #expect(fixture.client.spinnerActivityText == "(⌁) measuring burn...")
        fixture.client.receive(.init(type: "thinking.delta", sessionID: "runtime", payload: ["text": .string("Checking the next step…")], sequence: 3))
        #expect(fixture.client.spinnerActivityText == "Checking the next step…")
        #expect(fixture.client.projection.activities.filter { $0.kind == .reasoning }.isEmpty)
        fixture.client.receive(.init(type: "reasoning.delta", sessionID: "runtime", payload: ["text": .string("I need to evaluate the request.")], sequence: 4))
        #expect(fixture.client.projection.activities.filter { $0.kind == .reasoning }.count == 1)
        fixture.client.receive(.init(type: "message.complete", sessionID: "runtime", payload: ["text": .string("Finished segment.")], sequence: 5))
        // Stock message.complete closes a segment, not the parent turn.
        #expect(fixture.client.spinnerActivityText == "Checking the next step…")
        fixture.client.receive(.init(type: "session.info", sessionID: "runtime", payload: ["running": .boolean(false)], sequence: 6))
        #expect(fixture.client.spinnerActivityText == nil)
        fixture.client.receive(.init(type: "thinking.delta", sessionID: "another-runtime", payload: ["text": .string("Other chat")], sequence: 7))
        #expect(fixture.client.spinnerActivityText == nil)
        fixture.client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 7))
        #expect(fixture.client.spinnerActivityText == nil)
        fixture.client.receive(.init(type: "thinking.delta", sessionID: "runtime", payload: ["text": .string("New turn")], sequence: 8))
        #expect(fixture.client.spinnerActivityText == "New turn")
        fixture.client.suspend()
        #expect(fixture.client.spinnerActivityText == nil)
    }

    @Test func everySingleChoiceSubmitsItsExactValueAndPreservesComposerDraft() async throws {
        for choice in ["First", "Second", "Third"] {
            let fixture = try LegacyPromptFixture()
            defer { fixture.close() }
            fixture.rpc.snapshot["pending_clarify"] = .object([
                "request_id": .string("choice-test"), "question": .string("Choose a distinct answer"),
                "choices": .array([.string("First"), .string("Second"), .string("Third")])
            ])
            try await fixture.client.recover(epoch: "epoch")
            fixture.client.saveDraft("Unsent composer text")
            let prompt = try #require(fixture.client.prompts.first)
            #expect(prompt.clarification?.questions.first?.question == "Choose a distinct answer")
            try await fixture.client.respond(to: prompt, value: choice)
            #expect(fixture.rpc.mutations.count == 1)
            #expect(fixture.rpc.mutations.first?.method == "clarify.respond")
            #expect(fixture.rpc.mutations.first?.params["answer"] == .string(choice))
            #expect(fixture.client.journal.draft == "Unsent composer text")
        }
    }

    @Test func openEndedStockQuestionAcceptsNullChoices() async throws {
        let fixture = try LegacyPromptFixture()
        defer { fixture.close() }
        fixture.rpc.snapshot["pending_clarify"] = .object([
            "request_id": .string("open-question"), "question": .string("What should change?"), "choices": .null])
        try await fixture.client.recover(epoch: "epoch")
        let prompt = try #require(fixture.client.prompts.first)
        #expect(prompt.clarification?.questions.first?.choices == [])
        try await fixture.client.respond(to: prompt, value: "My custom answer")
        #expect(fixture.rpc.mutations.first?.params["answer"] == .string("My custom answer"))
    }

    @Test func stockSnapshotRestoresApprovalAndRespondsOnlyThroughLegacyRPC() async throws {
        let fixture = try LegacyPromptFixture()
        defer { fixture.close() }
        fixture.rpc.snapshot["pending_approval"] = .object(approval("approval-id"))
        try await fixture.client.recover(epoch: "epoch")
        let prompt = try #require(fixture.client.prompts.first)
        #expect(prompt.kind == .approval)
        #expect(prompt.approval?.choices == [.once, .deny])
        await #expect(throws: (any Error).self) {
            try await fixture.client.respond(to: prompt, decision: .always)
        }
        #expect(fixture.rpc.mutations.isEmpty)
        try await fixture.client.respond(to: prompt, decision: .once)
        let mutation = try #require(fixture.rpc.mutations.first)
        #expect(mutation.method == "approval.respond")
        #expect(mutation.params["request_id"] == .string("approval-id"))
        #expect(mutation.params["choice"] == .string("once"))
        #expect(mutation.params["all"] == .boolean(false))
        #expect(mutation.params["session_id"] == .string("runtime"))
        #expect(fixture.client.prompts.isEmpty)
    }

    @Test func stockLiveClarifyIsSessionScopedAndExpiresByExactID() async throws {
        let fixture = try LegacyPromptFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.client.receive(.init(type: "clarify.request", sessionID: "other", payload: question("wrong"), sequence: nil))
        #expect(fixture.client.prompts.isEmpty)
        fixture.client.receive(.init(type: "clarify.request", sessionID: "runtime", payload: question("question-id"), sequence: nil))
        #expect(fixture.client.prompts.count == 1)
        fixture.client.receive(.init(type: "clarify.expire", sessionID: "runtime", payload: ["request_id": .string("other")], sequence: nil))
        #expect(fixture.client.prompts.count == 1)
        fixture.client.receive(.init(type: "clarify.expire", sessionID: "runtime", payload: ["request_id": .string("question-id")], sequence: nil))
        #expect(fixture.client.prompts.isEmpty)
        #expect(fixture.rpc.mutations.isEmpty)
    }

    @Test func stockBatchRestoresLockedAnswersAndSendsOnlyUnansweredQuestions() async throws {
        let fixture = try LegacyPromptFixture()
        defer { fixture.close() }
        fixture.rpc.snapshot["pending_clarify"] = .object([
            "request_id": .string("batch-id"), "questions": .array([
                .object(["qid": .string("first"), "question": .string("Channel?"), "choices": .array([.string("Internal")])]),
                .object(["qid": .string("second"), "question": .string("Notes?"), "choices": .array([])])
            ]), "answers": .object(["first": .string("Internal")])
        ])
        try await fixture.client.recover(epoch: "epoch")
        let prompt = try #require(fixture.client.prompts.first)
        #expect(prompt.clarification?.questions.first?.lockedAnswer == "Internal")
        try await fixture.client.respond(to: prompt, answers: ["first": "Internal", "second": "Ready"])
        #expect(fixture.rpc.mutations.count == 1)
        let mutation = try #require(fixture.rpc.mutations.first)
        #expect(mutation.method == "clarify.respond")
        #expect(mutation.params["request_id"] == .string("batch-id"))
        #expect(mutation.params["question_id"] == .string("second"))
        #expect(mutation.params["answer"] == .string("Ready"))
        #expect(fixture.client.prompts.isEmpty)
    }

    @Test func stockCancelAndConfirmedStopClearOnlyConfirmedPrompts() async throws {
        let fixture = try LegacyPromptFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.client.receive(.init(type: "clarify.request", sessionID: "runtime", payload: question("cancel-id"), sequence: nil))
        try await fixture.client.cancel(#require(fixture.client.prompts.first))
        let cancel = try #require(fixture.rpc.mutations.first)
        #expect(cancel.method == "clarify.respond")
        #expect(cancel.params["answer"] == .string(""))
        #expect(cancel.params["question_id"] == nil)
        #expect(fixture.client.prompts.isEmpty)
        fixture.client.receive(.init(type: "approval.request", sessionID: "runtime", payload: approval("stop-id"), sequence: nil))
        try await fixture.client.stop(conversationID: fixture.client.conversationID)
        #expect(fixture.client.prompts.isEmpty)
        #expect(fixture.rpc.mutations.last?.method == "session.interrupt")
    }

    @Test func modernReplayDoesNotDuplicateLegacyCompatibilityPrompts() async throws {
        let fixture = try LegacyPromptFixture()
        defer { fixture.close() }
        fixture.rpc.openRequests = .array([])
        fixture.rpc.snapshot["pending_clarify"] = .object(question("compatibility-id"))
        try await fixture.client.recover(epoch: "epoch")
        fixture.client.receive(.init(type: "clarify.request", sessionID: "runtime", payload: question("compatibility-id"), sequence: nil))
        #expect(fixture.client.prompts.isEmpty)
        #expect(fixture.rpc.mutations.isEmpty)
    }

    @Test func suspensionRevokesLegacyPromptAuthority() async throws {
        let fixture = try LegacyPromptFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.client.receive(.init(type: "clarify.request", sessionID: "runtime", payload: question("old-id"), sequence: nil))
        let prompt = try #require(fixture.client.prompts.first)
        fixture.client.suspend()
        #expect(fixture.client.prompts.isEmpty)
        await #expect(throws: (any Error).self) { try await fixture.client.respond(to: prompt, value: "Old answer") }
        #expect(fixture.rpc.mutations.isEmpty)
    }

    @Test func unknownAnswerIsNotAutomaticallyResentOrConvertedToChat() async throws {
        let fixture = try LegacyPromptFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.client.receive(.init(type: "clarify.request", sessionID: "runtime", payload: question("uncertain-id"), sequence: nil))
        let prompt = try #require(fixture.client.prompts.first)
        fixture.rpc.failMutation = true
        await #expect(throws: (any Error).self) { try await fixture.client.respond(to: prompt, value: "Answer") }
        #expect(fixture.rpc.mutations.count == 1)
        #expect(fixture.rpc.mutations.first?.method == "clarify.respond")
        #expect(!fixture.rpc.mutations.contains { $0.method == "prompt.submit" })
    }

    @Test func overlappingAnswersSendOnlyOneLegacyMutation() async throws {
        let fixture = try LegacyPromptFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.client.receive(.init(type: "clarify.request", sessionID: "runtime", payload: question("held-id"), sequence: nil))
        let prompt = try #require(fixture.client.prompts.first)
        var release: CheckedContinuation<Void, Never>?
        fixture.rpc.beforeMutationResult = { await withCheckedContinuation { release = $0 } }
        let first = Task { try await fixture.client.respond(to: prompt, value: "First") }
        for _ in 0..<100 where release == nil { await Task.yield() }
        guard let continuation = release else {
            first.cancel()
            Issue.record("The first mutation did not reach the held response")
            return
        }
        await #expect(throws: (any Error).self) { try await fixture.client.respond(to: prompt, value: "Second") }
        #expect(fixture.rpc.mutations.count == 1)
        continuation.resume()
        try await first.value
        #expect(fixture.client.prompts.isEmpty)
    }

    private func approval(_ id: String) -> [String: BighelpJSONValue] {
        ["request_id": .string(id), "command": .string("Run fixture checks"),
         "choices": .array([.string("once"), .string("deny")])]
    }

    private func question(_ id: String) -> [String: BighelpJSONValue] {
        ["request_id": .string(id), "question": .string("Continue?"), "choices": .array([])]
    }
}

@MainActor
private final class LegacyPromptFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let rpc = LegacyPromptRPC()
    let client: DirectHermesConversationClient

    init() throws {
        client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
    }

    func close() {
        client.suspend()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class LegacyPromptRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var openRequests: BighelpJSONValue?
    var snapshot: [String: BighelpJSONValue] = ["session_id": .string("runtime"),
        "stored_session_id": .string("saved"), "running": .boolean(false), "messages": .array([])]
    var mutations: [(method: String, params: [String: BighelpJSONValue])] = []
    var failMutation = false
    var beforeMutationResult: (@MainActor () async -> Void)?

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        if method == "session.events.since" {
            var replay: [String: BighelpJSONValue] = ["epoch": .string("epoch"), "latest_seq": .integer(0),
                "truncated": .boolean(false), "events": .array([]), "count": .integer(0)]
            replay["open_requests"] = openRequests
            return .object(replay)
        }
        if method == "session.activate" { return .object(snapshot) }
        if method == "subagent.list" { return .object(["subagents": .array([])]) }
        mutations.append((method, params))
        await beforeMutationResult?()
        if failMutation { throw DirectHermesError.timedOut(outcomeUnknown: true) }
        switch method {
        case "approval.respond": return .object(["resolved": .integer(1)])
        case "clarify.respond": return .object(["status": .string("ok"), "remaining": .array([])])
        case "session.interrupt": return .object(["status": .string("interrupted")])
        default: throw DirectHermesError.invalidResponse
        }
    }
    func disconnect() async {}
}
