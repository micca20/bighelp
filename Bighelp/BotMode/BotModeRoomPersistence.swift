import Foundation

/// Shared local persistence. Stores that use one backing receive this same port,
/// which serializes revision and run-owner compare-and-save operations.
@MainActor
protocol BotModeRoomPersistence {
    func prepareNativeStorage() throws
    func load(recoveringRuns: Bool) throws -> [BotModeRoom]
    func insert(_ room: BotModeRoom) throws -> BotModeRoom?
    func compareAndSave(
        _ room: BotModeRoom,
        expectedRevision: Int,
        expectedOwner: BotModeRunOwnerExpectation
    ) throws -> BotModeRoom?
    func remove(roomID: String) throws -> Bool
}

@MainActor
extension BotModeRoomPersistence {
    func prepareNativeStorage() throws {}
    func insert(_ room: BotModeRoom) throws -> BotModeRoom? { nil }
    func remove(roomID: String) throws -> Bool { false }
}

@MainActor
final class DemoBotModeRoomPersistence: BotModeRoomPersistence {
    private let repository: DemoRepository<[BotModeRoom]>

    init(repository: DemoRepository<[BotModeRoom]>) {
        self.repository = repository
    }

    func prepareNativeStorage() throws {
        guard repository.currentSchemaVersion == BotModeRoomCacheSchema.currentVersion else {
            throw BotModePersistenceError.unsupportedNativeSchema
        }
    }

    func load(recoveringRuns: Bool) throws -> [BotModeRoom] {
        var rooms = try repository.load()
        guard recoveringRuns, rooms.contains(where: { $0.isRunning || $0.runOwner != nil }) else { return rooms }
        try rooms.forEach(requireSchema)
        for index in rooms.indices where rooms[index].isRunning || rooms[index].runOwner != nil {
            rooms[index].recoverFromPersistedRun()
            rooms[index].markPersisted(revision: rooms[index].persistenceRevision + 1)
        }
        try repository.save(rooms)
        return rooms
    }

    func insert(_ room: BotModeRoom) throws -> BotModeRoom? {
        try requireSchema(room)
        var rooms = try repository.load()
        guard !rooms.contains(where: { $0.id == room.id }) else { return nil }
        var saved = room
        saved.markPersisted(revision: 0)
        rooms.append(saved)
        try repository.save(rooms)
        return saved
    }

    func compareAndSave(
        _ room: BotModeRoom,
        expectedRevision: Int,
        expectedOwner: BotModeRunOwnerExpectation
    ) throws -> BotModeRoom? {
        try requireSchema(room)
        // Read the backing record for every operation. MainActor serialization
        // makes this check-and-save one local critical section even when stores
        // constructed separate persistence adapters for the same repository.
        var rooms = try repository.load()
        guard let index = rooms.firstIndex(where: { $0.id == room.id }) else { return nil }
        let current = rooms[index]
        guard current.persistenceRevision == expectedRevision, expectedOwner.matches(current) else { return nil }
        var saved = room
        saved.markPersisted(revision: current.persistenceRevision + 1)
        rooms[index] = saved
        try repository.save(rooms)
        return saved
    }

    func remove(roomID: String) throws -> Bool {
        var rooms = try repository.load()
        guard rooms.contains(where: { $0.id == roomID }) else { return true }
        rooms.removeAll { $0.id == roomID }
        try rooms.forEach(requireSchema)
        try repository.save(rooms)
        return true
    }

    private func requireSchema(_ room: BotModeRoom) throws {
        if room.hasNativeRoom || room.nativePendingCreation != nil
            || room.members.contains(where: { $0.nativeMemberID != nil }) {
            try prepareNativeStorage()
        }
    }

}

extension BotModeRunOwnerExpectation {
    func matches(_ room: BotModeRoom) -> Bool {
        switch self {
        case .noOwner: room.runOwner == nil && !room.isRunning
        case .owner(let owner): room.runOwner == owner && room.isRunning
        }
    }
}
