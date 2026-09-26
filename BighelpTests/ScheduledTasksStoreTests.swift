import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ScheduledTasksStoreTests {
    @Test func staleMutationCleanupCannotRemoveNewAccountPendingState() async {
        let task = ScheduledTask.fixture(id: "shared-task", agentID: "finance")
        let client = DeferredScheduledTaskMutationClient(task: task)
        let store = ScheduledTasksStore(client: client, initialAgentID: "finance")
        await store.load()

        let oldUpdate = Task {
            try? await store.update(
                id: task.id,
                name: "Old account update",
                instructions: task.instructions,
                schedule: task.schedule
            )
        }
        await client.waitUntilMutationStarts(count: 1)

        store.resetForAccountBoundary()
        await store.load()
        let newUpdate = Task {
            try? await store.update(
                id: task.id,
                name: "New account update",
                instructions: task.instructions,
                schedule: task.schedule
            )
        }
        await client.waitUntilMutationStarts(count: 2)

        client.resumeMutation(request: 1, with: task)
        await oldUpdate.value
        #expect(store.isPending(task.id))

        client.resumeMutation(request: 2, with: task)
        await newUpdate.value
        #expect(!store.isPending(task.id))
    }

    @Test func resetInvalidatesAnInFlightRemoteLoad() async {
        let client = DeferredScheduledTasksClient()
        let store = ScheduledTasksStore(client: client, initialAgentID: "finance")
        let loading = Task { await store.load() }

        await client.waitUntilListStarts()
        store.resetForAccountBoundary()
        client.resumeList(with: [.fixture(id: "old-account-task", agentID: "finance")])
        await loading.value

        #expect(store.tasks.isEmpty)
        #expect(store.loadState == .idle)
        #expect(store.errorMessage == nil)
    }

    @Test func updateCannotMoveTaskToAnotherAgent() async throws {
        let client = ScheduledTasksFixtureClient(now: Self.fixtureDate)
        let store = ScheduledTasksStore(client: client, initialAgentID: "finance")
        let task = try await store.create(.fixture(agentID: "finance"))

        try await store.update(
            id: task.id,
            name: "Changed",
            instructions: "Review",
            schedule: .dailyFixture
        )

        #expect(store.task(id: task.id)?.agentID == "finance")
        #expect(client.lastMutation?.agentID == "finance")
    }

    @Test func creatingWithoutAnAgentDoesNotSubmitAnInvalidTask() async throws {
        let client = ScheduledTasksFixtureClient(now: Self.fixtureDate)
        let store = ScheduledTasksStore(client: client, initialAgentID: nil)

        await #expect(throws: ScheduledTasksError.agentRequired) {
            _ = try await store.create(.fixture(agentID: ""))
        }

        #expect(store.tasks.isEmpty)
        #expect(client.lastMutation == nil)
    }

    @Test func naturalLanguageFailureKeepsTheEntireDraftForRecovery() async throws {
        let client = ScheduledTasksFixtureClient(now: Self.fixtureDate)
        client.naturalLanguageFailure = true
        let store = ScheduledTasksStore(client: client, initialAgentID: "finance")
        let draft = ScheduledTaskDraft(
            agentID: "finance",
            name: "Friday review",
            instructions: "Review invoices",
            schedule: .naturalLanguage("Every other Friday at 3 PM", timeZoneID: "America/Chicago")
        )

        await #expect(throws: ScheduledTasksError.unrecognizedDescription) {
            _ = try await store.create(draft)
        }

        #expect(store.recoverableDraft == draft)
        #expect(store.errorMessage?.contains("Try Pick a schedule") == true)
    }

    @Test func activeTasksOrderByNextRunBeforePausedTasks() async throws {
        let client = ScheduledTasksFixtureClient(
            tasks: [
                .fixture(id: "paused", agentID: "finance", isPaused: true, nextRun: Self.fixtureDate.addingTimeInterval(10)),
                .fixture(id: "later", agentID: "finance", nextRun: Self.fixtureDate.addingTimeInterval(300)),
                .fixture(id: "first", agentID: "finance", nextRun: Self.fixtureDate.addingTimeInterval(60))
            ],
            now: Self.fixtureDate
        )
        let store = ScheduledTasksStore(client: client, initialAgentID: "finance")
        await store.load()

        #expect(store.visibleTasks.map(\.id) == ["first", "later", "paused"])
    }

    private static let fixtureDate = Date(timeIntervalSinceReferenceDate: 777_600_000)
}

@MainActor
private final class DeferredScheduledTasksClient: ScheduledTasksClient {
    private var listContinuation: CheckedContinuation<[ScheduledTask], Error>?
    private var listStarted = false

    func list(agentID: String?) async throws -> [ScheduledTask] {
        listStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            listContinuation = continuation
        }
    }

    func create(_ draft: ScheduledTaskDraft) async throws -> ScheduledTask {
        throw ScheduledTasksError.taskNotFound
    }

    func update(id: String, agentID: String, changes: ScheduledTaskChanges) async throws -> ScheduledTask {
        throw ScheduledTasksError.taskNotFound
    }

    func setPaused(_ paused: Bool, id: String, agentID: String) async throws -> ScheduledTask {
        throw ScheduledTasksError.taskNotFound
    }

    func runNow(id: String, agentID: String) async throws -> ScheduledTask {
        throw ScheduledTasksError.taskNotFound
    }

    func delete(id: String, agentID: String) async throws {
        throw ScheduledTasksError.taskNotFound
    }

    func waitUntilListStarts() async {
        while !listStarted { await Task.yield() }
    }

    func resumeList(with tasks: [ScheduledTask]) {
        listContinuation?.resume(returning: tasks)
        listContinuation = nil
    }
}

@MainActor
private final class DeferredScheduledTaskMutationClient: ScheduledTasksClient {
    private let task: ScheduledTask
    private var mutationContinuations: [Int: CheckedContinuation<ScheduledTask, Error>] = [:]
    private var mutationCount = 0

    init(task: ScheduledTask) {
        self.task = task
    }

    func list(agentID: String?) async throws -> [ScheduledTask] { [task] }

    func create(_ draft: ScheduledTaskDraft) async throws -> ScheduledTask {
        throw ScheduledTasksError.taskNotFound
    }

    func update(id: String, agentID: String, changes: ScheduledTaskChanges) async throws -> ScheduledTask {
        mutationCount += 1
        let request = mutationCount
        return try await withCheckedThrowingContinuation { continuation in
            mutationContinuations[request] = continuation
        }
    }

    func setPaused(_ paused: Bool, id: String, agentID: String) async throws -> ScheduledTask {
        throw ScheduledTasksError.taskNotFound
    }

    func runNow(id: String, agentID: String) async throws -> ScheduledTask {
        throw ScheduledTasksError.taskNotFound
    }

    func delete(id: String, agentID: String) async throws {
        throw ScheduledTasksError.taskNotFound
    }

    func waitUntilMutationStarts(count: Int) async {
        while mutationCount < count { await Task.yield() }
    }

    func resumeMutation(request: Int, with task: ScheduledTask) {
        mutationContinuations.removeValue(forKey: request)?.resume(returning: task)
    }
}
