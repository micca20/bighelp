import Foundation
import Testing
@testable import Loopdy

@MainActor
struct BotModeRunTests {
    @Test func sendPersistsHumanEventBeforeSerialRosterDispatchAndSuppressesPasses() async throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research", "travel"])
        let client = RecordingBotModeClient(replies: [
            "finance": .reply("Finance reply"),
            "research": .pass,
            "travel": .reply("Travel reply")
        ])
        let store = BotModeRoomStore(client: client, rooms: [room])

        try await store.send(text: "Please coordinate", roomID: room.id)

        #expect(client.memberIDs == ["finance", "research", "travel"])
        #expect(client.sawPersistedHumanEvent)
        #expect(store.room(id: room.id)?.visibleEvents.filter { $0.kind == .agent }.map(\.memberID) == ["finance", "travel"])
        #expect(store.room(id: room.id)?.isRunning == false)
    }

    @Test func sendReportsCanonicalBotHandoffsAcrossTheSerialRun() async throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        let client = RecordingBotModeClient(replies: [
            "finance": .reply("Finance reply"),
            "research": .pass
        ])
        let store = BotModeRoomStore(client: client, rooms: [room])
        var activities: [BotModeRunActivity] = []

        try await store.send(
            text: "Please coordinate",
            roomID: room.id,
            activitySink: { activities.append($0) }
        )

        #expect(activities.map(\.memberID) == ["finance", "finance", "research", "research"])
        #expect(activities.map(\.lifecycle) == [.running, .succeeded, .running, .succeeded])
        #expect(Set(activities.map(\.runID)).count == 1)
        #expect(Set(activities.map(\.turnID)).count == 1)
        #expect(activities[0].fromMemberID == nil)
        #expect(activities[2].fromMemberID == "finance")
        #expect(activities[0].eventID == activities[1].eventID)
        #expect(activities[2].eventID == activities[3].eventID)
        #expect(activities.allSatisfy { !$0.runID.isEmpty && !$0.turnID.isEmpty })
    }

    @Test func partialFailurePersistsSuccessfulRepliesAndReportsRecoverableMemberFailure() async throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research", "travel"])
        let client = RecordingBotModeClient(replies: [
            "finance": .reply("Finance reply"),
            "research": .failure,
            "travel": .reply("Travel reply")
        ])
        let store = BotModeRoomStore(client: client, rooms: [room])

        try await store.send(text: "Please coordinate", roomID: room.id)

        #expect(store.room(id: room.id)?.visibleEvents.filter { $0.kind == .agent }.map(\.memberID) == ["finance", "travel"])
        #expect(store.room(id: room.id)?.memberFailures.map(\.memberID) == ["research"])
        #expect(store.room(id: room.id)?.isRunning == false)
    }

    @Test func replacedRoomAndCancelledRunRejectStaleCompletionAndFinalizer() async throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        let client = DeferredBotModeClient()
        let store = BotModeRoomStore(client: client, rooms: [room])

        let running = Task { try await store.send(text: "First", roomID: room.id) }
        await client.waitForFirstRequest()
        let replacement = BotModeRoom.fixture(id: room.id, memberIDs: ["finance", "research"])
        store.replace(room: replacement)
        client.resolveFirst(with: .reply("stale reply"))
        _ = try? await running.value

        #expect(store.room(id: room.id)?.visibleEvents.contains(where: { $0.text == "stale reply" }) == false)
        #expect(store.room(id: room.id)?.isRunning == false)

        let cancelled = Task { try await store.send(text: "Second", roomID: room.id) }
        await client.waitForSecondRequest()
        store.cancel(roomID: room.id)
        client.resolveSecond(with: .reply("cancelled reply"))
        _ = try? await cancelled.value

        #expect(store.room(id: room.id)?.visibleEvents.contains(where: { $0.text == "cancelled reply" }) == false)
        #expect(store.room(id: room.id)?.isRunning == false)
    }

    @Test func failedAcceptedHumanSavePreventsEveryDispatch() async throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        let persistence = FailingBotModePersistence(rooms: [room])
        let client = RecordingBotModeClient(replies: [:])
        let store = BotModeRoomStore(client: client, persistence: persistence)
        try store.load()

        await #expect(throws: BotModePersistenceError.writeFailed) {
            try await store.send(text: "Persist first", roomID: room.id)
        }

        #expect(client.memberIDs.isEmpty)
        #expect(store.room(id: room.id)?.visibleEvents.map(\.kind) == [.botModeStarted])
    }

    @Test func secondMemberTurnDoesNotStartUntilFirstSettles() async throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        let client = DeferredBotModeClient()
        let store = BotModeRoomStore(client: client, rooms: [room])

        let running = Task { try await store.send(text: "Sequence", roomID: room.id) }
        await client.waitForFirstRequest()
        #expect(client.secondRequestStarted == false)
        client.resolveFirst(with: .reply("First reply"))
        await client.waitForSecondRequest()
        client.resolveSecond(with: .reply("Second reply"))
        try await running.value
    }

    @Test func successfulAcceptedHumanSavePrecedesFirstDispatch() async throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        let persistence = RecordingBotModePersistence(rooms: [room])
        let observation = SaveObservation()
        let client = RecordingBotModeClient(replies: [:]) { _ in
            guard let saved = persistence.savedRooms.last else { return }
            observation.sawAcceptedRunBeforeDispatch = saved.visibleEvents.contains(where: { $0.kind == .human && $0.text == "Persisted first" })
                && saved.persistenceRevision > 0
                && saved.isRunning
                && saved.runOwner != nil
        }
        let store = BotModeRoomStore(client: client, persistence: persistence)
        try store.load()

        try await store.send(text: "Persisted first", roomID: room.id)

        #expect(observation.sawAcceptedRunBeforeDispatch)
        #expect(client.memberIDs == ["finance", "research"])
    }

    @Test func independentlyConstructedRepositoryStoresRejectStaleCompletion() async throws {
        let directory = try botModeRunTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        let firstRepository = DemoRepository<[BotModeRoom]>(directory: directory, name: "bot-rooms", seed: [room])
        let secondRepository = DemoRepository<[BotModeRoom]>(directory: directory, name: "bot-rooms", seed: [room])
        let diskRepository = DemoRepository<[BotModeRoom]>(directory: directory, name: "bot-rooms", seed: [room])
        try firstRepository.save([room])
        let firstClient = DeferredBotModeClient(deferEveryTurn: false)
        let secondClient = DeferredBotModeClient()
        let firstStore = BotModeRoomStore(client: firstClient, repository: firstRepository)
        let secondStore = BotModeRoomStore(client: secondClient, repository: secondRepository)
        try firstStore.load()
        try secondStore.load()

        let firstRun = Task { try await firstStore.send(text: "Old request", roomID: room.id) }
        await firstClient.waitForFirstRequest()
        try secondStore.load()
        let secondRun = Task { try await secondStore.send(text: "New request", roomID: room.id) }
        await secondClient.waitForFirstRequest()

        firstClient.resolveFirst(with: .reply("stale reply"))
        _ = try? await firstRun.value
        let canonicalWhileSecondRuns = try #require(try diskRepository.load().first)
        #expect(canonicalWhileSecondRuns.isRunning == true)
        #expect(canonicalWhileSecondRuns.visibleEvents.contains(where: { $0.text == "stale reply" }) == false)
        #expect(canonicalWhileSecondRuns.visibleEvents.contains(where: { $0.text == "New request" }))

        secondClient.resolveFirst(with: .reply("fresh reply"))
        await secondClient.waitForSecondRequest()
        secondClient.resolveSecond(with: .pass)
        try await secondRun.value
    }
}

