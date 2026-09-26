import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesGoalControlTests {
    @Test func actualGoalAliasesDoNotInventDelete() {
        #expect(DirectHermesGoalControlProjection.argument(from: "/goal Build a feature") == "Build a feature")
        #expect(DirectHermesGoalControlProjection.controlAction(for: "pause") == .goalPause)
        #expect(DirectHermesGoalControlProjection.controlAction(for: "resume") == .goalResume)
        for alias in ["clear", "stop", "done"] {
            #expect(DirectHermesGoalControlProjection.controlAction(for: alias) == .goalClear)
        }
        #expect(DirectHermesGoalControlProjection.controlAction(for: "delete") == nil)
    }

    @Test func activePausedAndNullSnapshotsHaveCorrectRailState() throws {
        let active = try snapshot("active", revision: "a")
        #expect(try DirectHermesGoalControlProjection.railState(from: active)?.lifecycle == .active)
        let paused = try snapshot("paused", revision: "b")
        #expect(try DirectHermesGoalControlProjection.railState(from: paused)?.lifecycle == .paused)
        let clear = try snapshot(nil, revision: "c")
        #expect(try DirectHermesGoalControlProjection.railState(from: clear) == nil)
        let retained = try DirectHermesGoalControlProjection.retainedSnapshot(from: clear,
            visibleSessionID: "visible", storedSessionID: "saved", observedAt: 1)
        #expect(retained.status == .none)
        #expect(retained.summary == nil)
        #expect(throws: (any Error).self) {
            try DirectHermesGoalControlProjection.railState(from: snapshot("unexpected", revision: "d"))
        }
    }

    @Test func liveControlUpdatesReachModelAndPersistClearWithoutEndingChat() async throws {
        let fixture = try GoalFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        var saved: [SessionGoalSnapshot] = []
        let model = ChatModel(conversationID: fixture.client.conversationID, client: fixture.client,
            onGoalSnapshotChange: { saved.append($0) })
        fixture.client.model = model
        fixture.event("active", revision: "a", sequence: 1)
        #expect(model.sessionGoal?.status == .active)
        fixture.event("paused", revision: "b", sequence: 2)
        #expect(model.sessionGoal?.status == .paused)
        fixture.client.receive(.init(type: "message.complete", sessionID: "runtime", payload: ["text": .string("A segment")], sequence: 3))
        #expect(model.sessionGoal?.status == .paused)
        fixture.event(nil, revision: "c", sequence: 4)
        #expect(model.sessionGoal?.status == SessionGoalSnapshot.Status.none)
        #expect(saved.map(\.status) == [.active, .paused, .none])
        #expect(fixture.rpc.calls.allSatisfy { !$0.method.contains("delete") })
    }

    @Test func eventBeforeModelAttachmentIsAdopted() async throws {
        let fixture = try GoalFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.event("paused", revision: "a", sequence: 1)
        let model = ChatModel(conversationID: fixture.client.conversationID, client: fixture.client)
        fixture.client.model = model
        #expect(model.sessionGoal?.status == .paused)
    }

    @Test func resumeSubmitsExactHostContinuationOnce() async throws {
        let fixture = try GoalFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.rpc.calls.removeAll()
        let result = try await fixture.client.sessionActions.applyControl(.goalResume)
        #expect(result.continuation == .accepted)
        #expect(fixture.rpc.calls.map(\.method) == ["session.control", "prompt.submit"])
        #expect(fixture.rpc.calls.last?.params["text"] == .string(GoalRPC.continuation))
        #expect(fixture.rpc.calls.first?.params["action"] == .string("goal.resume"))
    }

    @Test func lostResumeAcknowledgementDoesNotReplay() async throws {
        let fixture = try GoalFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.rpc.calls.removeAll()
        fixture.rpc.loseSubmit = true
        let result = try await fixture.client.sessionActions.applyControl(.goalResume)
        #expect(result.continuation == .outcomeUnknown)
        #expect(fixture.rpc.calls.map(\.method) == ["session.control", "prompt.submit"])
    }

    @Test func lateReadCannotResurrectClearedGoal() async throws {
        let fixture = try GoalFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        let model = ChatModel(conversationID: fixture.client.conversationID, client: fixture.client)
        fixture.client.model = model
        await model.refreshNativeGoalControl()
        await Task.yield()
        fixture.event("active", revision: "a", sequence: 1)
        fixture.rpc.control = goalObject("active", revision: "a")
        var release: CheckedContinuation<Void, Never>?
        fixture.rpc.beforeReadReturn = { await withCheckedContinuation { release = $0 } }
        let read = Task { await model.refreshNativeGoalControl() }
        for _ in 0..<100 where release == nil { await Task.yield() }
        guard let release else {
            read.cancel()
            Issue.record("Read did not reach held response")
            return
        }
        fixture.event(nil, revision: "b", sequence: 2)
        release.resume()
        await read.value
        #expect(model.sessionGoal?.status == SessionGoalSnapshot.Status.none)
    }

    private func snapshot(_ status: String?, revision: String) throws -> DirectHermesSessionControlSnapshot {
        try .init(object: goalObject(status, revision: revision))
    }
}

private func goalObject(_ status: String?, revision: String) -> [String: BighelpJSONValue] {
    ["goal": status.map { .object(["title": .string("Build a useful feature"), "status": .string($0)]) } ?? .null,
     "loop": .null, "heartbeat": .null, "revision": .string(revision), "updated_at": .integer(1_800_000_000)]
}

@MainActor private final class GoalFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let rpc = GoalRPC()
    let client: DirectHermesConversationClient
    init() throws {
        client = try .init(rpc: rpc, hostIdentity: "host", profile: "default", runtimeID: "runtime",
            storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
    }
    func event(_ status: String?, revision: String, sequence: Int) {
        client.receive(.init(type: "session.control.update", sessionID: "runtime",
            payload: ["control": .object(goalObject(status, revision: revision))], sequence: sequence))
    }
    func close() { client.suspend(); try? FileManager.default.removeItem(at: root) }
}

@MainActor private final class GoalRPC: DirectHermesRPC {
    static let continuation = "Continue the exact host-authored goal.\nPreserve this second line."
    var onEvent: ((DirectHermesEvent) -> Void)?
    var calls: [(method: String, params: [String: BighelpJSONValue])] = []
    var control = goalObject(nil, revision: "initial")
    var loseSubmit = false
    var beforeReadReturn: (@MainActor () async -> Void)?
    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        calls.append((method, params))
        switch method {
        case "session.events.since":
            return .object(["epoch": .string("epoch"), "latest_seq": .integer(0), "truncated": .boolean(false), "events": .array([]), "count": .integer(0)])
        case "session.activate": return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"), "running": .boolean(false), "messages": .array([])])
        case "subagent.list": return .object(["subagents": .array([])])
        case "session.control.read":
            let observed = control
            await beforeReadReturn?()
            return .object(["control": .object(observed)])
        case "session.control":
            let resume = params["action"] == .string("goal.resume")
            return .object(["control": .object(goalObject(resume ? "active" : nil, revision: "action")),
                "dispatch": .object(["type": .string(resume ? "send" : "message"), "output": .null, "notice": .null,
                    "message": resume ? .string(Self.continuation) : .null, "display": .string("/goal resume")])])
        case "prompt.submit":
            if loseSubmit { throw DirectHermesError.timedOut(outcomeUnknown: true) }
            return .object(["status": .string("queued")])
        default: throw DirectHermesError.invalidResponse
        }
    }
    func disconnect() async {}
}
