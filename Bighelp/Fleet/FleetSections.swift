import Foundation

/// A folder the person makes in the all-hosts list. The list of sections
/// (their order, empty ones) belongs to this device; which section an agent
/// is in is saved on the agent's own host profile, the way Hermes Desktop
/// does, so other computers and phones file it the same.
struct FleetSection: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String

    /// The same shape Hermes Desktop makes (`sec-<time>-<random>`).
    static func newID(now: Date = Date()) -> String {
        let time = String(Int(now.timeIntervalSince1970 * 1_000), radix: 36)
        let random = String((0..<5).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        return "sec-\(time)-\(random)"
    }

    static let maximumCount = 50

    static func cleanName(_ name: String) -> String? { AgentListPlacement.cleanName(name) }

    /// Section names match the way people read them: "Work" and "work " are one.
    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// An agent or a group chat in the all-hosts list.
enum FleetListItem: Identifiable, Equatable {
    case agent(FleetAgent)
    case group(FleetGroup)

    var id: String {
        switch self {
        case .agent(let agent): agent.id
        case .group(let group): group.id
        }
    }
}

/// One block of the sectioned list. Without a section it's everything not filed.
struct FleetSectionBlock: Identifiable, Equatable {
    let section: FleetSection?
    let items: [FleetListItem]
    var id: String { section?.id ?? "fleet.unsectioned" }
}

/// What deleting a section needs to put it back.
struct FleetSectionDeletion: Equatable {
    let section: FleetSection
    let index: Int
    let agentIDs: [String]
    let groupIDs: [String]
}

enum FleetSectioning {
    /// Sections other devices made, rebuilt from the names their members
    /// carry. A known section takes its members' name only when they all
    /// agree (a rename elsewhere, fully saved). A section whose name is
    /// already listed joins it, so same-named sections on different hosts
    /// show as one. Mirrors Hermes Desktop's `adoptBotSectionsFromMeta`.
    static func adopt(_ local: [FleetSection], placements: [AgentListPlacement],
                      ignoring pendingDeletes: Set<String>) -> [FleetSection] {
        var order: [String] = []
        var names: [String: Set<String>] = [:]
        for placement in placements {
            guard let id = placement.sectionID, let name = placement.sectionName else { continue }
            if names[id] == nil { order.append(id) }
            names[id, default: []].insert(name)
        }
        let known = Set(local.map(\.id))
        var result = local.map { section -> FleetSection in
            guard let agreed = names[section.id], agreed.count == 1, let name = agreed.first else { return section }
            return FleetSection(id: section.id, name: name)
        }
        var listedNames = Set(result.map { FleetSection.nameKey($0.name) })
        for id in order where !known.contains(id) && !pendingDeletes.contains(id) {
            guard let name = names[id]?.sorted().first, listedNames.insert(FleetSection.nameKey(name)).inserted
            else { continue }
            result.append(FleetSection(id: id, name: name))
        }
        return Array(result.prefix(FleetSection.maximumCount))
    }

    /// The section an agent shows in: its own by ID, or one with the same
    /// name (made on another host). Nil when it's not filed anywhere listed.
    static func section(for placement: AgentListPlacement?, in sections: [FleetSection]) -> FleetSection? {
        guard let placement, let id = placement.sectionID else { return nil }
        if let exact = sections.first(where: { $0.id == id }) { return exact }
        guard let name = placement.sectionName else { return nil }
        return sections.first { FleetSection.nameKey($0.name) == FleetSection.nameKey(name) }
    }

    /// Splits items into section blocks in section order, unfiled last. An
    /// item filed in a section this device doesn't have lands unfiled
    /// rather than vanishing, which is what makes deleting a section safe.
    static func blocks(_ items: [FleetListItem], sections: [FleetSection],
                       groupSections: [String: String]) -> [FleetSectionBlock] {
        let known = Set(sections.map(\.id))
        var filed: [String: [FleetListItem]] = [:]
        var loose: [FleetListItem] = []
        for item in items {
            let sectionID: String? = switch item {
            case .agent(let agent): section(for: agent.placement, in: sections)?.id
            case .group(let group): groupSections[group.id].flatMap { known.contains($0) ? $0 : nil }
            }
            if let sectionID { filed[sectionID, default: []].append(item) } else { loose.append(item) }
        }
        return sections.map { FleetSectionBlock(section: $0, items: filed[$0.id] ?? []) }
            + [FleetSectionBlock(section: nil, items: loose)]
    }
}

extension FleetStore {
    // MARK: Sections

    func section(id: String?) -> FleetSection? {
        guard let id else { return nil }
        return sections.first { $0.id == id }
    }

    /// The section an agent shows in here.
    func section(of agent: FleetAgent) -> FleetSection? {
        FleetSectioning.section(for: agent.placement, in: sections)
    }

    func section(of group: FleetGroup) -> FleetSection? { section(id: groupSectionIDs[group.id]) }

    /// Agents the person hid. They stay in groups, chats and mentions.
    var hiddenAgentCount: Int { agents().filter(\.isHidden).count }

    /// Every group chat, the most recently active first.
    func groups(on hostID: UUID? = nil) -> [FleetGroup] {
        hosts.filter { hostID == nil || $0.id == hostID }
            .flatMap { snapshots[$0.id]?.groups ?? [] }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func createSection(named name: String) -> FleetSection? {
        guard let clean = FleetSection.cleanName(name), sections.count < FleetSection.maximumCount else { return nil }
        if let existing = sections.first(where: { FleetSection.nameKey($0.name) == FleetSection.nameKey(clean) }) {
            return existing
        }
        let section = FleetSection(id: FleetSection.newID(), name: clean)
        sections.append(section)
        saveSections()
        return section
    }

    /// Moves a section up (-1) or down (+1). The order is this device's own.
    func moveSection(_ id: String, by delta: Int) {
        guard let from = sections.firstIndex(where: { $0.id == id }), sections.indices.contains(from + delta) else { return }
        sections.swapAt(from, from + delta)
        saveSections()
    }

    /// Renames it here, then on each member, so other devices get the new name.
    func renameSection(_ id: String, to name: String) async {
        guard let clean = FleetSection.cleanName(name), let index = sections.firstIndex(where: { $0.id == id }),
              sections[index].name != clean else { return }
        let members = members(of: id)
        sections[index].name = clean
        saveSections()
        for agent in members where self.section(id: id) != nil {
            var placement = agent.placement ?? AgentListPlacement()
            placement.sectionID = id
            placement.sectionName = clean
            try? await savePlacement(placement, for: agent)
        }
    }

    /// Deletes the section only: its agents and groups go back to the
    /// unfiled list, never deleted. Returns what Undo needs.
    @discardableResult
    func deleteSection(_ id: String) -> FleetSectionDeletion? {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return nil }
        let members = members(of: id)
        let section = sections.remove(at: index)
        let groups = groupSectionIDs.filter { $0.value == id }.map(\.key)
        let deletion = FleetSectionDeletion(section: section, index: index, agentIDs: members.map(\.id), groupIDs: groups)
        let token = UUID()
        pendingSectionDeletes[id] = token
        for group in groups { groupSectionIDs[group] = nil }
        saveSections()
        Task { @MainActor [weak self] in
            for agent in members {
                guard let self, pendingSectionDeletes[id] == token else { return }
                var placement = agent.placement ?? AgentListPlacement()
                placement.sectionID = nil
                placement.sectionName = nil
                try? await savePlacement(placement, for: agent)
            }
            if self?.pendingSectionDeletes[id] == token { self?.pendingSectionDeletes[id] = nil }
        }
        return deletion
    }

    func undoDeleteSection(_ deletion: FleetSectionDeletion) {
        pendingSectionDeletes[deletion.section.id] = nil
        guard !sections.contains(where: { $0.id == deletion.section.id }) else { return }
        sections.insert(deletion.section, at: min(deletion.index, sections.count))
        for group in deletion.groupIDs { groupSectionIDs[group] = deletion.section.id }
        saveSections()
        let agents = deletion.agentIDs.compactMap { id in self.agents().first { $0.id == id } }
        Task { @MainActor [weak self] in
            for agent in agents {
                guard let self, let current = self.agent(hostID: agent.hostID, profileID: agent.profileID) else { continue }
                try? await file(current, in: deletion.section.id)
            }
        }
    }

    /// Files an agent into a section (nil takes it out), on its own host.
    func file(_ agent: FleetAgent, in sectionID: String?) async throws {
        var placement = agent.placement ?? AgentListPlacement()
        let section = section(id: sectionID)
        placement.sectionID = section?.id
        placement.sectionName = section?.name
        try await savePlacement(placement, for: agent)
    }

    /// Hiding only changes the list: the agent keeps working everywhere else.
    func setHidden(_ agent: FleetAgent, _ hidden: Bool) async throws {
        var placement = agent.placement ?? AgentListPlacement()
        placement.isHidden = hidden
        try await savePlacement(placement, for: agent)
    }

    /// A group's section stays on this device, as Hermes Desktop keeps it.
    func file(_ group: FleetGroup, in sectionID: String?) {
        groupSectionIDs[group.id] = section(id: sectionID)?.id
        saveSections()
    }

    private func members(of sectionID: String) -> [FleetAgent] {
        agents().filter { section(of: $0)?.id == sectionID }
    }

    /// Shows the change at once and saves it on the agent's host. The
    /// selected host saves through its own agent list; others through the
    /// reader. A failed save puts the old placement back.
    func savePlacement(_ placement: AgentListPlacement, for agent: FleetAgent) async throws {
        guard let current = self.agent(hostID: agent.hostID, profileID: agent.profileID) else { return }
        let previous = current.placement
        guard previous ?? AgentListPlacement() != placement else { return }
        setPlacementLocally(placement, agentID: agent.id, hostID: agent.hostID)
        placementWrites[agent.id] = Date()
        do {
            if agent.hostID == selectedHostID, let writer = selectedHostPlacementWriter {
                try await writer(placement, agent.profileID)
            } else {
                try await reader.setPlacement(placement, hostID: agent.hostID, profileID: agent.profileID)
            }
            placementWrites[agent.id] = Date()
            placementError = nil
        } catch {
            setPlacementLocally(previous, agentID: agent.id, hostID: agent.hostID)
            placementWrites[agent.id] = nil
            placementError = Self.placementMessage(error, hostName: hostName(agent.hostID))
            throw error
        }
    }

    private func setPlacementLocally(_ placement: AgentListPlacement?, agentID: String, hostID: UUID) {
        guard var snapshot = snapshots[hostID],
              let index = snapshot.agents.firstIndex(where: { $0.id == agentID }) else { return }
        snapshot.agents[index].placement = placement
        replaceSnapshot(snapshot, hostID: hostID)
    }

    static func placementMessage(_ error: any Error, hostName: String) -> String {
        switch error as? WorkspaceClientError {
        case .unavailable?: "Update Hermes on \(hostName) to keep sections and hidden agents there."
        case .conflict?: "This agent changed on another device. Try again."
        default: "\(hostName) couldn't save this just now. Try again."
        }
    }

    /// A read that started before a save can't undo it: for a minute after
    /// saving, the saved placement wins over what a read brings back.
    func fencedPlacements(_ snapshot: FleetSnapshot, hostID: UUID) -> FleetSnapshot {
        let now = Date()
        placementWrites = placementWrites.filter { now.timeIntervalSince($0.value) < 60 }
        guard !placementWrites.isEmpty, let current = snapshots[hostID] else { return snapshot }
        var fenced = snapshot
        for index in fenced.agents.indices where placementWrites[fenced.agents[index].id] != nil {
            if let local = current.agents.first(where: { $0.id == fenced.agents[index].id }) {
                fenced.agents[index].placement = local.placement
            }
        }
        return fenced
    }

    /// Rebuilds sections other devices made from what their members carry.
    func adoptSections() {
        let placements = hosts.flatMap { snapshots[$0.id]?.agents ?? [] }.compactMap(\.placement)
        let adopted = FleetSectioning.adopt(sections, placements: placements,
                                            ignoring: Set(pendingSectionDeletes.keys))
        guard adopted != sections else { return }
        sections = adopted
        saveSections()
    }

    // MARK: Saving

    struct SavedSections: Codable {
        var sections: [FleetSection]
        var groups: [String: String]
    }

    var sectionsURL: URL { directory.appending(path: "sections.json", directoryHint: .notDirectory) }

    func loadSections() {
        guard let data = try? Data(contentsOf: sectionsURL),
              let saved = try? JSONDecoder().decode(SavedSections.self, from: data) else { return }
        var seen = Set<String>()
        sections = saved.sections.compactMap { section in
            guard !section.id.isEmpty, section.id.utf8.count <= 128, seen.insert(section.id).inserted,
                  let name = FleetSection.cleanName(section.name) else { return nil }
            return FleetSection(id: section.id, name: name)
        }.prefix(FleetSection.maximumCount).map { $0 }
        groupSectionIDs = saved.groups.filter { seen.contains($0.value) }
    }

    func saveSections() {
        let protector = BighelpLocalFileProtector()
        try? protector.prepareDirectory(directory, protection: .privateVisual, fileManager: .default)
        if let data = try? JSONEncoder().encode(SavedSections(sections: sections, groups: groupSectionIDs)) {
            try? data.write(to: sectionsURL, options: [.atomic, .completeFileProtection])
        }
    }
}
