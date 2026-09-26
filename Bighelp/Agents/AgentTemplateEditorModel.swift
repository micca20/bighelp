import Foundation
import Observation

@MainActor
@Observable
final class AgentTemplateEditorModel: Identifiable {
    let id = UUID()
    let source: AgentProfile
    let owner: WorkspaceOwner

    private(set) var catalog: AgentTemplateCatalog?
    private(set) var document: AgentTemplateDocument?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var confirmationMessage: String?
    var selectedSection: AgentTemplateSection = .soul

    private let client: any AgentProfileTemplateClient
    private let isCurrent: @MainActor () -> Bool
    private var baseline: AgentTemplateDocument?
    private var generation = 0

    init(source: AgentProfile, owner: WorkspaceOwner,
         client: any AgentProfileTemplateClient,
         isCurrent: @escaping @MainActor () -> Bool) {
        self.source = source
        self.owner = owner
        self.client = client
        self.isCurrent = isCurrent
    }

    var isDirty: Bool { document != nil && document != baseline }
    var canSave: Bool {
        guard let document else { return false }
        return isCurrent() && !isLoading && !isSaving && isDirty
            && !document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load() async {
        guard !isLoading, !isSaving, document == nil, isCurrent() else { return }
        let request = beginLoading()
        defer { finishLoading(request) }
        do {
            let catalog = try await client.list(profileID: source.id, owner: owner)
            try requireCurrent(request)
            guard catalog.profileID == source.id else { throw WorkspaceClientError.invalidResponse }
            self.catalog = catalog
            if let first = catalog.templates.first {
                try await open(first.id, request: request)
            } else {
                try await derive(request: request)
            }
        } catch is CancellationError {
            return
        } catch {
            publish(error, request: request)
        }
    }

    func createNew() async {
        guard !isLoading, !isSaving, !isDirty, isCurrent() else { return }
        let request = beginLoading()
        defer { finishLoading(request) }
        do {
            try await derive(request: request)
        } catch is CancellationError {
            return
        } catch {
            publish(error, request: request)
        }
    }

    func open(_ templateID: String) async {
        guard !isLoading, !isSaving, !isDirty, isCurrent(), document?.id != templateID else { return }
        let request = beginLoading()
        defer { finishLoading(request) }
        do {
            try await open(templateID, request: request)
        } catch is CancellationError {
            return
        } catch {
            publish(error, request: request)
        }
    }

    func save() async {
        guard canSave, var candidate = document else { return }
        candidate.title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.title.isEmpty else { return }
        generation += 1
        let request = generation
        isSaving = true
        errorMessage = nil
        confirmationMessage = nil
        defer { if generation == request { isSaving = false } }
        do {
            let saved = try await client.save(
                candidate, profileID: source.id,
                expectedRevision: baseline?.revision, owner: owner
            )
            try requireCurrent(request)
            guard saved.id == candidate.id, saved.sourceProfileID == source.id,
                  saved.revision != nil else { throw WorkspaceClientError.invalidResponse }
            document = saved
            baseline = saved
            confirmationMessage = "Template saved in this agent’s workspace."
            do {
                let refreshed = try await client.list(profileID: source.id, owner: owner)
                try requireCurrent(request)
                catalog = refreshed
            } catch {
                try requireCurrent(request)
                confirmationMessage = "Template saved. Reopen the editor to refresh the template list."
            }
        } catch is CancellationError {
            return
        } catch {
            publish(error, request: request)
        }
    }

    func updateTitle(_ title: String) {
        guard !isSaving else { return }
        document?.title = title
        confirmationMessage = nil
    }

    func updateSection(_ text: String) {
        guard !isSaving else { return }
        document?.setText(text, for: selectedSection)
        confirmationMessage = nil
    }

    func cancel() {
        generation += 1
        isLoading = false
        isSaving = false
    }

    private func derive(request: Int) async throws {
        let value = try await client.derive(profileID: source.id, templateID: UUID(), owner: owner)
        try requireCurrent(request)
        guard value.sourceProfileID == source.id, value.revision == nil else {
            throw WorkspaceClientError.invalidResponse
        }
        document = value
        baseline = nil
        errorMessage = nil
        confirmationMessage = nil
        selectedSection = .soul
    }

    private func open(_ templateID: String, request: Int) async throws {
        let value = try await client.read(profileID: source.id, templateID: templateID, owner: owner)
        try requireCurrent(request)
        guard value.id == templateID, value.sourceProfileID == source.id,
              value.revision != nil else { throw WorkspaceClientError.invalidResponse }
        document = value
        baseline = value
        errorMessage = nil
        confirmationMessage = nil
        selectedSection = .soul
    }

    private func beginLoading() -> Int {
        generation += 1
        isLoading = true
        errorMessage = nil
        confirmationMessage = nil
        return generation
    }

    private func finishLoading(_ request: Int) {
        if generation == request { isLoading = false }
    }

    private func requireCurrent(_ request: Int) throws {
        try Task.checkCancellation()
        guard generation == request, isCurrent() else { throw WorkspaceClientError.ownerChanged }
    }

    private func publish(_ error: any Error, request: Int) {
        guard generation == request, isCurrent() else { return }
        errorMessage = (error as? WorkspaceClientError)?.localizedDescription
            ?? "The template could not be loaded or saved. Review the selected profile’s workspace and try again."
    }
}
