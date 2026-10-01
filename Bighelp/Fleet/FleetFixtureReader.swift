import Foundation

#if DEBUG
/// Demo hosts for the all-hosts view. "Home Hermes" is the demo's own agents
/// (live, like a selected host); "Studio Mac" has made-up agents to list but
/// not open; "Office Linux" can't be reached.
@MainActor
final class FleetFixtureReader: FleetHostReading {
    static let homeID = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000001")!
    static let studioID = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000002")!
    static let officeID = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000003")!

    var hosts: [FleetHost] {
        [(Self.homeID, "Home Hermes"), (Self.studioID, "Studio Mac"), (Self.officeID, "Office Linux")].map {
            FleetHost(id: $0.0, name: $0.1, isSelected: $0.0 == Self.homeID)
        }
    }

    func select(_ hostID: UUID) {}
    func canOpen(_ hostID: UUID) -> Bool { hostID == Self.homeID }
    /// Demo hosts keep pins on screen only.
    func setPinned(_ pinned: Bool, hostID: UUID, profileID: String) -> Bool { true }

    func read(_ hostID: UUID, avatars: FleetAvatarFolder) async throws -> FleetSnapshot {
        guard hostID == Self.studioID else { throw FleetReadError(message: "Couldn't reach this host.") }
        let id = Self.studioID
        let now = Date()
        return FleetSnapshot(
            agents: [
                FleetAgent(hostID: id, profileID: "research", name: "Rio Tanaka", role: "Research agent",
                           isPinned: true, isDefault: true),
                FleetAgent(hostID: id, profileID: "reviewer", name: "Sage Ortiz", role: "Code reviewer",
                           isPinned: false, isDefault: false, activity: .working),
            ],
            chats: [
                FleetChat(hostID: id, profileID: "research", storedSessionID: "studio-1", title: "Market scan",
                          preview: "Found three competitors worth a closer look.",
                          updatedAt: now.addingTimeInterval(-25 * 60), isActive: false),
                FleetChat(hostID: id, profileID: "reviewer", storedSessionID: "studio-2", title: "Pull request review",
                          preview: "Two small fixes before this can merge.",
                          updatedAt: now.addingTimeInterval(-2 * 60 * 60), isActive: true),
            ],
            tasks: [
                FleetTask(hostID: id, jobID: "digest", profileID: "research", name: "Morning research digest",
                          schedule: "Every day at 8:00 AM",
                          nextRun: Calendar.current.date(bySettingHour: 8, minute: 0, second: 0,
                                                         of: now.addingTimeInterval(24 * 60 * 60)),
                          status: .active),
                FleetTask(hostID: id, jobID: "health", profileID: "reviewer", name: "Weekly code health",
                          schedule: "Mondays at 9:00 AM", nextRun: nil, status: .paused),
            ],
            refreshedAt: now
        )
    }
}
#endif
