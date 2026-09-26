import Observation
import SwiftUI

enum ModelAdministrationAssignmentTarget: Identifiable, Equatable {
    case main
    case auxiliary(String)

    var id: String {
        switch self {
        case .main: "main"
        case .auxiliary(let task): "auxiliary:\(task)"
        }
    }

    var title: String {
        switch self {
        case .main: "Profile Default"
        case .auxiliary(let task): task.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

@MainActor @Observable
final class ModelAdministrationStore {
    let hostName: String
    let profileID: String

    private(set) var snapshot: DirectHermesModelAdministrationSnapshot?
    private(set) var isLoading = false
    private(set) var operationTitle: String?
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    private(set) var pendingConfirmation: DirectHermesModelAssignmentConfirmation?
    private(set) var isRetired = false

    @ObservationIgnored private let client: DirectHermesModelAdministrationClient
    @ObservationIgnored private var generation = UUID()

    init(hostName: String, profileID: String, client: DirectHermesModelAdministrationClient) {
        self.hostName = hostName
        self.profileID = profileID
        self.client = client
    }

    var ownsScope: Bool { !isRetired && client.ownsScope }
    var isBusy: Bool { isLoading || operationTitle != nil }

    func load(refreshModels: Bool = false) async {
        guard ownsScope, !isBusy else { return }
        let request = UUID()
        generation = request
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { if generation == request { isLoading = false } }
        do {
            let value = try await client.loadSnapshot(
                profileID: profileID, refreshModels: refreshModels
            )
            guard ownsScope, generation == request, !Task.isCancelled else { return }
            snapshot = value
        } catch is CancellationError {
        } catch {
            guard ownsScope, generation == request else { return }
            errorMessage = Self.message(error)
        }
    }

    func refresh() async {
        isLoading = false
        await load(refreshModels: true)
    }

    func retire() {
        isRetired = true
        generation = UUID()
        snapshot = nil
        pendingConfirmation = nil
        isLoading = false
        operationTitle = nil
        errorMessage = nil
        successMessage = nil
    }

    func assign(providerID: String, modelID: String, target: ModelAdministrationAssignmentTarget) async -> Bool {
        let scope: DirectHermesModelAssignmentScope
        switch target {
        case .main: scope = .main
        case .auxiliary(let task): scope = .auxiliary(task: task)
        }
        let request = DirectHermesModelAssignmentRequest(
            scope: scope, providerID: providerID, modelID: modelID,
            reasoningEffort: nil, confirmExpensiveModel: false
        )
        guard begin("Saving model assignment") else { return false }
        defer { finish() }
        do {
            let outcome = try await client.setModel(profileID: profileID, request: request)
            guard ownsScope else { return false }
            switch outcome {
            case .applied:
                try await reloadAfterMutation(message: "Hermes confirmed the model assignment for future sessions.")
                return true
            case .confirmationRequired(let confirmation):
                pendingConfirmation = confirmation
                return false
            }
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func confirmAssignment() async -> Bool {
        guard let confirmation = pendingConfirmation, begin("Confirming model assignment") else { return false }
        pendingConfirmation = nil
        defer { finish() }
        do {
            try await client.confirmModelAssignment(profileID: profileID, confirmation: confirmation)
            guard ownsScope else { return false }
            try await reloadAfterMutation(message: "Hermes confirmed the reviewed model assignment.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func cancelAssignmentConfirmation() { pendingConfirmation = nil }

    func resetAuxiliary() async {
        let request = DirectHermesModelAssignmentRequest(
            scope: .resetAuxiliary, providerID: "auto", modelID: "",
            reasoningEffort: nil, confirmExpensiveModel: false
        )
        guard begin("Resetting auxiliary models") else { return }
        defer { finish() }
        do {
            let outcome = try await client.setModel(profileID: profileID, request: request)
            guard outcome == .applied, ownsScope else { throw WorkspaceClientError.outcomeUnknown }
            try await reloadAfterMutation(message: "Hermes reset every auxiliary task to automatic routing.")
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func saveMoA(_ configuration: DirectHermesMoAConfiguration) async -> Bool {
        guard begin("Saving Mixture of Agents") else { return false }
        defer { finish() }
        do {
            try await client.saveMoAConfiguration(profileID: profileID, configuration: configuration)
            guard ownsScope else { return false }
            try await reloadAfterMutation(message: "Hermes confirmed the complete Mixture of Agents configuration.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    private func reloadAfterMutation(message: String) async throws {
        let value = try await client.loadSnapshot(profileID: profileID)
        guard ownsScope else { throw CancellationError() }
        snapshot = value
        errorMessage = nil
        successMessage = message
    }

    private func begin(_ title: String) -> Bool {
        guard ownsScope, !isBusy else { return false }
        operationTitle = title
        errorMessage = nil
        successMessage = nil
        return true
    }

    private func finish() { operationTitle = nil }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "Hermes could not confirm this model operation. Refresh before trying it again."
    }
}

@MainActor
struct ModelAdministrationView: View {
    @State private var store: ModelAdministrationStore
    @State private var assignmentTarget: ModelAdministrationAssignmentTarget?
    @State private var confirmAuxiliaryReset = false
    let onOpenProviderAccounts: (() -> Void)?
    let onOpenAgentDefaults: (() -> Void)?

    init(
        hostName: String,
        profileID: String,
        client: DirectHermesModelAdministrationClient,
        onOpenProviderAccounts: (() -> Void)? = nil,
        onOpenAgentDefaults: (() -> Void)? = nil
    ) {
        _store = State(initialValue: ModelAdministrationStore(
            hostName: hostName, profileID: profileID, client: client
        ))
        self.onOpenProviderAccounts = onOpenProviderAccounts
        self.onOpenAgentDefaults = onOpenAgentDefaults
    }

    var body: some View {
        Group {
            if store.ownsScope {
                List {
                    scopeSection
                    statusSections
                    if let snapshot = store.snapshot {
                        mainModelSection(snapshot)
                        if let runtime = snapshot.runtime { runtimeSection(runtime) }
                        modelCapabilitiesSection(snapshot)
                        if let auxiliary = snapshot.auxiliary { auxiliarySection(auxiliary) }
                        if let moa = snapshot.moa { moaSection(moa) }
                        if let analytics = snapshot.analytics { analyticsSection(analytics) }
                        SkippedPartsNote(parts: snapshot.skippedParts)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await store.refresh() }
            } else {
                ContentUnavailableView(
                    "Models unavailable", systemImage: "cpu",
                    description: Text("The selected host changed. Reopen Models from the current workspace.")
                )
            }
        }
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.snapshot == nil { await store.load() } }
        .sheet(item: $assignmentTarget) { target in
            NavigationStack {
                ModelAdministrationSelectionView(store: store, target: target)
            }
        }
        .confirmationDialog("Reset every auxiliary assignment?", isPresented: $confirmAuxiliaryReset, titleVisibility: .visible) {
            Button("Reset to Automatic", role: .destructive) { Task { await store.resetAuxiliary() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will explicitly set every auxiliary task to automatic routing. Main and MoA assignments are not changed.")
        }
        .accessibilityIdentifier("models.administration")
    }

    private var scopeSection: some View {
        Section {
            LabeledContent("Host", value: store.hostName)
            LabeledContent("Profile", value: store.profileID)
        } header: {
            Text("Applies to")
        } footer: {
            Text("Assignments affect future sessions. Change a running chat from its model control.")
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if store.isLoading || store.operationTitle != nil {
            Section { ProgressView(store.operationTitle ?? "Loading model administration") }
        }
        if let error = store.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Refresh") { Task { await store.load() } }.disabled(store.isBusy)
            }
            .accessibilityIdentifier("models.error")
        }
        if let success = store.successMessage {
            Section { Label(success, systemImage: "checkmark.circle") }
                .accessibilityIdentifier("models.confirmed")
        }
    }

    private func runtimeSection(_ runtime: DirectHermesRuntimeStatus) -> some View {
        Section("Readiness") {
            LabeledContent("New sessions", value: runtime.isUsable ? "Ready" : "Needs attention")
            if let source = runtime.source { LabeledContent("Credential source", value: source) }
            if let message = runtime.errorMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if let onOpenProviderAccounts {
                Button("Manage provider accounts", action: onOpenProviderAccounts)
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
        }
    }

    private func mainModelSection(_ snapshot: DirectHermesModelAdministrationSnapshot) -> some View {
        Section("New chats") {
            LabeledContent("Effective provider", value: snapshot.info.providerID.isEmpty ? "Not configured" : snapshot.info.providerID)
            LabeledContent("Effective model", value: snapshot.info.modelID.isEmpty ? "Not configured" : snapshot.info.modelID)
            if snapshot.info.effectiveContextLength > 0 {
                LabeledContent("Context", value: snapshot.info.effectiveContextLength.formatted())
            }

            if let recommendation = snapshot.recommendation, !recommendation.modelID.isEmpty,
               recommendation.modelID != snapshot.info.modelID {
                Text("Recommended for \(recommendation.providerID): \(recommendation.modelID)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Choose profile default") { assignmentTarget = .main }
                .disabled(store.isBusy || snapshot.providers.isEmpty)
                .frame(minHeight: BighelpTokens.hitTarget)
            if let onOpenAgentDefaults {
                Button("Agent runtime defaults", action: onOpenAgentDefaults)
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
        }
    }

    @ViewBuilder
    private func modelCapabilitiesSection(_ snapshot: DirectHermesModelAdministrationSnapshot) -> some View {
        let caps = snapshot.info.capabilities
        if caps.supportsTools != nil || caps.supportsVision != nil || caps.supportsReasoning != nil {
            Section("Advanced · Capabilities") {
                if let tools = caps.supportsTools { LabeledContent("Tools", value: tools ? "Supported" : "Not reported") }
                if let vision = caps.supportsVision { LabeledContent("Vision", value: vision ? "Supported" : "Not reported") }
                if let reasoning = caps.supportsReasoning { LabeledContent("Reasoning", value: reasoning ? "Supported" : "Not reported") }
            }
        }
    }

    private func auxiliarySection(_ auxiliary: DirectHermesAuxiliaryModels) -> some View {
        Section {
            ForEach(auxiliary.tasks) { task in
                Button {
                    assignmentTarget = .auxiliary(task.task)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.task.replacingOccurrences(of: "_", with: " ").capitalized)
                            Text(task.providerID == "auto" ? "Automatic" : "\(task.providerID) · \(task.modelID)")
                                .font(.caption).foregroundStyle(.secondary)
                            if task.isLocalEndpoint { Text("Local endpoint").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle()).frame(minHeight: BighelpTokens.hitTarget)
                }
                .buttonStyle(.plain)
                .disabled(store.isBusy)
                .accessibilityIdentifier("models.auxiliary.\(task.task)")
            }
            Button("Reset all auxiliary tasks", role: .destructive) { confirmAuxiliaryReset = true }
                .disabled(store.isBusy)
        } header: { Text("Advanced · Auxiliary tasks") } footer: {
            Text("Reset is explicit; leaving an assignment out does not clear its saved Hermes override.")
        }
    }

    private func moaSection(_ configuration: DirectHermesMoAConfiguration) -> some View {
        Section("Advanced · Mixture of Agents") {
            LabeledContent("Default preset", value: configuration.defaultPreset)
            LabeledContent("Presets", value: configuration.presets.count.formatted())
            NavigationLink("Edit model assignments") {
                ModelAdministrationMoAView(store: store, initial: configuration)
            }
            .disabled(store.isBusy)
            if !configuration.privacyFilter.isEmpty {
                Label("This host has a MoA privacy-filter override. The pinned write API cannot preserve it, so bighelp keeps this page read-only.", systemImage: "lock")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func analyticsSection(_ analytics: DirectHermesModelAnalytics) -> some View {
        Section("Usage · Last \(analytics.periodDays) days") {
            LabeledContent("Sessions", value: analytics.totals.sessions.formatted())
            LabeledContent("Models used", value: analytics.totals.distinctModels.formatted())
            LabeledContent("API calls", value: analytics.totals.apiCalls.formatted())
            LabeledContent("Estimated cost", value: analytics.totals.estimatedCost.formatted(.currency(code: "USD")))
            ForEach(analytics.rows.prefix(20)) { row in
                DisclosureGroup("\(row.providerID.isEmpty ? "Provider" : row.providerID) · \(row.modelID)") {
                    LabeledContent("Sessions", value: row.sessions.formatted())
                    LabeledContent("Input tokens", value: row.inputTokens.formatted())
                    LabeledContent("Output tokens", value: row.outputTokens.formatted())
                    LabeledContent("API calls", value: row.apiCalls.formatted())
                    LabeledContent("Estimated cost", value: row.estimatedCost.formatted(.currency(code: "USD")))
                    if let date = row.lastUsedAt { LabeledContent("Last used", value: date.formatted()) }
                }
            }
            if analytics.rows.count > 20 {
                Text("Showing the 20 most-used model routes.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private struct ModelAdministrationSelectionView: View {
    let store: ModelAdministrationStore
    let target: ModelAdministrationAssignmentTarget
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var providers: [DirectHermesModelProvider] { store.snapshot?.providers ?? [] }

    var body: some View {
        List {
            currentAssignmentSection
            ForEach(providers) { provider in
                let models = provider.models.filter {
                    !provider.unavailableModels.contains($0)
                        && (search.isEmpty || $0.localizedCaseInsensitiveContains(search)
                            || provider.name.localizedCaseInsensitiveContains(search))
                }
                if !models.isEmpty {
                    Section(provider.name) {
                        ForEach(models, id: \.self) { model in
                            Button(model) {
                                Task {
                                    if await store.assign(providerID: provider.id, modelID: model, target: target) {
                                        dismiss()
                                    }
                                }
                            }
                            .disabled(store.isBusy)
                        }
                    }
                }
            }
        }
        .navigationTitle(target.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search models")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .confirmationDialog(
            "Confirm model cost?", isPresented: Binding(
                get: { store.pendingConfirmation != nil },
                set: { if !$0 { store.cancelAssignmentConfirmation() } }
            ), titleVisibility: .visible
        ) {
            Button("Confirm assignment") {
                Task { if await store.confirmAssignment() { dismiss() } }
            }
            Button("Cancel", role: .cancel) { store.cancelAssignmentConfirmation() }
        } message: {
            Text(store.pendingConfirmation?.message ?? "Review this model assignment before continuing.")
        }
    }

    @ViewBuilder
    private var currentAssignmentSection: some View {
        if let snapshot = store.snapshot {
            Section("Current") {
                switch target {
                case .main:
                    LabeledContent("Provider", value: snapshot.info.providerID.isEmpty ? "Not configured" : snapshot.info.providerID)
                    LabeledContent("Model", value: snapshot.info.modelID.isEmpty ? "Not configured" : snapshot.info.modelID)
                case .auxiliary(let taskName):
                    if let task = snapshot.auxiliary?.tasks.first(where: { $0.task == taskName }) {
                        if task.providerID == "auto" {
                            LabeledContent("Routing", value: "Automatic")
                        } else {
                            LabeledContent("Provider", value: task.providerID)
                            LabeledContent("Model", value: task.modelID)
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private struct ModelAdministrationMoAView: View {
    let store: ModelAdministrationStore
    @State private var configuration: DirectHermesMoAConfiguration
    @State private var confirmSave = false
    @Environment(\.dismiss) private var dismiss

    init(store: ModelAdministrationStore, initial: DirectHermesMoAConfiguration) {
        self.store = store
        _configuration = State(initialValue: initial)
    }

    private var providers: [DirectHermesModelProvider] {
        (store.snapshot?.providers ?? []).filter { $0.id.lowercased() != "moa" && !$0.models.isEmpty }
    }

    var body: some View {
        Form {
            Section {
                Picker("Default preset", selection: $configuration.defaultPreset) {
                    ForEach(configuration.presets) { Text($0.name).tag($0.name) }
                }
                Picker("Active preset", selection: $configuration.activePreset) {
                    Text("Default").tag("")
                    ForEach(configuration.presets) { Text($0.name).tag($0.name) }
                }
            } header: {
                Text("Preset routing")
            } footer: {
                Text("All visible preset fields are round-tripped together. Hidden host overrides outside this typed document are not cleared.")
            }

            ForEach(configuration.presets.indices, id: \.self) { presetIndex in
                Section(configuration.presets[presetIndex].name) {
                    Toggle("Enabled", isOn: $configuration.presets[presetIndex].isEnabled)
                    Picker("Fan-out", selection: Binding(
                        get: { configuration.presets[presetIndex].fanout ?? "user_turn" },
                        set: { configuration.presets[presetIndex].fanout = $0 }
                    )) {
                        Text("Once per user turn").tag("user_turn")
                        Text("Every tool iteration").tag("per_iteration")
                    }
                    Picker("Failed reference policy", selection: $configuration.presets[presetIndex].degradedReferencePolicy) {
                        Text("Report failures").tag("loud")
                        Text("Continue silently").tag("silent")
                    }
                    ForEach(configuration.presets[presetIndex].referenceModels.indices, id: \.self) { referenceIndex in
                        DisclosureGroup("Reference \(referenceIndex + 1)") {
                            moaSlotEditor(slot: $configuration.presets[presetIndex].referenceModels[referenceIndex], allowsDisable: true)
                            if configuration.presets[presetIndex].referenceModels.count > 1 {
                                Button("Remove reference", role: .destructive) {
                                    configuration.presets[presetIndex].referenceModels.remove(at: referenceIndex)
                                }
                            }
                        }
                    }
                    Button("Add reference model", systemImage: "plus") {
                        if let provider = providers.first, let model = provider.models.first {
                            configuration.presets[presetIndex].referenceModels.append(.init(
                                providerID: provider.id, modelID: model,
                                reasoningEffort: nil, isEnabled: true
                            ))
                        }
                    }
                    .disabled(providers.isEmpty || configuration.presets[presetIndex].referenceModels.count >= 32)
                    DisclosureGroup("Aggregator") {
                        moaSlotEditor(slot: $configuration.presets[presetIndex].aggregator, allowsDisable: false)
                    }
                }
            }

            if !configuration.privacyFilter.isEmpty {
                Section {
                    Label("Saving is unavailable because this host's MoA privacy filter cannot be represented by the pinned write API without resetting it.", systemImage: "lock")
                }
            }
            Section {
                Button("Review Mixture of Agents changes") { confirmSave = true }
                    .disabled(store.isBusy || !configuration.privacyFilter.isEmpty || providers.isEmpty)
            }
        }
        .navigationTitle("Mixture of Agents")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Save all MoA preset assignments?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Save") {
                let submitted = configuration
                Task { if await store.saveMoA(submitted) { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will validate and replace the typed MoA preset document for this profile. This can change model spend for future MoA runs.")
        }
    }

    @ViewBuilder
    private func moaSlotEditor(slot: Binding<DirectHermesMoAModelSlot>, allowsDisable: Bool) -> some View {
        if allowsDisable { Toggle("Use this reference", isOn: slot.isEnabled) }
        Picker("Provider", selection: slot.providerID) {
            ForEach(providers) { Text($0.name).tag($0.id) }
        }
        .onChange(of: slot.wrappedValue.providerID) { _, providerID in
            guard let provider = providers.first(where: { $0.id == providerID }),
                  !provider.models.contains(slot.wrappedValue.modelID),
                  let model = provider.models.first else { return }
            slot.wrappedValue.modelID = model
        }
        Picker("Model", selection: slot.modelID) {
            if let provider = providers.first(where: { $0.id == slot.wrappedValue.providerID }) {
                ForEach(provider.models.filter { !provider.unavailableModels.contains($0) }, id: \.self) {
                    Text($0).tag($0)
                }
            }
        }
    }
}
