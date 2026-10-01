import Foundation
import Testing
@testable import Bighelp

/// The all-hosts view lists every host's agents, chats and tasks. The selected
/// host's come from the app live; the others are read, at most once a minute,
/// and kept on the device so the list shows at once and survives a host that's
/// out of reach.
@MainActor
struct FleetStoreTests {
    private let home = UUID()
    private let studio = UUID()
    private let office = UUID()

    @MainActor
    final class Reader: FleetHostReading {
        var hosts: [FleetHost]
        var snapshots: [UUID: FleetSnapshot] = [:]
        var failures: [UUID: String] = [:]
        private(set) var reads: [UUID] = []
        private(set) var selected: [UUID] = []
        private(set) var keptConnected: [UUID] = []

        init(hosts: [FleetHost]) { self.hosts = hosts }

        func read(_ hostID: UUID, avatars: FleetAvatarFolder) async throws -> FleetSnapshot {
            reads.append(hostID)
            if let message = failures[hostID] { throw FleetReadError(message: message) }
            return snapshots[hostID] ?? FleetSnapshot(refreshedAt: Date())
        }

        func select(_ hostID: UUID) {
            selected.append(hostID)
            hosts = hosts.map { FleetHost(id: $0.id, name: $0.name, isSelected: $0.id == hostID) }
        }

        func canOpen(_ hostID: UUID) -> Bool { true }

