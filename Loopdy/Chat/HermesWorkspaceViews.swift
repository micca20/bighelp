import SwiftUI

@MainActor
struct HermesWorkspacePickerView: View {
    let store: HermesWorkspaceStore
    let agentID: String
    let sessionID: String?
    let onSelected: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(
        store: HermesWorkspaceStore,
        agentID: String,
        sessionID: String? = nil,
        onSelected: (() -> Void)? = nil
    ) {
        self.store = store
        self.agentID = agentID
        self.sessionID = sessionID
        self.onSelected = onSelected
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                HermesWorkspaceManagerContent(
                    store: store,
                    agentID: agentID,
                    sessionID: sessionID
                ) {
                    onSelected?()
                    dismiss()
                }
                .padding(.horizontal, LoopdyTokens.space20)
                .padding(.vertical, LoopdyTokens.space16)
            }
            .scrollIndicators(.hidden)
            .background(LoopdyThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: "\(agentID)|\(sessionID ?? "none")") {
            await store.load(agentID: agentID, sessionID: sessionID)
        }
        .accessibilityIdentifier("hermes-workspaces.screen")
    }

    @LoopdyThemeReader private var theme: LoopdyTheme

}

@MainActor
struct HermesWorkspaceManagerContent: View {
    let store: HermesWorkspaceStore
    let agentID: String
    let sessionID: String?
    let onSelected: () -> Void

    @State private var isCreatePresented = false
    @State private var workspacePendingArchive: HermesWorkspaceSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space12) {
            HStack(spacing: LoopdyTokens.space8) {
                Text("Manage Workspaces")
                    .loopdyFont(.sectionTitle)
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: LoopdyTokens.space8)
                LoopdyHeaderActionButton(
                    systemImage: "plus",
                    accessibilityLabel: "New Workspace"
                ) {
                    isCreatePresented = true
                }
                .accessibilityIdentifier("hermes-workspaces.create")
            }

            HermesWorkspaceRows(
                store: store,
                agentID: agentID,
                sessionID: sessionID,
                onSelected: onSelected,
                onArchive: { workspacePendingArchive = $0 }
            )
        }
        .sheet(isPresented: $isCreatePresented) {
            HermesWorkspaceCreateView(store: store, agentID: agentID)
        }
        .confirmationDialog(
            workspacePendingArchive.map { "Archive \($0.name)?" } ?? "Archive Workspace?",
            isPresented: Binding(
                get: { workspacePendingArchive != nil },
                set: { if !$0 { workspacePendingArchive = nil } }
            ),
            titleVisibility: .visible,
            presenting: workspacePendingArchive
        ) { workspace in
            Button("Archive Workspace", role: .destructive) {
                workspacePendingArchive = nil
                Task { await store.archive(id: workspace.id, agentID: agentID) }
            }
            Button("Cancel", role: .cancel) {
                workspacePendingArchive = nil
            }
        } message: { _ in
            Text("This archives the Workspace registration. Its remote folders and files are not deleted.")
        }
    }

    @LoopdyThemeReader private var theme: LoopdyTheme

}

