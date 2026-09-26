import SwiftUI

@MainActor
struct SkillEditorSheet: View {
    let store: SkillsAndToolsStore
    let agentID: String
    let document: HermesSkillDocument

    @Environment(\.dismiss) private var dismiss
    @Environment(\.loopdyUIV2Enabled) private var uiV2Enabled
    @State private var content: String

    @LoopdyThemeReader private var theme: LoopdyTheme

    init(store: SkillsAndToolsStore, agentID: String, document: HermesSkillDocument) {
        self.store = store
        self.agentID = agentID
        self.document = document
        _content = State(initialValue: document.content)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: LoopdyTokens.space12) {
                Text("Edit the complete SKILL.md. Keep its frontmatter name unchanged.")
                    .loopdyFont(.body)
                    .foregroundStyle(uiV2Enabled ? AnyShapeStyle(theme.secondaryText) : AnyShapeStyle(.secondary))
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(uiV2Enabled ? .hidden : .automatic)
                    .padding(LoopdyTokens.space8)
                    .background(
                        uiV2Enabled ? AnyShapeStyle(theme.surface) : AnyShapeStyle(.regularMaterial),
                        in: .rect(cornerRadius: LoopdyTokens.radius16)
                    )
                    .accessibilityIdentifier("skills-tools.editor.content")
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(uiV2Enabled ? theme.danger : .orange)
                }
            }
            .padding(LoopdyTokens.space20)
            .modifier(CapabilitySheetAppearance(theme: theme))
            .navigationTitle(document.skillID)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await store.saveSkill(content: content, agentID: agentID, expectedDocument: document) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(store.isSaving || content == document.content || content.isEmpty
                              || store.catalog?.management?.canUpdate != true)
                    .accessibilityIdentifier("skills-tools.editor.save")
                }
            }
        }
        .interactiveDismissDisabled(store.isSaving)
        .accessibilityIdentifier("skills-tools.editor")
    }
}

@MainActor
struct SkillCreationWizard: View {
    let store: SkillsAndToolsStore
    let agentID: String

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var category = ""
    @State private var description = ""
    @State private var instructions = ""
    @Environment(\.loopdyUIV2Enabled) private var uiV2Enabled

    @LoopdyThemeReader private var theme: LoopdyTheme

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Skill name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("skills-tools.wizard.name")
                    TextField("Category (optional)", text: $category)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("When should this skill be used?", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Identity")
                } footer: {
                    Text("Names and categories use lowercase letters, numbers, dots, hyphens, or underscores.")
                }
                .listRowBackground(uiV2Enabled ? theme.surface : nil)
                Section("Instructions") {
                    TextEditor(text: $instructions)
                        .scrollContentBackground(uiV2Enabled ? .hidden : .automatic)
                        .frame(minHeight: 220)
                        .accessibilityIdentifier("skills-tools.wizard.instructions")
                }
                .listRowBackground(uiV2Enabled ? theme.surface : nil)
                if let error = store.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(uiV2Enabled ? theme.danger : .orange)
                    }
                    .listRowBackground(uiV2Enabled ? theme.surface : nil)
                }
            }
            .modifier(CapabilitySheetAppearance(theme: theme))
            .navigationTitle("Create Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            if await store.createSkill(
                                name: name,
                                description: description,
                                instructions: instructions,
                                category: category,
                                agentID: agentID
                            ) != nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!isValid || store.isSaving)
                    .accessibilityIdentifier("skills-tools.wizard.create")
                }
            }
        }
        .interactiveDismissDisabled(store.isSaving)
        .accessibilityIdentifier("skills-tools.wizard")
    }

    private var isValid: Bool {
        name.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil
            && (category.isEmpty
                || category.range(
                    of: "^[a-z0-9][a-z0-9._-]{0,63}$",
                    options: .regularExpression
                ) != nil)
            && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
