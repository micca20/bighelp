import SwiftUI

@MainActor
struct AgentRuntimeDefaultsSection: View {
    @Bindable var model: AgentRuntimeDefaultsEditorModel
    var allowsEdits = true
    var scopes: [AgentRuntimeScope] = AgentRuntimeScope.allCases

    @Binding var modelPickerScope: AgentRuntimeScope?

    var body: some View {
        Group {
            if model.isLoading {
                Section {
                    ProgressView("Loading model settings…")
                } header: {
                    AgentStudioCaption(statusCaption)
                }
                .listRowBackground(theme.surface)
                .accessibilityIdentifier("agent.runtime.loading")
            } else if !model.hasLoaded {
                Section {
                    recoveryMessage(
                        model.errorMessage
                            ?? "We couldn’t load this agent’s model defaults. Try again."
                    )
                    Button("Try again") {
                        Task { await model.load() }
                    }
                    .foregroundStyle(theme.action)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("agent.runtime.retry")
                } header: {
                    AgentStudioCaption(statusCaption)
                }
                .listRowBackground(theme.surface)
            } else {
                if let errorMessage = model.errorMessage {
                    Section {
                        recoveryMessage(errorMessage)
                    }
                    .listRowBackground(theme.surface)
                }
                ForEach(scopes) { scope in
                    scopeSection(scope)
                }
            }
        }
        .task {
            guard !model.hasLoaded, !model.isLoading else { return }
            await model.load()
        }
        .onChange(of: allowsEdits) { _, canEdit in
            if !canEdit {
                modelPickerScope = nil
            }
        }
    }

    private func scopeSection(_ scope: AgentRuntimeScope) -> some View {
        let selection = model.draft[scope]
        let usesDefault = selection.modelID.isEmpty
        let isEditable = allowsEdits && !model.providers.isEmpty && model.support.modelUnavailableReasons[scope] == nil
        return Section {
                Button {
                    modelPickerScope = scope
                } label: {
                    HStack(spacing: BighelpTokens.space12) {
                        AIProviderMarkView(
                            providerID: selection.providerID,
                            providerName: providerName(for: selection.providerID),
                            context: .agentRuntimeSelection
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(usesDefault ? "Uses the default model" : "Uses \(modelName(for: selection))")
                                .font(.body)
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(2)
                            if !usesDefault {
                                Text(providerName(for: selection.providerID))
                                    .font(.footnote)
                                    .foregroundStyle(theme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: BighelpTokens.space8)
                        if usesDefault {
                            Text("Default")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.secondaryText)
                                .padding(.horizontal, BighelpTokens.space8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(theme.incomingMessageBackground))
                        }
                        if isEditable {
                            Text("Change")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(theme.action)
                        }
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!isEditable)
                .accessibilityLabel("Choose provider and model for \(scope.title)")
                .accessibilityValue(modelLabel(for: selection))
                .accessibilityIdentifier("agent.runtime.\(scope.rawValue).model")
                if let reason = model.support.modelUnavailableReasons[scope] {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.support.reasoningUnavailableReasons[scope] != nil {
                    LabeledContent("Reasoning", value: "Inherited")
                        .accessibilityIdentifier("agent.runtime.\(scope.rawValue).reasoning")
                } else {
                    Picker("Reasoning", selection: Binding(
                        get: { model.draft[scope].reasoningEffort },
                        set: { model.selectReasoning($0, for: scope) }
                    )) {
                        ForEach(AgentReasoningOption.all, id: \.value) { option in
                            Text(option.title).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(theme.action)
                    .disabled(!allowsEdits || model.support.reasoningUnavailableReasons[scope] != nil)
                    .accessibilityIdentifier("agent.runtime.\(scope.rawValue).reasoning")
                }
                if let reason = model.support.reasoningUnavailableReasons[scope] ?? model.support.reasoningNotes[scope] {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("agent.runtime.\(scope.rawValue).reasoning-note")
                }
        } header: {
            AgentStudioCaption(scope == .mainChats ? "Model" : scope.title)
        } footer: {
            Text(scope.detail)
        }
        .listRowBackground(theme.surface)
    }

    private var statusCaption: String {
        scopes.contains(.mainChats) ? "Model" : "Subagent and task models"
    }

    private func providerName(for providerID: String) -> String {
        model.providers.first(where: { $0.id == providerID })?.name
            ?? (providerID.isEmpty ? "Hermes" : providerID)
    }

    private func modelName(for selection: AgentRuntimeSelection) -> String {
        ModelNameCatalogStore.shared.displayName(for: selection.modelID)
    }

    private func modelLabel(for selection: AgentRuntimeSelection) -> String {
        guard !selection.modelID.isEmpty else { return "Default model" }
        return "\(modelName(for: selection)) · \(providerName(for: selection.providerID))"
    }

    private func recoveryMessage(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .bighelpFont(.metadata)
            .foregroundStyle(theme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }

    @BighelpThemeReader private var theme
}
