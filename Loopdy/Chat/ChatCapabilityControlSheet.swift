import SwiftUI

struct CapabilitySelection: Identifiable {
    let agentID: String
    let kind: HermesCapabilityKind
    let itemID: String
    let title: String
    var id: String { "\(agentID):\(kind.rawValue):\(itemID)" }
}

@MainActor
struct CapabilityControlSheet: View {
    let store: SkillsAndToolsStore
    let selection: CapabilitySelection
    @State private var pendingControl: HermesCapabilityControl?
    @State private var isConfirming = false
    @State private var isPresentingEditor = false
    @Environment(\.loopdyUIV2Enabled) private var uiV2Enabled
    @Environment(\.dismiss) private var dismiss

    @LoopdyThemeReader private var theme: LoopdyTheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
                    Text(selection.kind.title).loopdyFont(.metadata).foregroundStyle(theme.secondaryText)
                    Text(selection.itemID).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text("Hermes profile: \(selection.agentID)").loopdyFont(.metadata)
                    if store.isLoadingControl {
                        ProgressView("Reading host settings…").tint(theme.action)
                    } else if let control = store.capabilityControl,
                              control.agentID == selection.agentID,
                              control.kind == selection.kind, control.itemID == selection.itemID {
                        LabeledContent("Host-reported state", value: control.isEnabled ? "Enabled" : "Disabled")
                        Text(control.scope).loopdyFont(.body)
                        Text(control.activation).loopdyFont(.metadata).foregroundStyle(theme.secondaryText)
                        if control.canToggle {
                            Button(control.isEnabled ? "Disable" : "Enable") {
                                pendingControl = control
                                isConfirming = true
                            }
                            .loopdyActionStyle(.primary)
                            .tint(theme.action)
                            .disabled(store.isChangingCapability || store.isSaving)
                            .accessibilityIdentifier("skills-tools.control.toggle")
                        } else {
                            Label(control.reason, systemImage: "lock.fill")
                                .loopdyFont(.body).foregroundStyle(theme.secondaryText)
                                .accessibilityIdentifier("skills-tools.control.locked")
                        }
                    }
                    if store.isChangingCapability {
                        ProgressView("Saving and reading back from Hermes…").tint(theme.action)
                    }
                    if let message = store.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(theme.warning)
                    }
                    if let message = store.statusMessage {
                        Label(message, systemImage: "checkmark.circle")
                            .foregroundStyle(theme.secondaryText)
                            .accessibilityIdentifier("skills-tools.control.receipt")
                    }
                    if selection.kind == .skill {
                        Button("Edit SKILL.md", systemImage: "square.and.pencil") {
                            Task {
                                if await store.loadSkill(id: selection.itemID, agentID: selection.agentID) != nil {
                                    isPresentingEditor = true
                                }
                            }
                        }
                        .disabled(store.isLoading || store.isChangingCapability)
                        .loopdyActionStyle()
                        .tint(theme.action)
                    } else {
                        Text("Only the supported host settings above are editable here. Credentials, server commands, and executable tool code stay on the host.")
                            .loopdyFont(.metadata).foregroundStyle(theme.secondaryText)
                    }
                    Button("Refresh host state", systemImage: "arrow.clockwise") {
                        Task { await reload() }
                    }
                    .loopdyActionStyle().tint(theme.action)
                    .disabled(store.isLoadingControl || store.isChangingCapability)
                }
                .foregroundStyle(theme.primaryText)
                // Loading and short identifiers must accept the same cross-axis
                // proposal as the hydrated host controls.
                .frame(maxWidth: uiV2Enabled ? .infinity : nil, alignment: .leading)
                .padding(LoopdyTokens.space20)
            }
            .background {
                if !uiV2Enabled {
                    LoopdyThemeCanvas(theme: theme).ignoresSafeArea()
                }
            }
            .modifier(CapabilitySheetAppearance(theme: theme))
            .navigationTitle(selection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(store.isChangingCapability)
                }
            }
            .confirmationDialog("Change this capability?", isPresented: $isConfirming, titleVisibility: .visible,
                                presenting: pendingControl) { control in
                Button(control.isEnabled ? "Disable \(selection.title)" : "Enable \(selection.title)",
                       role: control.isEnabled ? .destructive : nil) {
                    Task { await store.setEnabled(!control.isEnabled, confirmedControl: control) }
                }
                Button("Cancel", role: .cancel) { pendingControl = nil }
            } message: { control in
                Text("\(control.scope)\n\(selection.agentID) · \(selection.itemID)\n\n\(control.activation)")
            }
        }
        .task(id: selection.id) { await reload() }
        .sheet(isPresented: $isPresentingEditor, onDismiss: store.clearDocument) {
            if let document = store.document, document.agentID == selection.agentID,
               document.skillID == selection.itemID {
                SkillEditorSheet(store: store, agentID: selection.agentID, document: document)
            }
        }
        .interactiveDismissDisabled(store.isChangingCapability)
        .accessibilityIdentifier("skills-tools.control")
    }

    private func reload() async {
        await store.loadControl(kind: selection.kind, id: selection.itemID, agentID: selection.agentID)
    }
}

/// The native navigation content owns one full-size canvas, independent of
/// loading state. NavigationStack retains title, toolbar and dismissal ownership.
struct CapabilitySheetAppearance: ViewModifier {
    let theme: LoopdyTheme
    @Environment(\.loopdyUIV2Enabled) private var uiV2Enabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if uiV2Enabled {
            ZStack {
                LoopdyThemeCanvas(theme: theme).ignoresSafeArea()
                content
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .foregroundStyle(theme.primaryText)
            .tint(theme.action)
        } else {
            content
        }
    }
}
