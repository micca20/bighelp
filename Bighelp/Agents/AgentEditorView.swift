import PhotosUI
import SwiftUI
import UIKit

@MainActor
struct AgentEditorView: View {
    private enum Destination: Hashable {
        case advanced
    }

    @State private var model: AgentEditorModel
    @State private var navigationPath: [Destination]
    @State private var runtimeDefaultsModel: AgentRuntimeDefaultsEditorModel?
    @State private var modelPickerScope: AgentRuntimeScope?
    @State private var photoSelection: PhotosPickerItem?
    @State private var avatarPreparationTask: Task<Void, Never>?
    @State private var avatarPreparationID: UUID?
    @State private var avatarPreparationLabel: String?
    @State private var isDiscardConfirmationPresented = false
    @State private var isModelConfirmationPresented = false
    @State private var pendingCompletedProfile: AgentProfile?
    @State private var isAvatarCreatorPresented = false
    /// A new agent's first look in the creator, picked once per editor.
    @State private var surpriseLook = AvatarCreatorModel.surprise()
    @FocusState private var focusedField: AgentEditorModel.Field?
    @Environment(\.dismiss) private var dismiss

    let onCompleted: (AgentProfile) -> Void
    let runtimeDefaultsReadOnlyReason: String?

    init(
        model: AgentEditorModel,
        runtimeDefaultsClient: (any AgentRuntimeDefaultsClient)? = nil,
        runtimeDefaultsReadOnlyReason: String? = nil,
        initiallyShowsAdvanced: Bool = false,
        onCompleted: @escaping (AgentProfile) -> Void
    ) {
        _model = State(initialValue: model)
        _navigationPath = State(initialValue: initiallyShowsAdvanced ? [.advanced] : [])
        if let agentID = model.editingAgentID, let runtimeDefaultsClient {
            _runtimeDefaultsModel = State(initialValue: AgentRuntimeDefaultsEditorModel(
                agentID: agentID,
                client: runtimeDefaultsClient
            ))
        } else {
            _runtimeDefaultsModel = State(initialValue: nil)
        }
        self.onCompleted = onCompleted
        self.runtimeDefaultsReadOnlyReason = runtimeDefaultsReadOnlyReason
    }

