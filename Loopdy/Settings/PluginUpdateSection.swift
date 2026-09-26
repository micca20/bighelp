import SwiftUI

@MainActor
struct PluginUpdateSection: View {
    let store: PluginUpdateStore?
    let theme: LoopdyTheme
    var modelNames: ModelNameCatalogStore = .shared
    @State private var confirmsUpdate = false

    var body: some View {
        Group {
            Section {
            if let store {
                VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                    HStack {
                        Text(store.title).loopdyFont(.label, weight: .semibold)
                        if store.isWorking || store.isPending { ProgressView().controlSize(.small) }
                    }
                    if let message = store.message ?? store.status?.message {
                        Text(message).loopdyFont(.metadata).foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let revision = store.status?.activeRevision {
                        Text("Active revision: \(revision.prefix(12))")
                            .loopdyFont(.metadata).foregroundStyle(theme.tertiaryText)
                    }
                }
                .accessibilityIdentifier("settings.plugin-update-status")
            } else {
                Text("Connect to a paired host to update its Loopdy plugin.")
                    .loopdyFont(.metadata).foregroundStyle(theme.secondaryText)
            }
            Button {
                confirmsUpdate = true
            } label: {
                Label("Update Loopdy Plugin", systemImage: "arrow.down.circle")
                    .frame(minHeight: LoopdyTokens.hitTarget)
            }
            .disabled(store?.canStart != true)
            .accessibilityIdentifier("settings.update-plugin")
            if let store {
                Button {
                    Task { await store.refreshStatus() }
                } label: {
                    Label("Check Update Status", systemImage: "arrow.clockwise")
                        .frame(minHeight: LoopdyTokens.hitTarget)
                }
                .disabled(store.isWorking)
                .accessibilityIdentifier("settings.check-plugin-update")
            }
        } header: {
            Text("Loopdy plugin")
        } footer: {
            Text("Updating downloads the latest plugin and restarts the connected host’s gateway. Active work may be interrupted.")
        }
        .task(id: store?.pendingOperationID) {
            if let store { await store.observe() }
        }
        .alert("Update Loopdy Plugin?", isPresented: $confirmsUpdate) {
            Button("Update and Restart", role: .destructive) {
                if let store { Task { await store.start() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This downloads the latest Loopdy plugin and restarts the connected host’s gateway. Active work may be interrupted. bighelp will reconnect and verify the updated plugin before reporting completion.")
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
                    .frame(minHeight: LoopdyTokens.hitTarget)
                }
                .disabled(modelNames.isRefreshing)
                .accessibilityIdentifier("settings.update-model-names")
                if let message = modelNames.statusMessage {
                    Text(message).loopdyFont(.metadata).foregroundStyle(theme.secondaryText)
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