        func keepConnected(_ hostID: UUID) async { keptConnected.append(hostID) }
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "fleet-tests-\(UUID().uuidString)")
    }

    private func reader(_ count: Int = 2) -> Reader {
        Reader(hosts: [
            FleetHost(id: home, name: "Home", isSelected: true),
            FleetHost(id: studio, name: "Studio", isSelected: false),
            FleetHost(id: office, name: "Office", isSelected: false),
        ].prefix(count).map { $0 })
    }

    private func agent(_ host: UUID, _ id: String, _ name: String, pinned: Bool = false) -> FleetAgent {
        FleetAgent(hostID: host, profileID: id, name: name, role: "", isPinned: pinned, isDefault: false)
    }

    private func chat(_ host: UUID, _ profile: String, _ id: String, minutesAgo: Double) -> FleetChat {
        FleetChat(hostID: host, profileID: profile, storedSessionID: id, title: id, preview: "",
                  updatedAt: Date().addingTimeInterval(-minutesAgo * 60), isActive: false)
    }

    @Test func agentsFromEveryHostAreListedByTheirLatestChat() async {
        let reader = reader()
        reader.snapshots[studio] = FleetSnapshot(
            agents: [agent(studio, "default", "Rio")],
            chats: [chat(studio, "default", "s1", minutesAgo: 5)], refreshedAt: Date())
        let fleet = FleetStore(reader: reader, directory: directory(), saveDelay: .zero)
        fleet.recordLive(FleetSnapshot(
            agents: [agent(home, "default", "Avery"), agent(home, "travel", "Mina")],
            chats: [chat(home, "default", "h1", minutesAgo: 30), chat(home, "travel", "h2", minutesAgo: 1)],
            refreshedAt: Date()), hostID: home)

        fleet.refresh()
        await fleet.waitForReads()

        // The same profile ID on two hosts is two agents.
        #expect(fleet.agents().map(\.name) == ["Mina", "Rio", "Avery"])
        #expect(fleet.agents(on: studio).map(\.name) == ["Rio"])
        #expect(fleet.chats().map(\.storedSessionID) == ["h2", "s1", "h1"])
        #expect(fleet.showsHostNames)
        #expect(reader.reads == [studio], "The selected host is live; it is never read")
    }

    @Test func aHostIsReadAtMostOnceAMinuteUnlessAsked() async {
        let reader = reader()
        let fleet = FleetStore(reader: reader, directory: directory(), saveDelay: .zero)
        fleet.refresh()
        await fleet.waitForReads()
        fleet.refresh()
        await fleet.waitForReads()
        #expect(reader.reads == [studio])
        fleet.refresh(force: true)
        await fleet.waitForReads()
        #expect(reader.reads == [studio, studio])
    }

    @Test func aHostReadRecentlyIsStillKeptConnectedForTheNextSwitch() async {
        let reader = reader()
        let fleet = FleetStore(reader: reader, directory: directory(), saveDelay: .zero)
        fleet.refresh()
        await fleet.waitForReads()
        #expect(reader.keptConnected.isEmpty, "A read connects it anyway")

        fleet.refresh()
        for _ in 0..<20 where reader.keptConnected.isEmpty { await Task.yield() }
        #expect(reader.reads == [studio])
        #expect(reader.keptConnected == [studio], "Not read again, but its connection is checked")
    }

    @Test func aHostOutOfReachKeepsWhatItHadLastTime() async {
        let folder = directory()
        let reader = reader(3)
        reader.snapshots[office] = FleetSnapshot(agents: [agent(office, "ops", "Kit")], refreshedAt: Date())
        let first = FleetStore(reader: reader, directory: folder, saveDelay: .zero)
        first.refresh()
        await first.waitForReads()
        await first.waitForSaves()

        reader.failures[office] = "Couldn't reach this host."
        let relaunched = FleetStore(reader: reader, directory: folder, saveDelay: .zero)
        #expect(relaunched.agents(on: office).map(\.name) == ["Kit"], "Shown at once from this device")
        relaunched.refresh(force: true)
        await relaunched.waitForReads()

        #expect(relaunched.statuses[office] == .unreachable("Couldn't reach this host."))
        #expect(relaunched.agents(on: office).map(\.name) == ["Kit"])
    }

    @Test func aRemovedHostIsForgotten() async {
        let folder = directory()
        let reader = reader()
        reader.snapshots[studio] = FleetSnapshot(agents: [agent(studio, "default", "Rio")], refreshedAt: Date())
        let fleet = FleetStore(reader: reader, directory: folder, saveDelay: .zero)
        fleet.refresh()
        await fleet.waitForReads()
        await fleet.waitForSaves()

        reader.hosts.removeAll { $0.id == studio }
        fleet.syncHosts()

        #expect(fleet.agents().isEmpty)
        #expect(!fleet.showsHostNames)
        #expect(FleetStore(reader: reader, directory: folder).snapshots[studio] == nil)
    }

    @Test func liveDataOnlyCountsForAKnownHost() {
        let fleet = FleetStore(reader: reader(), directory: directory(), saveDelay: .zero)
        fleet.recordLive(FleetSnapshot(agents: [agent(office, "x", "Ghost")], refreshedAt: Date()), hostID: office)
        #expect(fleet.agents().isEmpty)
    }

    @Test func tasksThatWillRunComeFirstSoonestFirst() {
        let fleet = FleetStore(reader: reader(), directory: directory(), saveDelay: .zero)
        let now = Date()
        func task(_ name: String, _ status: ScheduledTaskStatus, in hours: Double?) -> FleetTask {
            FleetTask(hostID: home, jobID: name, profileID: "default", name: name, schedule: "",
                      nextRun: hours.map { now.addingTimeInterval($0 * 3_600) }, status: status)
        }
        fleet.recordLive(FleetSnapshot(tasks: [task("paused", .paused, in: nil), task("later", .active, in: 5),
                                               task("soon", .active, in: 1)], refreshedAt: now), hostID: home)
        #expect(fleet.tasks().map(\.name) == ["soon", "later", "paused"])
    }

    @Test func choosingAHostSelectsIt() {
        let reader = reader()
        let fleet = FleetStore(reader: reader, directory: directory(), saveDelay: .zero)
        fleet.select(studio)
        #expect(reader.selected == [studio])
        #expect(fleet.selectedHostID == studio)
    }

    // MARK: Reading a host's session list

    @Test func sessionRowsBecomeChatsWithWhatTheyAreDoingNow() throws {
        let row: BighelpJSONValue = .object([
            "id": .string("abc"), "title": .string("Trip"), "preview": .string("Book the flight"),
            "started_at": .number(1_790_000_000), "last_active": .number(1_790_000_600),
        ])
        let chat = try #require(RegistryFleetReader.chat(row, hostID: studio, profileID: "default",
                                                         live: ["abc": "streaming"]))
        #expect(chat.storedSessionID == "abc")
        #expect(chat.title == "Trip")
        #expect(chat.updatedAt == Date(timeIntervalSince1970: 1_790_000_600))
        #expect(chat.isActive)
        let idle = RegistryFleetReader.chat(row, hostID: studio, profileID: "default", live: ["abc": "idle"])
        #expect(idle?.isActive == false)
        #expect(RegistryFleetReader.chat(.object(["title": .string("No ID")]), hostID: studio,
                                         profileID: "default", live: [:]) == nil)
    }
}