    @Environment(\.nerdModeEnabled) private var nerdModeEnabled

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $navigationPath) {
            Form {
                identitySection(
                    model: model,
                    name: $model.draft.name,
                    role: $model.draft.role,
                    summary: $model.draft.summary
                )
                instructionsSection(model: model, instructions: $model.draft.instructions)
                if let defaults = runtimeDefaultsModel {
                    AgentRuntimeDefaultsSection(
                        model: defaults,
                        allowsEdits: runtimeDefaultsReadOnlyReason == nil,
                        scopes: [.mainChats],
                        modelPickerScope: $modelPickerScope
                    )
                }
                if let reason = runtimeDefaultsReadOnlyReason {
                    Section {
                        Label(reason, systemImage: "lock")
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryText)
                    } header: {
                        if runtimeDefaultsModel == nil { AgentStudioCaption("Model") }
                    }
                    .listRowBackground(theme.surface)
                }
                // Handles, subagent models, clone sources and bundled skills are
                // host details: the Advanced route appears only with Nerd Mode on.
                if nerdModeEnabled || model.fieldErrors[.cloning] != nil {
                Section {
                    if nerdModeEnabled {
                    NavigationLink(value: Destination.advanced) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Advanced")
                                    .foregroundStyle(theme.primaryText)
                                Text(!model.isEditing
                                     ? "Starting point, bundled skills, mention handle"
                                     : runtimeDefaultsModel == nil
                                        ? "Mention handle"
                                        : "Subagent and task models, mention handle")
                                    .font(.footnote)
                                    .foregroundStyle(theme.secondaryText)
                            }
                        } icon: {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(theme.secondaryText)
                        }
                        .frame(minHeight: BighelpTokens.hitTarget)
                    }
                    .accessibilityIdentifier("agent.editor.advanced")
                    }
                    if let error = model.fieldErrors[.cloning] { recoveryMessage(error) }
                }
                .listRowBackground(theme.surface)
                }
                if let saveError = model.saveError {
                    Section { recoveryMessage(saveError) }
                        .listRowBackground(theme.surface)
                }
            }
            .disabled(isSaving)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(model.isEditing ? "Edit Agent" : "Agent Studio")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .advanced:
                    advancedForm(model: model)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: requestDismissal)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .disabled(isSaving)
                        .accessibilityIdentifier("agent.editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isEditing ? "Save" : "Create") {
                        Task {
                            do {
                                let profile = try await model.save()
                                applyCompanionLook(to: profile)
                                pendingCompletedProfile = profile
                                try await runtimeDefaultsModel?.saveIfNeeded()
                                guard model.isCurrentContext else { return }
                                onCompleted(profile)
                                pendingCompletedProfile = nil
                                dismiss()
                            } catch {
                                // Each model owns precise, recoverable inline error copy.
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .bighelpProminentButtonStyle()
                    .buttonBorderShape(.capsule)
                    .tint(theme.action)
                    .foregroundStyle(theme.actionForeground)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .disabled(isSaving || model.hasUnconfirmedSave || avatarPreparationID != nil)
                    .accessibilityLabel(model.isEditing ? "Save agent" : "Create agent")
                    .accessibilityIdentifier("agent.editor.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .accessibilityLabel("Dismiss keyboard")
                }
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges || isSaving)
        .onChange(of: photoSelection) { _, selection in
            guard let selection else { return }
            preparePhotoAvatar(selection)
        }
        .sheet(isPresented: $isAvatarCreatorPresented) {
            AvatarCreatorView(appearance: creatorStartLook, agentName: heroTitle) { look in
                prepareCompanionAvatar(look)
            }
            .presentationDragIndicator(.visible)
        }
        // Modal ownership must outlive the lazy sections while a picker is presented.
        .sheet(item: $modelPickerScope) { scope in
            if let defaults = runtimeDefaultsModel {
                let selection = defaults.draft[scope]
                BighelpModelPickerSheet(
                    title: "Choose model",
                    scopeLabel: scope.title,
                    providers: defaults.providers,
                    currentProviderID: selection.providerID,
                    currentModelID: selection.modelID,
                    isLoading: false,
                    isApplying: false,
                    errorMessage: defaults.errorMessage,
                    onClearError: defaults.clearError,
                    onRetry: {
                        Task { await defaults.refreshProviders() }
                    },
                    onSelect: { providerID, modelID in
                        defaults.selectModel(
                            providerID: providerID,
                            modelID: modelID,
                            for: scope
                        )
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .alert(
            "Discard agent changes?",
            isPresented: $isDiscardConfirmationPresented
        ) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your unsaved changes will be lost.")
        }
        .onDisappear {
            cancelAvatarPreparation()
            runtimeDefaultsModel?.dismissConfirmation()
        }
        .onChange(of: runtimeDefaultsModel?.pendingConfirmation) { _, confirmation in
            isModelConfirmationPresented = confirmation != nil
        }
        .confirmationDialog(
            "Confirm model defaults",
            isPresented: $isModelConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Apply model defaults") {
                Task {
                    do {
                        try await runtimeDefaultsModel?.confirmPendingSave()
                        if model.isCurrentContext, !model.hasUnsavedChanges,
                           runtimeDefaultsModel?.isDirty != true, let profile = pendingCompletedProfile {
                            onCompleted(profile)
                            pendingCompletedProfile = nil
                            dismiss()
                        }
                    } catch {
                        // The defaults model retains the choices and reports the failed confirmation.
                    }
                }
            }
            Button("Cancel", role: .cancel) { runtimeDefaultsModel?.dismissConfirmation() }
        } message: {
            Text(runtimeDefaultsModel?.pendingConfirmation?.message ?? "")
        }
        .accessibilityIdentifier(model.isEditing ? "agent.editor.edit" : "agent.editor.create")
    }

    private var isSaving: Bool {
        model.isSaving || runtimeDefaultsModel?.isSaving == true
    }

    private var hasUnsavedChanges: Bool {
        model.hasUnsavedChanges || runtimeDefaultsModel?.isDirty == true
    }

    private func advancedForm(model: AgentEditorModel) -> some View {
        Form {
            if let defaults = runtimeDefaultsModel {
                AgentRuntimeDefaultsSection(
                    model: defaults,
                    allowsEdits: runtimeDefaultsReadOnlyReason == nil,
                    scopes: [.subagents, .scheduledTasks],
                    modelPickerScope: $modelPickerScope
                )
            }
            if !model.isEditing { cloningSection(model: model) }
            handleSection(model: model)
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func requestDismissal() {
        if hasUnsavedChanges {
            isDiscardConfirmationPresented = true
        } else {
            dismiss()
        }
    }

    private func cancelAvatarPreparation() {
        avatarPreparationTask?.cancel()
        avatarPreparationTask = nil
        avatarPreparationID = nil
        avatarPreparationLabel = nil
    }

    private func beginAvatarPreparation(label: String) -> UUID {
        cancelAvatarPreparation()
        let requestID = UUID()
        avatarPreparationID = requestID
        avatarPreparationLabel = label
        return requestID
    }

    private func finishAvatarPreparation(_ requestID: UUID) {
        guard avatarPreparationID == requestID else { return }
        avatarPreparationTask = nil
        avatarPreparationID = nil
        avatarPreparationLabel = nil
        photoSelection = nil
    }

    private func ownsAvatarPreparation(_ requestID: UUID) -> Bool {
        avatarPreparationID == requestID && model.isCurrentContext && !Task.isCancelled
    }

    private var heroState: AgentLiveState {
        // A preview, not live status: a new agent perks up once it has a name.
        !model.isEditing && !model.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .happy : .idle
    }

    private var heroTitle: String {
        let name = model.draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return model.isEditing ? "Agent" : "New agent"
    }

    private var hasAvatar: Bool {
        model.pendingAvatar != nil || model.draft.avatarFileName != nil || model.draft.avatar != nil
    }

    private func hero(model: AgentEditorModel) -> some View {
        VStack(spacing: BighelpTokens.space8) {
            avatarPreview(model: model, size: 120)
                .contentShape(.circle)
                .onTapGesture { isAvatarCreatorPresented = true }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.selectedCompanionCharacter.map {
                    "\($0.displayName) agent avatar preview"
                } ?? "Agent avatar preview")
                .accessibilityHint("Opens the avatar creator.")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("agent.editor.avatar-preview")
                .overlay(alignment: .bottomTrailing) {
                    PhotosPicker(selection: $photoSelection, matching: .images) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.actionForeground)
                            .frame(width: 34, height: 34)
                            .background(theme.action, in: .circle)
                            .overlay(Circle().strokeBorder(theme.canvas, lineWidth: 3))
                            .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                            .contentShape(.circle)
                    }
                    .offset(x: 6, y: 6)
                    .accessibilityLabel("Choose custom agent avatar photo")
                    .accessibilityIdentifier("agent.editor.avatar-picker")
                }
                .padding(.bottom, BighelpTokens.space4)
            Text(heroTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            let role = model.draft.role.trimmingCharacters(in: .whitespacesAndNewlines)
            if !role.isEmpty {
                Text(role)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            HStack(spacing: BighelpTokens.space8) {
                Button {
                    isAvatarCreatorPresented = true
                } label: {
                    Label(hasAvatar ? "Edit avatar" : "Design avatar", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.action)
                        .padding(.horizontal, BighelpTokens.space16)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(theme.incomingMessageBackground))
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Pick a character, color, eyes, extras and moves.")
                .accessibilityIdentifier("agent.editor.design-avatar")
                if hasAvatar {
                    Button {
                        cancelAvatarPreparation()
                        model.removeAvatar()
                        photoSelection = nil
                    } label: {
                        Text("Remove")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, BighelpTokens.space12)
                            .frame(minHeight: BighelpTokens.hitTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove avatar")
                    .accessibilityIdentifier("agent.editor.avatar-remove")
                }
            }
            if let avatarPreparationLabel {
                ProgressView(avatarPreparationLabel)
                    .font(.footnote)
                    .accessibilityIdentifier("agent.editor.avatar.loading")
            }
            if let avatarError = model.avatarError {
                recoveryMessage(avatarError)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, BighelpTokens.space8)
    }

    private func preparePhotoAvatar(_ selection: PhotosPickerItem) {
        let requestID = beginAvatarPreparation(label: "Preparing photo avatar")
        avatarPreparationTask = Task { @MainActor in
            defer { finishAvatarPreparation(requestID) }
            do {
                let data = try await selection.loadTransferable(type: Data.self)
                try Task.checkCancellation()
                guard ownsAvatarPreparation(requestID) else { return }
                guard let data else {
                    model.reportAvatarLoadFailure()
                    return
                }
                try await model.importAvatar(data: data)
            } catch is CancellationError {
                return
            } catch is AvatarImageProcessor.Error {
                // The model already exposed a format or size-specific recovery message.
            } catch {
                guard ownsAvatarPreparation(requestID) else { return }
                model.reportAvatarLoadFailure()
            }
        }
    }

    /// Where the creator opens: this session's look, the agent's saved chat
    /// companion, or a fresh surprise for a new agent.
    private var creatorStartLook: CompanionAppearance {
        if let look = model.selectedCompanionAppearance { return look }
        if let agentID = model.editingAgentID, let store = companionStore, !companionAgentScope.isEmpty,
           let saved = store.override(for: CompanionStore.agentKey(agentScope: companionAgentScope, agentID: agentID)) {
            return saved
        }
        return surpriseLook
    }

    private func companionBackdrop(_ look: CompanionAppearance) -> Color {
        let hex = look.matchesTheme
            ? CompanionAppearance.validatedColorHex(theme.actionHex) ?? CompanionAppearance.fallbackColorHex
            : look.colorHex
        return Color(hex: String(hex.dropFirst()))
    }

    /// The creator's look also becomes this agent's animated chat companion.
    private func applyCompanionLook(to profile: AgentProfile) {
        guard let look = model.selectedCompanionAppearance, let store = companionStore,
              !companionAgentScope.isEmpty else { return }
        store.setOverride(look, for: CompanionStore.agentKey(agentScope: companionAgentScope, agentID: profile.id))
    }

    private func prepareCompanionAvatar(_ look: CompanionAppearance) {
        photoSelection = nil
        let appearance = appAppearance
        let scheme = colorScheme
        let contrast = colorSchemeContrast
        let requestID = beginAvatarPreparation(label: "Preparing \(look.character.displayName) avatar")
        avatarPreparationTask = Task { @MainActor in
            defer { finishAvatarPreparation(requestID) }
            do {
                let data = try await AgentCompanionAvatarRenderer.renderPNG(
                    companion: look,
                    appearance: appearance,
                    colorScheme: scheme,
                    colorSchemeContrast: contrast
                )
                try Task.checkCancellation()
                guard ownsAvatarPreparation(requestID) else { return }
                try await model.importCompanionAvatar(data: data, appearance: look)
            } catch is CancellationError {
                return
            } catch is AvatarImageProcessor.Error {
                // The model already exposed a format or size-specific recovery message.
            } catch {
                guard ownsAvatarPreparation(requestID) else { return }
                model.reportCompanionAvatarRenderFailure()
            }
        }
    }

    @ViewBuilder
    private func avatarPreview(model: AgentEditorModel, size: CGFloat = 72) -> some View {
        if model.pendingAvatar != nil, let look = model.selectedCompanionAppearance {
            // A creator look plays its chosen moves right here.
            Circle()
                .fill(companionBackdrop(look).opacity(0.18))
                .overlay(Circle().strokeBorder(companionBackdrop(look).opacity(0.25), lineWidth: 1))
                .overlay {
                    CompanionAvatar(appearance: look, reaction: .idle, isAnimating: true)
                        .frame(width: size * 0.8, height: size * 0.8)
                }
                .frame(width: size, height: size)
        } else if let pending = model.pendingAvatar, let image = UIImage(data: pending.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(.circle)
        } else {
            AvatarView(
                stableID: model.editingAgentID ?? "agent-editor-new",
                displayName: model.draft.name.isEmpty ? "New agent" : model.draft.name,
                imageURL: model.draft.removesAvatar ? nil : model.avatarURL,
                size: size,
                state: heroState
            )
        }
    }

    private func identitySection(
        model: AgentEditorModel,
        name: Binding<String>,
        role: Binding<String>,
        summary: Binding<String>
    ) -> some View {
        Section {
            field("Name", prompt: "Give your agent a name", text: name, focus: .name,
                  error: model.fieldErrors[.name], identifier: "agent.editor.name")
            field("Role", prompt: "e.g. Travel planner", text: role, focus: .role,
                  error: model.fieldErrors[.role], identifier: "agent.editor.role")
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                fieldCaption("About")
                TextField("About", text: summary, prompt: Text("One line about what it does"), axis: .vertical)
                    .lineLimit(1...3)
                    .focused($focusedField, equals: .summary)
                    .accessibilityLabel("About")
                    .accessibilityIdentifier("agent.editor.summary")
                if let error = model.fieldErrors[.summary] { recoveryMessage(error) }
            }
            .padding(.vertical, BighelpTokens.space4)
        } header: {
            VStack(spacing: BighelpTokens.space20) {
                hero(model: model)
                if !model.isEditing {
                    AgentStudioStarterRow(selectedID: model.appliedStarterID) { starter in
                        model.applyStarter(starter)
                    }
                }
                AgentStudioCaption("Identity")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("agent.editor.identity-header")
            }
            .textCase(nil)
            .padding(.bottom, BighelpTokens.space4)
        }
        .listRowBackground(theme.surface)
    }

    private func cloningSection(model: AgentEditorModel) -> some View {
        Section {
            if let reason = model.profileCloneSupport.unavailableReason {
                Label(reason, systemImage: "info.circle")
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Clone from existing profile", selection: cloneSourceBinding(model)) {
                    Text("None, create fresh").tag(String?.none)
                    ForEach(model.cloneSources) { profile in
                        Text(profile.name).tag(String?.some(profile.id))
                    }
                }
                .accessibilityIdentifier("agent.editor.clone.source")

                Toggle("Skip bundled skills", isOn: Binding(
                    get: { model.draft.skipBundledSkills },
                    set: { model.setSkipBundledSkills($0) }
                ))
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("agent.editor.clone.skip-bundled-skills")
                .disabled(model.draft.cloneSourceProfileID != nil)

                if model.draft.cloneSourceProfileID != nil {
                    Label(
                        "The source’s skills are included. Chat history, scheduled tasks, and local pins are not copied.",
                        systemImage: "doc.on.doc"
                    )
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Label(
                "Use a new name and avatar, then review SOUL so this agent keeps a distinct purpose.",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("agent.editor.clone.soul-reminder")

            if let error = model.fieldErrors[.cloning] { recoveryMessage(error) }
        } header: {
            AgentStudioCaption("Start from an existing agent")
        } footer: {
            Text(model.draft.cloneSourceProfileID == nil
                 ? "Start fresh can omit Hermes’ bundled skills."
                 : "Hermes copies configuration, saved credentials, skills, built-in memories, and SOUL on this host. bighelp never displays credential contents.")
        }
        .listRowBackground(theme.surface)
    }

    private func cloneSourceBinding(_ model: AgentEditorModel) -> Binding<String?> {
        Binding(
            get: { model.draft.cloneSourceProfileID },
            set: { model.selectCloneSource($0) }
        )
    }

    private func instructionsSection(model: AgentEditorModel, instructions: Binding<String>) -> some View {
        let name = model.draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Section {
            textEditor(
                "Instructions",
                placeholder: "What should \(name.isEmpty ? "your agent" : name) help you with? How should it talk?",
                text: instructions,
                focus: .instructions,
                error: model.fieldErrors[.instructions],
                identifier: "agent.editor.instructions"
            )
        } header: {
            AgentStudioCaption("Instructions")
                .accessibilityIdentifier("agent.editor.behavior-header")
        } footer: {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                if !model.isEditing && runtimeDefaultsModel == nil && runtimeDefaultsReadOnlyReason == nil {
                    Label("Uses your default model. You can pick another after creating.", systemImage: "cpu")
                        .accessibilityIdentifier("agent.editor.model-default-note")
                }
                if !model.isEditing, let source = model.cloneSourceName {
                    Label(nerdModeEnabled
                          ? "Starts with \(source)’s skills, memories and settings. Change this in Advanced."
                          : "Starts with \(source)’s skills, memories and settings.",
                          systemImage: "doc.on.doc")
                        .accessibilityIdentifier("agent.editor.clone-note")
                }
            }
        }
        .listRowBackground(theme.surface)
    }

    private func handleSection(model: AgentEditorModel) -> some View {
        Section {
            LabeledContent("Mention handle") {
                Text("@\(model.handlePreview)")
                    .font(.body.monospaced())
                    .foregroundStyle(theme.action)
            }
        } header: {
            AgentStudioCaption("Mention handle")
        } footer: {
            Text("Suggested for new groups. Existing handles stay unchanged.")
        }
        .listRowBackground(theme.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Suggested mention handle @\(model.handlePreview)")
    }

    private func fieldCaption(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.secondaryText)
            .accessibilityHidden(true)
    }

    private func field(
        _ title: String,
        prompt: String,
        text: Binding<String>,
        focus: AgentEditorModel.Field,
        error: String?,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            fieldCaption(title)
            TextField(title, text: text, prompt: Text(prompt))
                .focused($focusedField, equals: focus)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
            if let error { recoveryMessage(error) }
        }
        .padding(.vertical, BighelpTokens.space4)
    }

    private func textEditor(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        focus: AgentEditorModel.Field,
        error: String?,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            TextEditor(text: text)
                .focused($focusedField, equals: focus)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(.body)
                            .foregroundStyle(theme.tertiaryText)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(title)
                .accessibilityHint(text.wrappedValue.isEmpty ? placeholder : "")
                .accessibilityIdentifier(identifier)
            if let error { recoveryMessage(error) }
        }
    }

    private func recoveryMessage(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .bighelpFont(.metadata)
            .foregroundStyle(theme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }

    @BighelpThemeReader private var theme

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appAppearance) private var appAppearance
    @Environment(\.companionStore) private var companionStore
    @Environment(\.companionAgentScope) private var companionAgentScope
}
