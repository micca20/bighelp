import Foundation

struct SessionSectionKey: RawRepresentable, Hashable, Identifiable, Codable, Sendable {
    let rawValue: String

    var id: String { rawValue }

    static let pinned = Self(rawValue: "pinned")
    static let active = Self(rawValue: "active")
    static let sessions = Self(rawValue: "sessions")
    static let unassigned = Self(rawValue: "unassigned")

    static func project(_ projectID: String) -> Self {
        Self(rawValue: "project:\(projectID)")
    }

    var isReorderable: Bool {
        rawValue == Self.unassigned.rawValue || rawValue.hasPrefix("project:")
    }
}

enum SessionSectionMoveDirection: Equatable, Sendable {
    case up
    case down
}

struct SessionSectionPreferences: Codable, Equatable, Sendable {
    var projectOrder: [SessionSectionKey] = []
    var collapsedSectionKeys: Set<SessionSectionKey> = []

    func isCollapsed(_ key: SessionSectionKey) -> Bool {
        collapsedSectionKeys.contains(key)
    }
}

struct SessionSectionLayout: Equatable, Sendable {
    let projectOrder: [SessionSectionKey]
    let collapsedSectionKeys: Set<SessionSectionKey>

    func isCollapsed(_ key: SessionSectionKey) -> Bool {
        collapsedSectionKeys.contains(key)
    }

    static func orderedProjectKeys(
        savedOrder: [SessionSectionKey],
        availableKeys: [SessionSectionKey]
    ) -> [SessionSectionKey] {
        let available = Set(availableKeys.filter(\.isReorderable))
        var seen = Set<SessionSectionKey>()
        let saved = savedOrder.filter {
            available.contains($0) && seen.insert($0).inserted
        }
        return saved + availableKeys.filter {
            $0.isReorderable && seen.insert($0).inserted
        }
    }

    static func preservingSavedKeys(
        reorderedKeys: [SessionSectionKey],
        savedOrder: [SessionSectionKey]
    ) -> [SessionSectionKey] {
        var seen = Set<SessionSectionKey>()
        let incoming = reorderedKeys.filter { $0.isReorderable && seen.insert($0).inserted }
        let incomingSet = Set(incoming)
        seen.removeAll()
        let saved = savedOrder.filter { $0.isReorderable && seen.insert($0).inserted }
        var replacements = incoming.makeIterator()
        // Replace only the slots represented by this view. Filtered-out and
        // temporarily absent projects retain their existing positions.
        var result = saved.map { key in
            incomingSet.contains(key) ? (replacements.next() ?? key) : key
        }
        result.append(contentsOf: replacements)
        return result
    }

    static func moving(
        _ source: SessionSectionKey,
        to target: SessionSectionKey,
        in order: [SessionSectionKey]
    ) -> [SessionSectionKey] {
        guard
            source != target,
            let sourceIndex = order.firstIndex(of: source),
            let targetIndex = order.firstIndex(of: target)
        else { return order }
        var reordered = order
        let moved = reordered.remove(at: sourceIndex)
        reordered.insert(moved, at: min(targetIndex, reordered.endIndex))
        return reordered
    }
}

enum SessionSectionOrganizer {
    static func sections(
        from sessions: [SessionSummary],
        organizeByProjects: Bool,
        projectOrder: [SessionSectionKey] = []
    ) -> [SessionDaySection] {
        let ordered = sessions.sorted(by: recencySort)
        let pinned = ordered.filter { $0.isPinned && !$0.isActive }
        let active = ordered.filter(\.isActive)
        let remaining = ordered.filter { !$0.isPinned && !$0.isActive }

        var sections: [SessionDaySection] = []
        if !active.isEmpty {
            sections.append(SessionDaySection(day: .active, sessions: active))
        }
        if !pinned.isEmpty {
            sections.append(SessionDaySection(day: .pinned, sessions: pinned))
        }

        guard organizeByProjects else {
            if !remaining.isEmpty {
                sections.append(SessionDaySection(day: .sessions, sessions: remaining))
            }
            return sections
        }

        let projectGroups = Dictionary(grouping: remaining.compactMap { session -> (String, SessionSummary)? in
            guard let projectID = session.workspaceID, !projectID.isEmpty else { return nil }
            return (projectID, session)
        }, by: { $0.0 })
        let defaultProjectKeys = projectGroups
            .compactMap { projectID, entries -> (SessionSectionKey, Date, String)? in
                guard let newest = entries.map(\.1).sorted(by: recencySort).first else {
                    return nil
                }
                return (.project(projectID), newest.updatedAt, newest.workspaceName ?? "Project")
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                let nameOrder = lhs.2.localizedStandardCompare(rhs.2)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.0.rawValue < rhs.0.rawValue
            }
            .map(\.0)

        let unassigned = remaining.filter {
            guard let projectID = $0.workspaceID else { return true }
            return projectID.isEmpty
        }
        var availableKeys = defaultProjectKeys
        if !unassigned.isEmpty { availableKeys.append(.unassigned) }
        let orderedKeys = SessionSectionLayout.orderedProjectKeys(
            savedOrder: projectOrder,
            availableKeys: availableKeys
        )

        for key in orderedKeys {
            if key == .unassigned {
                sections.append(SessionDaySection(day: .unassigned, sessions: unassigned))
                continue
            }
            guard key.rawValue.hasPrefix("project:") else { continue }
            let projectID = String(key.rawValue.dropFirst("project:".count))
            guard let entries = projectGroups[projectID] else { continue }
            let projectSessions = entries.map(\.1).sorted(by: recencySort)
            guard let newest = projectSessions.first else { continue }
            let project = SessionProjectOption(
                projectID: projectID,
                name: newest.workspaceName ?? "Project"
            )
            sections.append(SessionDaySection(day: .project(project), sessions: projectSessions))
        }
        return sections
    }

    static func reorderableKeys(
        in sessions: [SessionSummary],
        organizeByProjects: Bool,
        projectOrder: [SessionSectionKey] = []
    ) -> [SessionSectionKey] {
        sections(
            from: sessions,
            organizeByProjects: organizeByProjects,
            projectOrder: projectOrder
        ).map(\.key).filter(\.isReorderable)
    }

    static func recencySort(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }
}
