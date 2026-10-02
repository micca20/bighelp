import SwiftUI

@MainActor
struct PluginUpdateSection: View {
    let store: PluginUpdateStore?
    let theme: BighelpTheme
    var modelNames: ModelNameCatalogStore = .shared
    @State private var confirmsUpdate = false

    var body: some View {
        Group {
            Section {
            if let store {
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    HStack {
                        Text(store.title).bighelpFont(.label, weight: .semibold)
                        if let connection = HostConnectionStatus(pluginUpdate: store) {
                            BighelpConnectionIndicator(phase: connection.phase)
                        } else if store.isWorking || store.isPending {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let message = store.message ?? store.status?.message {
                        Text(message).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let revision = store.status?.activeRevision {
                        Text("Active revision: \(revision.prefix(12))")
                            .bighelpFont(.metadata).foregroundStyle(theme.tertiaryText)
                    }
                }
                .accessibilityIdentifier("settings.plugin-update-status")
            } else {
                Text("Connect to a paired host to update its bighelp plugin.")
                    .bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
            }
            Button {
                confirmsUpdate = true
            } label: {
                Label("Update bighelp Plugin", systemImage: "arrow.down.circle")
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
            .disabled(store?.canStart != true)
            .accessibilityIdentifier("settings.update-plugin")
            if let store {
                Button {
                    Task { await store.refreshStatus() }
                } label: {
                    Label("Check Update Status", systemImage: "arrow.clockwise")
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
                .disabled(store.isWorking)
                .accessibilityIdentifier("settings.check-plugin-update")
            }
        } header: {
            Text("bighelp plugin")
        } footer: {
            Text("Updating downloads the latest plugin and restarts the connected host’s gateway. Active work may be interrupted.")
        }
        .task(id: store?.pendingOperationID) {
            if let store { await store.observe() }
        }
        .alert("Update bighelp Plugin?", isPresented: $confirmsUpdate) {
            Button("Update and Restart", role: .destructive) {
                if let store { Task { await store.start() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This downloads the latest bighelp plugin and restarts the connected host’s gateway. Active work may be interrupted. bighelp will reconnect and verify the updated plugin before reporting completion.")
        }

            Section {
                Button {
                    Task { await modelNames.refresh() }
                } label: {
                    HStack {
                        Label("Update Model Names", systemImage: "text.badge.checkmark")
                        Spacer()
                        if modelNames.isRefreshing { ProgressView() }
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
                .disabled(modelNames.isRefreshing)
                .accessibilityIdentifier("settings.update-model-names")
                if let message = modelNames.statusMessage {
                    Text(message).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("settings.model-names-status")
                }
            } header: {
                Text("Model names")
            } footer: {
                Text("Refreshes display labels only. It does not restart the host or change model assignments.")
            }
        }
        .foregroundStyle(theme.primaryText)
        .tint(theme.action)
        .listRowBackground(theme.surface)

    }
}

#if DEBUG
/// Explicit simulator fixture, never selected for a production account.
@MainActor
final class PluginUpdatePreviewClient: PluginUpdateClient {
    private var operationID: String?
    func start(operationID: String) async throws -> PluginUpdateStatus {
        self.operationID = operationID
        return value(.waitingForActivation)
    }
    func status(operationID: String?) async throws -> PluginUpdateStatus {
        value(self.operationID == nil ? .idle : .complete)
    }
    private func value(_ phase: PluginUpdateStatus.Phase) -> PluginUpdateStatus {
        .init(operationID: operationID, phase: phase,
              targetRevision: String(repeating: "a", count: 40), activeRevision: String(repeating: "a", count: 40),
              runtimeID: phase == .idle ? "fixture_old" : "fixture_restarted", message: phase.title)
    }
}
#endif
