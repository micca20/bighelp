import Foundation
import Observation

@MainActor
@Observable
final class AgentRuntimeDefaultsEditorModel {
    private(set) var draft = AgentRuntimeDefaults.automatic
    private(set) var providers: [BighelpLinkModelProvider] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var support: AgentRuntimeDefaultsSupport = .all
    private(set) var pendingConfirmation: AgentRuntimeDefaultsSaveConfirmation?

    let agentID: String

    private let client: any AgentRuntimeDefaultsClient
    private let retryDelays: [Duration]
    private var persisted = AgentRuntimeDefaults.automatic
    private var loadGeneration = 0

    init(
        agentID: String,
        client: any AgentRuntimeDefaultsClient,
        retryDelays: [Duration] = [.seconds(1), .seconds(3)]
    ) {
        self.agentID = agentID
        self.client = client
        self.retryDelays = retryDelays
    }

    var isDirty: Bool { hasLoaded && draft != persisted }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        for attempt in 0...retryDelays.count {
            do {
                let catalog = try await client.loadCatalog(agentID: agentID)
                guard generation == loadGeneration else { return }
                persisted = catalog.defaults
                draft = catalog.defaults
                providers = catalog.providers
                support = catalog.support
                hasLoaded = true
                return
            } catch is CancellationError {
                return
            } catch {
                guard generation == loadGeneration else { return }
                guard attempt < retryDelays.count else {
                    errorMessage = "We couldn’t load this agent’s model defaults. Try again."
                    return
                }
                do {
                    try await Task.sleep(for: retryDelays[attempt])
                } catch {
                    return
                }
            }
        }
    }

    func refreshProviders() async {
        do {
            providers = try await client.refreshModelProviders(agentID: agentID)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = "We couldn’t refresh this agent’s models. Try again."
        }
    }

    func selectModel(
        providerID: String,
        modelID: String,
        for scope: AgentRuntimeScope
    ) {
        guard support.modelUnavailableReasons[scope] == nil else {
            errorMessage = support.modelUnavailableReasons[scope]
            return
        }
        guard
            let provider = providers.first(where: { $0.id == providerID }),
            provider.models.contains(modelID)
        else {
            errorMessage = "That model or reasoning level is no longer available."
            return
        }
        draft[scope].providerID = providerID
        draft[scope].modelID = modelID
        errorMessage = nil
    }

    func selectReasoning(_ value: String, for scope: AgentRuntimeScope) {
        guard support.reasoningUnavailableReasons[scope] == nil else {
            errorMessage = support.reasoningUnavailableReasons[scope]
            return
        }
        guard AgentReasoningOption.all.contains(where: { $0.value == value }) else {
            errorMessage = "That model or reasoning level is no longer available."
            return
        }
        draft[scope].reasoningEffort = value
        errorMessage = nil
    }

    func saveIfNeeded() async throws {
        guard !isSaving else { throw WorkspaceClientError.conflict }
        guard isDirty else { return }
        isSaving = true
        errorMessage = nil
        let submitted = draft
        defer { isSaving = false }
        do {
            try await client.saveDefaults(submitted, agentID: agentID)
            persisted = submitted
            pendingConfirmation = nil
        } catch let required as AgentRuntimeDefaultsConfirmationRequired {
            pendingConfirmation = required.confirmation
            throw required
        } catch let partial as AgentRuntimeDefaultsPartialSaveError {
            adoptPartial(partial.committed, submitted: submitted)
            throw partial
        } catch {
            errorMessage = (error as? WorkspaceClientError)?.localizedDescription
                ?? "We couldn’t save these agent defaults. Your choices are still here."
            throw error
        }
    }

    func confirmPendingSave() async throws {
        guard let confirmation = pendingConfirmation,
              confirmation.agentID == agentID, confirmation.defaults == draft,
              let confirming = client as? any AgentRuntimeDefaultsConfirmingClient else {
            pendingConfirmation = nil
            errorMessage = "The choices changed. Save again to review the current request."
            throw WorkspaceClientError.conflict
        }
        pendingConfirmation = nil
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await confirming.saveDefaults(confirmation.defaults, agentID: agentID, confirmation: confirmation)
            persisted = confirmation.defaults
        } catch let partial as AgentRuntimeDefaultsPartialSaveError {
            adoptPartial(partial.committed, submitted: confirmation.defaults)
            throw partial
        } catch {
            errorMessage = "These defaults could not be confirmed. Your choices are still here."
            throw error
        }
    }

    func dismissConfirmation() { pendingConfirmation = nil }

    private func adoptPartial(_ committed: AgentRuntimeDefaults, submitted: AgentRuntimeDefaults) {
        for scope in AgentRuntimeScope.allCases {
            if submitted[scope].providerID == persisted[scope].providerID,
               draft[scope].providerID == submitted[scope].providerID {
                draft[scope].providerID = committed[scope].providerID
            }
            if submitted[scope].modelID == persisted[scope].modelID,
               draft[scope].modelID == submitted[scope].modelID {
                draft[scope].modelID = committed[scope].modelID
            }
            if submitted[scope].reasoningEffort == persisted[scope].reasoningEffort,
               draft[scope].reasoningEffort == submitted[scope].reasoningEffort {
                draft[scope].reasoningEffort = committed[scope].reasoningEffort
            }
        }
        persisted = committed
        errorMessage = "Some defaults were saved, but the full change was not confirmed. Your remaining choices are still here."
    }

    func clearError() {
        errorMessage = nil
    }
}
