import SwiftUI

struct AgentTemplateEditorView: View {
    @Bindable var model: AgentTemplateEditorModel
    let onDone: () -> Void

    @State private var confirmsDiscard = false

    var body: some View {
        NavigationStack {
            Form {
                if model.isLoading && model.document == nil {
                    ProgressView("Loading templates")
                        .accessibilityIdentifier("agent.templates.loading")
                } else if let document = model.document {
                    templateSelection(document)
                    basics(document)
                    editor(document)
                    advancedMetadata
                    notices(document)
                } else if let error = model.errorMessage {
                    ContentUnavailableView(
                        "Templates unavailable",
                        systemImage: "doc.badge.ellipsis",
                        description: Text(error)
                    )
                    Button("Try again") { Task { await model.load() } }
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .accessibilityIdentifier("agent.templates.retry")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Agent templates")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(model.isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if model.isDirty { confirmsDiscard = true }
                        else { onDone() }
                    }
                        .disabled(model.isSaving)
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await model.save() } }
                        .fontWeight(.semibold)
                        .bighelpProminentButtonStyle()
                        .buttonBorderShape(.capsule)
                        .tint(theme.action)
                        .foregroundStyle(theme.actionForeground)
                        .disabled(!model.canSave)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .accessibilityIdentifier("agent.templates.save")
                }
            }
        }
        .task { await model.load() }
        .confirmationDialog(
            "Discard unsaved template changes?",
            isPresented: $confirmsDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard changes", role: .destructive, action: onDone)
            Button("Keep editing", role: .cancel) {}
        }
        .interactiveDismissDisabled(model.isSaving || model.isDirty)
        .onDisappear { model.cancel() }
        .accessibilityIdentifier("agent.templates.screen")
    }

    private func templateSelection(_ document: AgentTemplateDocument) -> some View {
        Section {
            if let catalog = model.catalog, !catalog.templates.isEmpty {
                Picker("Saved template", selection: Binding(
                    get: { document.id },
                    set: { id in Task { await model.open(id) } }
                )) {
                    if !catalog.templates.contains(where: { $0.id == document.id }) {
                        Text("Unsaved template").tag(document.id)
                    }
                    ForEach(catalog.templates) { template in
                        Text(template.title).tag(template.id)
                    }
                }
                .disabled(model.isDirty || model.isLoading)
                .accessibilityIdentifier("agent.templates.saved-picker")
            }

            Button("New template", systemImage: "plus") {
                Task { await model.createNew() }
            }
            .disabled(model.isDirty || model.isLoading)
            .frame(minHeight: BighelpTokens.hitTarget)
            .foregroundStyle(theme.action)
            .accessibilityIdentifier("agent.templates.new")
        } header: {
            AgentStudioCaption("Templates")
        }
        .listRowBackground(theme.surface)
    }

    private func basics(_ document: AgentTemplateDocument) -> some View {
        Section {
            TextField("Template name", text: Binding(
                get: { document.title },
                set: { model.updateTitle($0) }
            ))
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("agent.templates.title")
        } header: {
            AgentStudioCaption("Name")
        }
        .listRowBackground(theme.surface)
    }

    private var advancedMetadata: some View {
        Section {
            LabeledContent("Source agent", value: model.source.name)
            if let folder = model.catalog?.storageFolder {
                LabeledContent("Local folder", value: folder)
            }
        } header: {
            AgentStudioCaption("Advanced")
        } footer: {
            Text("This local copy is edited independently. The source agent never changes.")
        }
        .listRowBackground(theme.surface)
    }

    private func editor(_ document: AgentTemplateDocument) -> some View {
        Section {
            Picker("Section", selection: $model.selectedSection) {
                ForEach(AgentTemplateSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage).tag(section)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("agent.templates.section")

            TextEditor(text: Binding(
                get: { model.document?.text(for: model.selectedSection) ?? "" },
                set: { model.updateSection($0) }
            ))
            .font(model.selectedSection == .soul ? .body : .system(.body, design: .monospaced))
            // Long content scrolls inside the box rather than stretching the form.
            .frame(minHeight: 220, maxHeight: 360)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("\(model.selectedSection.title) template content")
            .accessibilityIdentifier("agent.templates.editor")
        } header: {
            AgentStudioCaption("Content")
        } footer: {
            Text(model.selectedSection.help)
        }
        .listRowBackground(theme.surface)
    }

    @ViewBuilder
    private func notices(_ document: AgentTemplateDocument) -> some View {
        if model.isSaving {
            Section { ProgressView("Saving template") }
                .listRowBackground(theme.surface)
        }
        if let message = model.confirmationMessage {
            Section {
                Label(message, systemImage: "checkmark.circle")
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("agent.templates.confirmation")
            }
            .listRowBackground(theme.surface)
        }
        if let error = model.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(theme.danger)
                    .accessibilityIdentifier("agent.templates.error")
            }
            .listRowBackground(theme.surface)
        }
        if !document.omissions.isEmpty {
            Section {
                Text("\(document.omissions.count) source items were excluded because they may contain credentials or unsupported settings.")
                    .foregroundStyle(theme.secondaryText)
                DisclosureGroup("Details") {
                    ForEach(document.omissions, id: \.self) { Text($0).font(.footnote) }
                }
            } header: {
                AgentStudioCaption("Excluded for safety")
            }
            .listRowBackground(theme.surface)
        }
    }

    @BighelpThemeReader private var theme
}
