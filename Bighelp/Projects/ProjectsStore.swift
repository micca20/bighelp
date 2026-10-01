import Foundation
import Observation

/// What the Projects screens show beyond the project list itself: each
/// project's look, folders and chats. The list, the current project and
/// create/archive come from `HermesWorkspaceStore`, the same Hermes projects
/// the chat's folder picker uses.
@MainActor
@Observable
final class ProjectsStore {
    struct Details: Equatable, Sendable {
        var icon: String?
        var color: String?
        var folders: [String] = []
        var chatCount = 0
        var lastActive: Date?
    }

    struct Chat: Identifiable, Equatable, Sendable {
        /// Hermes's stored session ID.
        let id: String
        let profileID: String
        let title: String
        let preview: String
        let lastActive: Date?
        /// Demo chats name the chat to open directly.
        var catalogID: String? = nil
    }

    private(set) var details: [String: Details] = [:]
    private(set) var chats: [String: [Chat]] = [:]
    private(set) var loadingChats: Set<String> = []
    private(set) var errorMessage: String?
    /// A project chat being looked up on the host; the page shows "Opening chat…".
    var openingChatID: String?

    @ObservationIgnored private let source: any ProjectsSource
    @ObservationIgnored private let profileID: String

    init(source: any ProjectsSource, profileID: String) {
        self.source = source
        self.profileID = profileID
    }

    /// A Mac list can't be pulled down; it has a Refresh button instead.
    static var tryAgain: String {
        BighelpPlatform.isMac ? "Click Refresh to try again." : "Pull down to try again."
    }

    func refresh() async {
        do {
            details = try await source.details(profileID: profileID)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = "Projects couldn't load from your computer. \(Self.tryAgain)"
        }
    }

    func loadChats(projectID: String) async {
        loadingChats.insert(projectID)
        defer { loadingChats.remove(projectID) }
        do {
            let rows = try await source.chats(projectID: projectID, profileID: profileID)
            // Newest first; a chat can sit in more than one lane of a project.
            var seen = Set<String>()
            chats[projectID] = rows
                .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
                .filter { seen.insert($0.id).inserted }
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = "This project's chats couldn't load. \(Self.tryAgain)"
        }
    }
}

@MainActor
protocol ProjectsSource: AnyObject {
    func details(profileID: String) async throws -> [String: ProjectsStore.Details]
    func chats(projectID: String, profileID: String) async throws -> [ProjectsStore.Chat]
}

/// Hermes's own project tree (`projects.tree`, `projects.project_sessions`),
/// through the owner-scoped project store the runtime already keeps.
@MainActor
final class LiveProjectsSource: ProjectsSource {
    private let lifecycle: ProjectLifecycleStore

    init(lifecycle: ProjectLifecycleStore) { self.lifecycle = lifecycle }

    func details(profileID: String) async throws -> [String: ProjectsStore.Details] {
        await lifecycle.load()
        guard let overview = lifecycle.overview else { throw WorkspaceClientError.invalidResponse }
        let nodes = Dictionary(overview.tree.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: ProjectsStore.Details] = [:]
        for project in overview.registeredProjects where !project.isArchived {
            let node = nodes[project.id]
            result[project.id] = .init(icon: node?.icon, color: node?.color,
                                       folders: project.folders.sorted { $0.isPrimary && !$1.isPrimary }.map(\.path),
                                       chatCount: node?.sessionCount ?? 0, lastActive: node?.lastActive)
        }
        return result
    }

    func chats(projectID: String, profileID: String) async throws -> [ProjectsStore.Chat] {
        await lifecycle.loadDetail(projectID: projectID)
        guard let detail = lifecycle.detail, detail.project.id == projectID else {
            throw WorkspaceClientError.invalidResponse
        }
        return detail.tree.repositories.flatMap(\.lanes).flatMap(\.sessions).map { session in
            .init(id: session.id, profileID: session.profileID, title: session.title,
                  preview: session.preview, lastActive: session.lastActive)
        }
    }
}

/// Demo mode: the sample projects' look and a few of the sample chats.
@MainActor
final class DemoProjectsSource: ProjectsSource {
    private let now = Date.now

    func details(profileID: String) async throws -> [String: ProjectsStore.Details] {
        [
            "loopdy": .init(icon: "🚀", color: "#7C5CFC", folders: ["~/Projects/bighelp-native"], chatCount: 3,
                            lastActive: now.addingTimeInterval(-60 * 40)),
            "home": .init(icon: "🏡", color: "#2FA37A", folders: ["~/Documents/Home", "~/Documents/Notes"],
                          chatCount: 2, lastActive: now.addingTimeInterval(-60 * 60 * 26)),
        ]
    }

    func chats(projectID: String, profileID: String) async throws -> [ProjectsStore.Chat] {
        switch projectID {
        case "loopdy":
            return [
                .init(id: "demo-project-1", profileID: profileID, title: "Plan the Projects screen",
                      preview: "Cards for each project, then its chats and folders.",
                      lastActive: now.addingTimeInterval(-60 * 40), catalogID: "demo-session-1"),
                .init(id: "demo-project-2", profileID: profileID, title: "Release notes for build 30",
                      preview: "Tables, faster alerts and widget fixes.",
                      lastActive: now.addingTimeInterval(-60 * 60 * 5), catalogID: "demo-session-2"),
                .init(id: "demo-project-3", profileID: profileID, title: "Why did the tests fail?",
                      preview: "The same ones fail on main, so nothing new broke.",
                      lastActive: now.addingTimeInterval(-60 * 60 * 30), catalogID: "demo-session-3"),
            ]
        case "home":
            return [
                .init(id: "demo-project-4", profileID: profileID, title: "Finance",
                      preview: "This month's bills and the budget sheet.",
                      lastActive: now.addingTimeInterval(-60 * 60 * 26), catalogID: "demo-finance"),
                .init(id: "demo-project-5", profileID: profileID, title: "Travel",
                      preview: "Kyoto in October: flights, the ryokan and dinner spots.",
                      lastActive: now.addingTimeInterval(-60 * 60 * 50), catalogID: "demo-travel"),
            ]
        default:
            return []
        }
    }
}