@MainActor
struct HermesWorkspaceRows: View {
    let store: HermesWorkspaceStore
    let agentID: String
    let sessionID: String?
    let onSelected: () -> Void
    let onArchive: (HermesWorkspaceSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
            if store.isLoading, store.catalog == nil {
                LoopdyThinkingOrb(
                    scenario: .searching,
                    visibleLabel: "Loading Workspaces"
                )
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if let catalog = store.catalog, catalog.workspaces.isEmpty {
                ContentUnavailableView(
                    "No Workspaces",
                    systemImage: "square.stack.3d.up",
                    description: Text("Create a Workspace on your Hermes host, then try again.")
                )
            } else if let catalog = store.catalog {
                ForEach(catalog.workspaces) { workspace in
                    let isSelected = HermesWorkspaceSelectionPresentation.isSelected(
                        workspace,
                        store: store,
                        sessionID: sessionID
                    )
                    HStack(spacing: LoopdyTokens.space4) {
                        Button {
                            Task {
                                if await store.select(
                                    id: workspace.id,
                                    agentID: agentID,
                                    sessionID: sessionID
                                ) {
                                    onSelected()
                                }
                            }
                        } label: {
                            workspaceRow(workspace)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.selectingID != nil || store.archivingID != nil)
                        .accessibilityValue(isSelected ? "Selected" : "Not selected")
                        .accessibilityIdentifier("hermes-workspace.\(workspace.id)")

                        Button {
                            onArchive(workspace)
                        } label: {
                            if store.archivingID == workspace.id {
                                LoopdyThinkingOrb(scenario: .working, scale: .inline)
                                    .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                            } else {
                                Image(systemName: "archivebox")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(theme.secondaryText)
                                    .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(store.selectingID != nil || store.archivingID != nil || store.isCreating)
                        .accessibilityLabel("Archive \(workspace.name)")
                        .accessibilityIdentifier("hermes-workspace.archive.\(workspace.id)")
                    }
                    .padding(.trailing, LoopdyTokens.space4)
                    .background(theme.surface, in: .rect(cornerRadius: LoopdyTokens.radius16))
                    .overlay {
                        RoundedRectangle(cornerRadius: LoopdyTokens.radius16, style: .continuous)
                            .stroke(
                                isSelected ? theme.action : theme.border,
                                lineWidth: isSelected ? 1.5 : LoopdyTokens.hairline
                            )
                    }
                }
            } else {
                ContentUnavailableView(
                    "Workspaces unavailable",
                    systemImage: "square.stack.3d.up",
                    description: Text(store.errorMessage ?? "Connect to the selected Hermes host and try again.")
                )
            }

            if let message = store.errorMessage {
                Text(message)
                    .loopdyFont(.metadata)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") {
                    Task {
                        await store.load(agentID: agentID, sessionID: sessionID)
                    }
                }
                    .loopdyActionStyle()
                    .tint(theme.action)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hermes-workspaces.content")
    }

    private func workspaceRow(_ workspace: HermesWorkspaceSummary) -> some View {
        let isSelected = HermesWorkspaceSelectionPresentation.isSelected(
            workspace,
            store: store,
            sessionID: sessionID
        )
        return HStack(alignment: .top, spacing: LoopdyTokens.space12) {
            Image(systemName: isSelected
                ? "square.stack.3d.up.fill"
                : "square.stack.3d.up")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isSelected ? theme.action : theme.primaryText)
                .frame(width: 36, height: 36)
                .background(theme.raisedSurface, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.name)
                    .loopdyFont(.label, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                if !workspace.description.isEmpty {
                    Text(workspace.description)
                        .loopdyFont(.body)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(workspace.folderCount) \(workspace.folderCount == 1 ? "folder" : "folders")")
                    .loopdyFont(.metadata)
                    .foregroundStyle(theme.tertiaryText)
            }
            Spacer(minLength: LoopdyTokens.space8)
            if store.selectingID == workspace.id {
                LoopdyThinkingOrb(scenario: .working, scale: .inline)
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.action)
            }
        }
        .padding(LoopdyTokens.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    @LoopdyThemeReader private var theme: LoopdyTheme

}

@MainActor
private struct HermesWorkspaceCreateView: View {
    private enum Field: Hashable {
        case name
        case folderPath
    }

    let store: HermesWorkspaceStore
    let agentID: String

    @State private var name = ""
    @State private var folderPath = ""
    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.loopdyUIV2Enabled) private var uiV2Enabled

    @LoopdyThemeReader private var theme: LoopdyTheme

    var body: some View {
        NavigationStack {
            Form {
                Section("Workspace") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .focused($focusedField, equals: .name)
                        .accessibilityIdentifier("hermes-workspaces.create.name")
                    TextField("Remote folder path", text: $folderPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .folderPath)
                        .accessibilityIdentifier("hermes-workspaces.create.path")
                }
                .listRowBackground(uiV2Enabled ? theme.surface : nil)

                Section("Remote folders") {
                    if store.isLoadingFolderSuggestions {
                        LoopdyThinkingOrb(
                            scenario: .searching,
                            scale: .inline,
                            visibleLabel: "Looking for folders"
                        )
                    } else if let message = store.folderSuggestionErrorMessage {
                        Text(message)
                            .foregroundStyle(uiV2Enabled ? AnyShapeStyle(theme.secondaryText) : AnyShapeStyle(.secondary))
                    } else if let suggestions = store.folderSuggestions?.folders,
                              suggestions.isEmpty,
                              folderPath.hasPrefix("/") {
                        Text("No matching child folders")
                            .foregroundStyle(uiV2Enabled ? AnyShapeStyle(theme.secondaryText) : AnyShapeStyle(.secondary))
                    } else if let suggestions = store.folderSuggestions?.folders {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            Button {
                                folderPath = suggestion.path
                            } label: {
                                HStack(spacing: LoopdyTokens.space12) {
                                    Image(systemName: "folder")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.name)
                                            .foregroundStyle(uiV2Enabled ? AnyShapeStyle(theme.primaryText) : AnyShapeStyle(.primary))
                                        Text(suggestion.path)
                                            .loopdyFont(.metadata)
                                            .foregroundStyle(uiV2Enabled ? AnyShapeStyle(theme.secondaryText) : AnyShapeStyle(.secondary))
                                    }
                                }
                            }
                            .accessibilityIdentifier("hermes-workspaces.folder-suggestion.\(index)")
                        }
                    } else {
                        Text("Type an absolute path to browse folders on your Hermes host.")
                            .foregroundStyle(uiV2Enabled ? AnyShapeStyle(theme.secondaryText) : AnyShapeStyle(.secondary))
                    }
                }
                .listRowBackground(uiV2Enabled ? theme.surface : nil)

                if uiV2Enabled {
                    if store.isCreating {
                        Section {
                            ProgressView("Creating workspace…")
                                .accessibilityIdentifier("hermes-workspaces.create.progress")
                        }
                        .listRowBackground(theme.surface)
                    }
                    if let message = store.errorMessage {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(theme.danger)
                                .accessibilityIdentifier("hermes-workspaces.create.error")
                        }
                        .listRowBackground(theme.surface)
                    }
                }
            }
            .modifier(CapabilitySheetAppearance(theme: theme))
            .navigationTitle("New Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            if await store.create(
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                folderPath: folderPath.trimmingCharacters(in: .whitespacesAndNewlines),
                                agentID: agentID
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !folderPath.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
                            || store.isCreating
                    )
                    .accessibilityIdentifier("hermes-workspaces.create.submit")
                }
            }
        }
        .task(id: folderPath) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                await store.loadFolderSuggestions(typedPath: folderPath, agentID: agentID)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        .task {
            await Task.yield()
            focusedField = .name
        }
    }
}
