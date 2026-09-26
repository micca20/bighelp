import SwiftUI

@MainActor
struct WorkspaceCredentialsSection: View {
    let store: WorkspaceManagementStore
    let credentials: [WorkspaceCredentialStatus]

    private var rows: [WorkspaceCredentialStatus] {
        credentials.filter { store.matches($0.id, $0.description, $0.category) }
    }

    var body: some View {
        Section("Credentials") {
            Text("Only credential presence is shown. Values are never revealed. A saved key is not proof that a provider account works.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(Array(rows.prefix(store.visibleLimit))) { credential in
                NavigationLink {
                    WorkspaceCredentialDetailView(store: store, credentialID: credential.id)
                } label: {
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text(credential.id).font(.callout)
                        Label(credential.isSet ? "Set on host" : "Not set",
                            systemImage: credential.isSet ? "key.fill" : "key")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
                .accessibilityIdentifier("workspace.credential.\(credential.id)")
            }
            if rows.isEmpty { Text("No matching credentials.").foregroundStyle(.secondary) }
            if rows.count > store.visibleLimit {
                Button("Show more credentials") { store.loadMore() }.frame(minHeight: BighelpTokens.hitTarget)
            }
        }
    }
}

@MainActor
struct WorkspaceCredentialDetailView: View {
    let store: WorkspaceManagementStore
    let credentialID: String
    @State private var replacement = ""

    private var credential: WorkspaceCredentialStatus? {
        guard store.ownsScope, case .credentials(let keys) = store.content else { return nil }
        return keys.first { $0.id == credentialID }
    }

    var body: some View {
        Form {
            WorkspaceManagementStatusSection(store: store)
            if let credential {
                Section("Credential") {
                    Text(credential.description)
                    LabeledContent("Presence", value: credential.isSet ? "Set on host" : "Not set")
                    LabeledContent("Category", value: credential.category)
                }
                if credential.canReplace && store.canEdit {
                    Section("Write-only replacement") {
                        SecureField("New credential", text: $replacement)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                            .accessibilityIdentifier("workspace.credential.replacement")
                        Button("Review replacement") {
                            store.review = .replaceCredential(key: credential.id, value: replacement)
                            replacement = ""
                        }
                        .disabled(replacement.isEmpty || replacement.utf8.count > 8_192)
                        .frame(minHeight: BighelpTokens.hitTarget)
                    }
                } else {
                    Text("Manage this credential through its Hermes connection setup. This page does not reveal or remove it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("This credential is no longer available in the selected workspace.")
            }
        }
        .navigationTitle("Credential")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { replacement = "" }
        .onChange(of: store.ownsScope) { _, current in if !current { replacement = "" } }
    }
}

@MainActor
struct WorkspaceMutationReviewView: View {
    let store: WorkspaceManagementStore
    let mutation: WorkspaceManagementMutation

    var body: some View {
        NavigationStack {
            Form {
                Section("Review") {
                    LabeledContent("Host", value: store.hostName)
                    LabeledContent("Profile", value: store.profileName)
                    Text(mutation.reviewMessage).fixedSize(horizontal: false, vertical: true)
                }
                Section("Confirm") {
                    Button("Confirm change") { Task { await store.confirmReview(expected: mutation) } }
                        .disabled(!store.canEdit)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .accessibilityIdentifier("workspace.mutation.confirm")
                    Button("Cancel", role: .cancel) { store.review = nil }
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
            }
            .navigationTitle(mutation.reviewTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.review = nil }
                }
            }
        }
    }
}