@MainActor
private final class RecordingBotModeClient: BotModeMemberTurnClient {
    enum Reply {
        case reply(String)
        case pass
        case failure
    }

    private let replies: [String: Reply]
    private(set) var memberIDs: [String] = []
    private(set) var sawPersistedHumanEvent = false

    private let onRequest: ((BotModeMemberTurnRequest) -> Void)?

    init(replies: [String: Reply], onRequest: ((BotModeMemberTurnRequest) -> Void)? = nil) {
        self.replies = replies
        self.onRequest = onRequest
    }

    func performMemberTurn(_ request: BotModeMemberTurnRequest) async throws -> BotModeMemberTurnResult {
        memberIDs.append(request.memberID)
        onRequest?(request)
        sawPersistedHumanEvent = request.sharedEvents.contains(where: { $0.kind == .human && $0.text == "Please coordinate" })
        switch replies[request.memberID] ?? .pass {
        case .reply(let text): return .reply(text)
        case .pass: return .pass
        case .failure: throw BotModeFixtureError.failedMember
        }
    }
}

@MainActor
private final class DeferredBotModeClient: BotModeMemberTurnClient {
    private var requests = 0
    private let deferEveryTurn: Bool
    private var firstContinuation: CheckedContinuation<BotModeMemberTurnResult, Error>?
    private var secondContinuation: CheckedContinuation<BotModeMemberTurnResult, Error>?

