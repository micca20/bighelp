import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ScheduledTaskIdentityTests {
    @Test func bothProfilesRemainVisibleWithoutRenamingRemoteIDs() async {
        let client = CollisionScheduleClient()
        let store = ScheduledTasksStore(client: client, initialAgentID: nil)
        await store.load()
        #expect(store.loadState == .loaded)
        #expect(store.visibleTasks.count == 2)
        #expect(store.visibleTasks.allSatisfy { $0.id == "shared-job" })
        #expect(Set(store.visibleTasks.map(\.identity)).count == 2)
        #expect(store.task(id: "shared-job") == nil)
        #expect(store.task(id: "shared-job", agentID: "research")?.name == "Research")
        #expect(store.task(id: "shared-job", agentID: "writing")?.name == "Writing")
    }

    @Test func legacyAmbiguityIsExplicitAndNeverMutatesEitherProfile() async {
        let client = CollisionScheduleClient()
        let store = ScheduledTasksStore(client: client, initialAgentID: nil)
        await store.load()
        await #expect(throws: ScheduledTasksError.ambiguousTask) { try await store.runNow(id: "shared-job") }
        await #expect(throws: ScheduledTasksError.ambiguousTask) { try await store.delete(id: "shared-job") }
        #expect(store.taskLookupMessage(id: "shared-job").contains("More than one profile"))
        #expect(client.mutations.isEmpty)
    }

    @Test func scopedDeletionDoesNotRemoveTheOtherProfilesSameID() async throws {
        let client = CollisionScheduleClient()
        let store = ScheduledTasksStore(client: client, initialAgentID: nil)
        await store.load()
        try await store.delete(id: "shared-job", agentID: "research")
        #expect(store.tasks.map(\.agentID) == ["writing"])
        #expect(store.tasks.first?.id == "shared-job")
        #expect(client.mutations == [.init(profileID: "research", jobID: "shared-job")])
    }

    @Test func scopedUpdateAndRunReplaceOnlyTheirExactProfile() async throws {
        let client = CollisionScheduleClient()
        let store = ScheduledTasksStore(client: client, initialAgentID: nil)
        await store.load()
        try await store.update(id: "shared-job", name: "Updated writing", instructions: "New instruction",
            schedule: .dailyFixture, deliveryTarget: "local", agentID: "writing")
        #expect(store.task(id: "shared-job", agentID: "research")?.name == "Research")
        #expect(store.task(id: "shared-job", agentID: "writing")?.name == "Updated writing")
        try await store.runNow(id: "shared-job", agentID: "research")
        #expect(store.task(id: "shared-job", agentID: "research")?.lastResult == "Synthetic run")
        #expect(store.task(id: "shared-job", agentID: "writing")?.lastResult == nil)
    }

    @Test func pendingMutationsAreIndependentForCollidingIDs() async throws {
        let client = CollisionScheduleClient()
        client.suspendPauses = true
        let store = ScheduledTasksStore(client: client, initialAgentID: nil)
        await store.load()
        let research = Task { try await store.setPaused(true, id: "shared-job", agentID: "research") }
        let writing = Task { try await store.setPaused(true, id: "shared-job", agentID: "writing") }
        defer { research.cancel(); writing.cancel(); client.cancelPending() }
        for _ in 0..<100 where client.continuations.count < 2 { await Task.yield() }
        #expect(client.continuations.count == 2)
        #expect(store.pendingTaskIdentities.count == 2)
        #expect(store.isPending("shared-job", agentID: "research"))
        #expect(store.isPending("shared-job", agentID: "writing"))
        try client.finishPause(profile: "research")
        try await research.value
        #expect(!store.isPending("shared-job", agentID: "research"))
        #expect(store.isPending("shared-job", agentID: "writing"))
        #expect(store.task(id: "shared-job", agentID: "writing")?.status == .active)
        try client.finishPause(profile: "writing")
        try await writing.value
        #expect(store.pendingTaskIdentities.isEmpty)
        #expect(store.tasks.allSatisfy { $0.isPaused })
    }

    @Test func identityFramingIsByteExactAndNotAConcatenationAlias() {
        let first = ScheduledTaskIdentity(profileID: "a:b", jobID: "c")
        let second = ScheduledTaskIdentity(profileID: "a", jobID: "b:c")
        #expect(first != second)
        #expect(first.accessibilitySuffix != second.accessibilitySuffix)
        #expect(ScheduledTaskIdentity(profileID: "p", jobID: "caf\u{00E9}") !=
            ScheduledTaskIdentity(profileID: "p", jobID: "cafe\u{0301}"))
    }

    @Test func duplicateExactProfileIdentityIsNotAcceptedAsTwoRows() async {
        let client = CollisionScheduleClient()
        client.tasks = [client.tasks[0], client.tasks[0]]
        let store = ScheduledTasksStore(client: client, initialAgentID: nil)
        await store.load()
        #expect(store.loadState == .failed(ScheduledTasksError.invalidCatalog.localizedDescription))
        #expect(store.tasks.isEmpty)
    }
}

@MainActor
private final class CollisionScheduleClient: ScheduledTasksClient {
    var tasks: [ScheduledTask] = [
        .fixture(id: "shared-job", agentID: "research", name: "Research", deliveryTarget: "local"),
        .fixture(id: "shared-job", agentID: "writing", name: "Writing", deliveryTarget: "local")
    ]
    var mutations: [ScheduledTaskIdentity] = []
    var suspendPauses = false
    var continuations: [String: CheckedContinuation<ScheduledTask, any Error>] = [:]

    func list(agentID: String?) async throws -> [ScheduledTask] {
        tasks.filter { agentID == nil || $0.agentID == agentID }
    }
    func create(_ draft: ScheduledTaskDraft) async throws -> ScheduledTask { throw ScheduledTasksError.invalidSchedule }

    func update(id: String, agentID: String, changes: ScheduledTaskChanges) async throws -> ScheduledTask {
        let index = try index(id: id, profile: agentID)
        mutations.append(tasks[index].identity)
        tasks[index].name = changes.name
        tasks[index].instructions = changes.instructions
        return tasks[index]
    }

    func setPaused(_ paused: Bool, id: String, agentID: String) async throws -> ScheduledTask {
        let index = try index(id: id, profile: agentID)
        mutations.append(tasks[index].identity)
        if suspendPauses { return try await withCheckedThrowingContinuation { continuations[agentID] = $0 } }
        tasks[index].status = paused ? .paused : .active
        return tasks[index]
    }

    func runNow(id: String, agentID: String) async throws -> ScheduledTask {
        let index = try index(id: id, profile: agentID)
        mutations.append(tasks[index].identity)
        tasks[index].lastResult = "Synthetic run"
        return tasks[index]
    }

    func delete(id: String, agentID: String) async throws {
        let index = try index(id: id, profile: agentID)
        mutations.append(tasks[index].identity)
        tasks.remove(at: index)
    }

    func finishPause(profile: String) throws {
        let index = try index(id: "shared-job", profile: profile)
        tasks[index].status = .paused
        guard let continuation = continuations.removeValue(forKey: profile) else { throw ScheduledTasksError.taskNotFound }
        continuation.resume(returning: tasks[index])
    }

    func cancelPending() {
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }

    private func index(id: String, profile: String) throws -> Int {
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.agentID == profile }) else {
            throw ScheduledTasksError.taskNotFound
        }
        return index
    }
}
