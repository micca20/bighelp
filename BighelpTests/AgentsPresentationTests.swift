import Foundation
import Testing
@testable import Bighelp

struct AgentsPresentationTests {
    private let studio = AgentProfile(
        id: "studio", name: "Studio", role: "Everyday planning",
        summary: "Practical ideas for a small workshop.", instructions: "Private instruction marker.",
        isDefault: true
    )
    private let field = AgentProfile(
        id: "field", name: "Field Notes", role: "Research partner",
        summary: "Sources and careful explanations.", instructions: "", isDefault: false
    )

    @MainActor @Test func groupPreferencesPersistWithinOwnerAndAreErasedWithAccountData() throws {
        let suite = "group-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AgentGroupPreferences(defaults: defaults).set(.init(pinned: true, archived: true), id: "group", scope: "owner-a")
        let restored = AgentGroupPreferences(defaults: defaults)
        #expect(restored.entry("group", scope: "owner-a").pinned)
        #expect(restored.entry("group", scope: "owner-a").archived)
        #expect(!restored.entry("group", scope: "owner-b").archived)
        AgentDirectoryStore.erasePersistedUserPreferences(defaults: defaults)
        #expect(!AgentGroupPreferences(defaults: defaults).entry("group", scope: "owner-a").archived)
    }

    @Test func searchPreservesOrderAndMatchesMultiplePublicFields() {
        let profiles = [studio, field]
        #expect(AgentDirectoryPresentation.visibleProfiles(profiles, query: "planning workshop") == [studio])
        #expect(AgentDirectoryPresentation.visibleProfiles(profiles, query: "   ") == profiles)
        #expect(AgentDirectoryPresentation.visibleProfiles(profiles, query: "FIELD") == [field])
    }

    @Test func searchNeverExposesInstructionMatchesOrTheInternalPlaceholder() {
        #expect(AgentDirectoryPresentation.visibleProfiles([studio], query: "Private instruction").isEmpty)
        #expect(AgentDirectoryPresentation.visibleProfiles([.bighelpLinkDefault, studio]) == [studio])
    }

    @Test func memberSearchKeepsTheCompleteGroupRoster() {
        let group = room()
        let visible = AgentDirectoryPresentation.visibleGroups(
            [group], profiles: [studio, field], query: "Field Notes", profileID: nil
        )
        #expect(visible.count == 1)
        #expect(visible.first?.memberCount == 3)
        #expect(visible.first?.participants(profiles: [studio, field]).count == 3)
    }

    @Test func unavailableMembersKeepTheirNativeIdentityAndCount() {
        let participants = room().participants(profiles: [studio, field])
        #expect(participants.map(\.memberID) == ["member-studio", "member-field", "member-absent"])
        #expect(participants.last?.availability == .profileUnavailable)
        #expect(participants.last?.canOpenAgentChat == false)
    }

    @Test func groupSelectionPreservesTheCodexFirstMatchingFallback() {
        let groups = [room(id: "first"), room(id: "second")]
        #expect(AgentDirectoryPresentation.selectedGroup(in: groups, selectedID: nil)?.roomID == "first")
        #expect(AgentDirectoryPresentation.selectedGroup(in: groups, selectedID: "second")?.roomID == "second")
        #expect(AgentDirectoryPresentation.selectedGroup(in: groups, selectedID: "filtered-out")?.roomID == "first")
        #expect(AgentDirectoryPresentation.selectedGroup(in: [], selectedID: "first") == nil)
    }