    var secondRequestStarted: Bool { secondContinuation != nil }

    init(deferEveryTurn: Bool = true) {
        self.deferEveryTurn = deferEveryTurn
    }

    func performMemberTurn(_ request: BotModeMemberTurnRequest) async throws -> BotModeMemberTurnResult {
        requests += 1
        if requests > 1, !deferEveryTurn { return .pass }
        return try await withCheckedThrowingContinuation { continuation in
            if requests == 1 { firstContinuation = continuation } else { secondContinuation = continuation }
        }
    }

    func waitForFirstRequest() async { while firstContinuation == nil { await Task.yield() } }
    func waitForSecondRequest() async { while secondContinuation == nil { await Task.yield() } }
    func resolveFirst(with result: BotModeMemberTurnResult) { firstContinuation?.resume(returning: result); firstContinuation = nil }
    func resolveSecond(with result: BotModeMemberTurnResult) { secondContinuation?.resume(returning: result); secondContinuation = nil }
}

@MainActor
private final class FailingBotModePersistence: BotModeRoomPersistence {
    private let rooms: [BotModeRoom]

    init(rooms: [BotModeRoom]) { self.rooms = rooms }
    func load(recoveringRuns: Bool) throws -> [BotModeRoom] { rooms }
    func compareAndSave(_ room: BotModeRoom, expectedRevision: Int, expectedOwner: BotModeRunOwnerExpectation) throws -> BotModeRoom? {
        throw BotModePersistenceError.writeFailed
    }
}

@MainActor
private final class RecordingBotModePersistence: BotModeRoomPersistence {
    private var rooms: [BotModeRoom]
    private(set) var savedRooms: [BotModeRoom] = []

    init(rooms: [BotModeRoom]) { self.rooms = rooms }

    func load(recoveringRuns: Bool) throws -> [BotModeRoom] { rooms }

    func compareAndSave(
        _ room: BotModeRoom,
        expectedRevision: Int,
        expectedOwner: BotModeRunOwnerExpectation
    ) throws -> BotModeRoom? {
        guard let index = rooms.firstIndex(where: { $0.id == room.id }),
              rooms[index].persistenceRevision == expectedRevision else { return nil }
        var saved = room
        saved.markPersisted(revision: expectedRevision + 1)
        rooms[index] = saved
        savedRooms.append(saved)
        return saved
    }
}

@MainActor
private final class SaveObservation {
    var sawAcceptedRunBeforeDispatch = false
}

private func botModeRunTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "LoopdyBotModeRunTests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
