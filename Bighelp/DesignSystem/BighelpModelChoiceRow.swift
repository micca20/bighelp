import SwiftUI

/// A settings row showing a chosen model (provider mark, friendly name, provider)
/// that opens the shared model picker, so every model setting looks and works
/// like the chat's model control.
struct BighelpModelChoiceRow: View {
    /// What this model is for, when a list has several (e.g. an auxiliary task).
    var label: String?
    let providerID: String
    let providerName: String
    let modelID: String
    /// Shown when no model is chosen, e.g. "Uses the default model" or "Automatic".
    var emptyTitle = "Uses the default model"
    /// An extra line under the provider, e.g. the reasoning level.
    var detail: String?
    var showsDefaultBadge = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        let isEmpty = modelID.isEmpty
        Button(action: action) {
            HStack(spacing: BighelpTokens.space12) {
                AIProviderMarkView(
                    providerID: providerID,
                    providerName: providerName,
                    context: .agentRuntimeSelection
                )
                VStack(alignment: .leading, spacing: 2) {
                    if let label {
                        Text(label)
                            .font(.bighelp(.footnote).weight(.semibold))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    Text(isEmpty ? emptyTitle : ModelNameCatalogStore.shared.displayName(for: modelID))
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(2)
                    if !isEmpty {
                        Text(providerName)
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    if let detail {
                        Text(detail)
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: BighelpTokens.space8)
                if isEmpty && showsDefaultBadge {
                    Text("Default")
                        .font(.bighelp(.caption).weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, BighelpTokens.space8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.incomingMessageBackground))
                }
                if isEnabled {
                    Text("Change")
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(theme.action)
                }
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    @BighelpThemeReader private var theme
}

extension BighelpLinkModelProvider {
    /// A Models-page provider, without models Hermes reports as unavailable.
    init(administration provider: DirectHermesModelProvider) {
        self.init(
            id: provider.id,
            name: provider.name,
            isCurrent: provider.isCurrent,
            isCustom: provider.isCustom,
            models: provider.models.filter { !provider.unavailableModels.contains($0) }
        )
    }

    init(kanban provider: HermesKanbanModelProvider) {
        self.init(id: provider.slug, name: provider.label, isCurrent: false, isCustom: false, models: provider.models)
    }
}