    @Test func groupFilterUsesProfileIdentityRatherThanDisplayName() {
        #expect(AgentDirectoryPresentation.visibleGroups(
            [room()], profiles: [studio], query: "", profileID: "studio"
        ).count == 1)
        #expect(AgentDirectoryPresentation.visibleGroups(
            [room()], profiles: [studio], query: "", profileID: "Studio"
        ).isEmpty)
    }

    @Test func groupsAlwaysPrecedeAgentsIncludingWhenFilteredToAnAgent() {
        #expect(AgentDirectoryPresentation.sectionOrder == [.groups, .agents])
        #expect(AgentDirectoryPresentation.sectionOrder(filteredToProfileID: "studio") == [.groups, .agents])
    }

    @Test func unknownCapabilitiesDoNotEnableRemoteActions() throws {
        let owner = try owner()
        let items = actions(owner: owner, capabilities: WorkspaceCapabilities(owner: owner))
        #expect(items.first { $0.action == .openChat }?.isEnabled == false)
        #expect(items.first { $0.action == .edit }?.isEnabled == false)
        #expect(items.first { $0.action == .togglePin }?.isEnabled == true)
        #expect(items.first { $0.action == .setPrimary }?.isEnabled == true)
        #expect(!items.contains { $0.action == .shortcuts })
    }

    @Test func profileSpecificPolicyOverridesWorkspaceCapability() throws {
        let owner = try owner()
        let capabilities = WorkspaceCapabilities(
            owner: owner, values: [.profilesEdit: .available],
            profileValues: ["studio": [.profilesEdit: .unavailable(.policyRestricted)]]
        )
        let item = actions(owner: owner, capabilities: capabilities).first { $0.action == .edit }
        #expect(item?.isEnabled == false)
        #expect(item?.detail == WorkspaceUnavailableReason.policyRestricted.message)
    }

    @Test func staleCapabilitySnapshotCannotEnableNewOwnerActions() throws {
        let previous = try owner()
        let current = try owner()
        let capabilities = WorkspaceCapabilities(owner: previous, values: [.canonicalAgentChat: .available])
        #expect(actions(owner: current, capabilities: capabilities).first { $0.action == .openChat }?.isEnabled == false)
    }

    @Test func directNativeRuntimeSolelyOwnsInitialStoreRefreshWhileLinkKeepsViewBootstrap() throws {
        let direct = WorkspaceOwner(
            authority: try .direct(endpointIdentity: "https://hermes.example", providerID: "provider", userID: "user"),
            authenticationGeneration: UUID(), connectionGeneration: UUID()
        )
        let link = WorkspaceOwner(
            authority: try .link(origin: "https://loopdy.example", deviceID: "device", deviceAuthorizationEpoch: 1,
                                 hostID: "host", hostAuthorizationEpoch: 1),
            authenticationGeneration: UUID(), connectionGeneration: UUID()
        )
        let fixture = WorkspaceOwner(
            authority: try .fixture(id: "agents-presentation-fixture"),
            authenticationGeneration: UUID(), connectionGeneration: UUID()
        )

        #expect(!AgentsView.shouldBootstrapStoreRefresh(for: direct))
        #expect(AgentsView.shouldBootstrapStoreRefresh(for: link))
        #expect(AgentsView.shouldBootstrapStoreRefresh(for: fixture))
        #expect(AgentsView.shouldBootstrapStoreRefresh(for: nil))
    }

    @MainActor @Test func nativeRefreshFlightOutlivesCancelledViewCallerUntilExplicitSuspension() async {
        let flight = NativeWorkspaceRefreshFlight()
        let state = NativeRefreshFlightTestState()
        let caller = Task { @MainActor in
            await flight.run {
                state.started = true
                await Task.yield()
                state.finished = !Task.isCancelled
            }
        }

        while !state.started { await Task.yield() }
        caller.cancel()
        await caller.value
        #expect(state.finished)

        let secondState = NativeRefreshFlightTestState()
        let second = Task { @MainActor in
            await flight.run {
                secondState.started = true
                while !Task.isCancelled { await Task.yield() }
            }
        }
        while !secondState.started { await Task.yield() }
        flight.cancel()
        let replacementState = NativeRefreshFlightTestState()
        let replacement = Task { @MainActor in
            await flight.run {
                replacementState.started = true
            }
        }
        while !replacementState.started { await Task.yield() }
        await replacement.value
        await second.value
    }

    @Test func pinLimitNeverPreventsUnpinAndPrimaryRemainsSeparate() throws {
        let owner = try owner()
        let items = actions(owner: owner, capabilities: WorkspaceCapabilities(owner: owner), isPrimary: true, isPinned: true, canPin: false)
        #expect(items.first { $0.action == .togglePin }?.title == "Unpin")
        #expect(items.first { $0.action == .togglePin }?.isEnabled == true)
        #expect(items.first { $0.action == .setPrimary }?.isEnabled == false)
    }

    private func actions(
        owner: WorkspaceOwner, capabilities: WorkspaceCapabilities,
        isPrimary: Bool = false, isPinned: Bool = false, canPin: Bool = true
    ) -> [AgentActionItem] {
        AgentActionsPresentation.items(
            profileID: "studio", owner: owner, capabilities: capabilities,
            isPrimary: isPrimary, isPinned: isPinned, canPin: canPin,
            canClone: true, shortcutsAvailable: false, hasNavigation: true
        )
    }

    private func owner() throws -> WorkspaceOwner {
        WorkspaceOwner(
            authority: try .fixture(id: "agents-presentation"),
            authenticationGeneration: UUID(), connectionGeneration: UUID()
        )
    }

    private func room(id: String = "research-circle") -> HermesBotModeRoomSummary {
        let members = ["studio", "field", "absent"].map { id in
            HermesBotModeRoomMember(
                memberID: "member-\(id)", profile: id, handle: id,
                target: ["kind": .string("local"), "profile": .string(id)]
            )
        }
        return HermesBotModeRoomSummary(
            room: HermesBotModeRoomState(
                roomID: id, name: "Research Circle", members: members,
                authorityGatewayID: "fixture-gateway", authorityEpoch: 1, revision: 1,
                createdAt: 1_700_000_000, updatedAt: 1_700_000_060,
                latestSequence: 0, disbandedAt: nil, driverStatus: nil
            ),
            capabilities: nil
        )
    }
}

@MainActor
private final class NativeRefreshFlightTestState {
    var started = false
    var finished = false
}
