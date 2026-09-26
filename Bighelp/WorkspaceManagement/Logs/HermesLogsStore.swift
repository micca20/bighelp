import Foundation
import Observation

@MainActor
@Observable
final class HermesLogsStore {
    let hostName: String
    let owner: WorkspaceOwner

    private(set) var entries: [HermesLogEntry] = []
    private(set) var appliedQuery: HermesLogQuery?
    private(set) var isLoading = false
    private(set) var isUnsupported = false
    private(set) var isRetired = false
    private(set) var errorMessage: String?

    var selectedFile: HermesLogFile = .agent
    var selectedLevel: HermesLogLevelFilter = .all
    var selectedComponent: HermesLogComponent = .all
    var searchText = ""

    @ObservationIgnored private let client: any HermesLogsReading
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var requestTask: Task<HermesLogPage, any Error>?

    init(hostName: String, owner: WorkspaceOwner, client: any HermesLogsReading) {
        self.hostName = hostName
        self.owner = owner
        self.client = client
    }

    var ownsScope: Bool {
        !isRetired && client.owner == owner
    }

    var hasUnappliedFilters: Bool {
        guard let appliedQuery else { return true }
        guard let draft = try? makeQuery(lineLimit: appliedQuery.lineLimit) else { return true }
        return draft != appliedQuery
    }

    var canLoadEarlier: Bool {
        !isLoading && !hasUnappliedFilters && appliedQuery.map {
            entries.count == $0.lineLimit && $0.lineLimit < HermesLogQuery.maximumLineLimit
        } == true
    }

    func refresh(resetWindow: Bool = false) async {
        guard ownsScope, !Task.isCancelled else { return }
        do {
            let limit = resetWindow ? HermesLogQuery.initialLineLimit
                : appliedQuery?.lineLimit ?? HermesLogQuery.initialLineLimit
            try await load(makeQuery(lineLimit: limit))
        } catch is CancellationError {
        } catch {
            guard ownsScope, !Task.isCancelled else { return }
            errorMessage = message(for: error)
        }
    }

    func applyFilters() async {
        await refresh(resetWindow: true)
    }

    func loadEarlier() async {
        guard ownsScope, canLoadEarlier, let current = appliedQuery else { return }
        let nextLimit = min(
            current.lineLimit + HermesLogQuery.lineStep,
            HermesLogQuery.maximumLineLimit
        )
        do {
            try await load(makeQuery(lineLimit: nextLimit))
        } catch is CancellationError {
        } catch {
            guard ownsScope, !Task.isCancelled else { return }
            errorMessage = message(for: error)
        }
    }

    func retire() {
        guard !isRetired else { return }
        isRetired = true
        generation = UUID()
        requestTask?.cancel()
        requestTask = nil
        entries = []
        appliedQuery = nil
        selectedFile = .agent
        selectedLevel = .all
        selectedComponent = .all
        searchText = ""
        isLoading = false
        isUnsupported = false
        errorMessage = nil
    }

    private func load(_ query: HermesLogQuery) async throws {
        guard ownsScope, !Task.isCancelled else { throw CancellationError() }
        let request = UUID()
        generation = request
        requestTask?.cancel()
        let task = Task { try await client.read(query) }
        requestTask = task
        isLoading = true
        isUnsupported = false
        errorMessage = nil
        defer {
            if generation == request {
                requestTask = nil
                isLoading = false
            }
        }

        do {
            let page = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard canPublish(request) else { return }
            appliedQuery = page.query
            entries = Array(page.entries.reversed())
        } catch HermesLogsClientError.unsupported {
            guard canPublish(request) else { return }
            entries = []
            appliedQuery = query
            isUnsupported = true
        } catch {
            guard canPublish(request) else { return }
            throw error
        }
    }

    private func makeQuery(lineLimit: Int) throws -> HermesLogQuery {
        try HermesLogQuery(
            file: selectedFile,
            lineLimit: lineLimit,
            level: selectedLevel,
            component: selectedComponent,
            search: searchText
        )
    }

    private func canPublish(_ request: UUID) -> Bool {
        ownsScope && generation == request && !Task.isCancelled
    }

    private func message(for error: any Error) -> String {
        if let error = error as? HermesLogsClientError { return error.localizedDescription }
        if let error = error as? WorkspaceClientError { return error.localizedDescription }
        return "Hermes could not load this bounded log window. Check the connection and refresh."
    }
}
