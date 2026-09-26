import SwiftUI

struct BighelpCardCatalogView: View {
    typealias InstallAction = @MainActor (BighelpCardCatalogEntry) async throws -> Void
    typealias RemoveAction = @MainActor (String) async throws -> Void

    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private let client: BighelpCardCatalogClient
    private let installAction: InstallAction
    private let removeAction: RemoveAction

    @State private var loadState: LoadState = .loading
    @State private var entries: [BighelpCardCatalogEntry] = []
    @State private var query = ""
    @State private var selectedID: String?
    @State private var installedVersions: [String: Int]

    init(
        client: BighelpCardCatalogClient,
        installedVersions: [String: Int] = [:],
        installAction: @escaping InstallAction,
        removeAction: @escaping RemoveAction
    ) {
        self.client = client
        self.installAction = installAction
        self.removeAction = removeAction
        _installedVersions = State(initialValue: installedVersions)
    }

    var body: some View {
        NavigationSplitView {
            Group {
                switch loadState {
                case .loading:
                    ProgressView("Loading card catalog…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Catalog unavailable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again", action: reload)
                    }
                case .loaded where filteredEntries.isEmpty:
                    ContentUnavailableView(
                        "No card templates found",
                        systemImage: "magnifyingglass",
                        description: Text("Try another name, author, or description.")
                    )
                case .loaded:
                    templateList
                }
            }
            .navigationTitle("Card Catalog")
            .searchable(text: $query, prompt: "Search Card Catalog")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh catalog", systemImage: "arrow.clockwise", action: reload)
                        .labelStyle(.iconOnly)
                }
            }
            .accessibilityIdentifier("catalog.sidebar")
        } detail: {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    if let selectedEntry {
                        BighelpCardTemplateDetailView(
                            entry: selectedEntry,
                            installedVersion: installedVersions[selectedEntry.id],
                            installAction: {
                                try await installAction(selectedEntry)
                                installedVersions[selectedEntry.id] = selectedEntry.version
                            },
                            removeAction: {
                                try await removeAction(selectedEntry.id)
                                installedVersions[selectedEntry.id] = nil
                            }
                        )
                    } else {
                        ContentUnavailableView(
                            "Choose a card template",
                            systemImage: "rectangle.stack",
                            description: Text("Review its preview and permissions before installing.")
                        )
                    }
                }
                .frame(maxWidth: 760, maxHeight: .infinity)
                .accessibilityIdentifier("catalog.detail-column")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityIdentifier("catalog.screen")
        .task { await load() }
    }

    private var templateList: some View {
        List(filteredEntries, selection: $selectedID) { entry in
            NavigationLink(value: entry.id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .font(.headline)
                    Text(entry.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    HStack(spacing: 8) {
                        Text(entry.author)
                        Text("Version \(entry.version)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("catalog.template.\(entry.id)")
            .accessibilityLabel("\(entry.name), \(entry.author), Version \(entry.version)")
        }
        .listStyle(.sidebar)
    }

    private var filteredEntries: [BighelpCardCatalogEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.name, entry.summary, entry.author]
                .contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    private var selectedEntry: BighelpCardCatalogEntry? {
        guard let selectedID else { return nil }
        return entries.first { $0.id == selectedID }
    }

    private func reload() {
        Task { await load() }
    }

    @MainActor
    private func load() async {
        loadState = .loading
        do {
            let snapshot = try await client.load()
            entries = snapshot.entries
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }
}

extension BighelpCardCatalogView {
    static func storeBacked(
        client: BighelpCardCatalogClient,
        store: BighelpCardTemplateStore
    ) throws -> Self {
        let installedVersions = Dictionary(
            uniqueKeysWithValues: try store.installedTemplates().map { ($0.id, $0.version) }
        )
        return Self(
            client: client,
            installedVersions: installedVersions,
            installAction: { entry in try store.install(entry.template) },
            removeAction: { id in try store.remove(id: id) }
        )
    }

    /// A fully local composition for previews and UI tests. It performs no network request.
    static func fixture(
        indexURL: URL,
        cacheURL: URL,
        installedVersions: [String: Int] = [:],
        installAction: @escaping InstallAction = { _ in },
        removeAction: @escaping RemoveAction = { _ in }
    ) -> Self {
        precondition(indexURL.isFileURL, "Fixture catalogs must use a local file URL.")
        return Self(
            client: BighelpCardCatalogClient(
                indexURL: indexURL,
                pinnedPublicKey: BighelpCardCatalogClient.fixturePinnedPublicKey,
                supportedBighelpVersion: "1.0.0",
                supportedCardVersion: 1,
                cacheURL: cacheURL
            ),
            installedVersions: installedVersions,
            installAction: installAction,
            removeAction: removeAction
        )
    }
}
