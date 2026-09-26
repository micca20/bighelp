import SwiftUI

enum ChatSessionControlChoiceAlignment: Equatable, Sendable {
    case center

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .center:
            .center
        }
    }
}

enum ChatSessionControlsPresentation {
    static let choiceAlignment: ChatSessionControlChoiceAlignment = .center
    static let choicesFillAvailableWidth = true
    static let quickChoiceCentersTextIndependentlyOfAccessories = true
    static let quickChoiceAccessoryWidth: CGFloat = 40
    static let compactChipCentersModelIndependentlyOfProviderMark = true
    static let compactChipAccessoryWidth: CGFloat = 24
    static let showsCompactChipDisclosureIndicator = false

    static func preferredHeight(isVerticallyCompact: Bool) -> CGFloat {
        isVerticallyCompact ? 320 : 560
    }

    static func surfacePresentation(
        isDarkMode: Bool
    ) -> LoopdyPickerSheetSurfacePresentation {
        .resolve(isDarkMode: isDarkMode)
    }
}

struct ChatSessionControlsPopover: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @Bindable var controls: SessionRuntimeControlModel
    let usesWideLayout: Bool
    let onSeeAllModels: () -> Void
    let onApplied: () -> Void

    @State private var draft: SessionRuntimeSelectionDraft

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(
        controls: SessionRuntimeControlModel,
        usesWideLayout: Bool,
        onSeeAllModels: @escaping () -> Void,
        onApplied: @escaping () -> Void
    ) {
        self.controls = controls
        self.usesWideLayout = usesWideLayout
        self.onSeeAllModels = onSeeAllModels
        self.onApplied = onApplied
        _draft = State(initialValue: SessionRuntimeSelectionDraft(
            providerID: controls.currentProvider,
            modelID: controls.currentModel,
            reasoningValue: controls.currentReasoningValue
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: LoopdyTokens.space16) {
                if let errorMessage = controls.errorMessage {
                    LoopdyInlineNotice(
                        message: errorMessage,
                        actionTitle: "Retry",
                        actionIdentifier: "chat.session-controls-retry",
                        isActionEnabled: !(controls.isLoadingModel || controls.isLoadingReasoning),
                        action: { Task { await controls.loadPickersIfNeeded() } },
                        onDismiss: controls.clearError
                    )
                }
                pickerContent
            }
            .padding(LoopdyTokens.space16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityIdentifier("chat.session-controls.popover")
        .frame(minWidth: 280, idealWidth: usesWideLayout ? 600 : 338,
               maxWidth: usesWideLayout ? 600 : 338)
        .frame(
            height: ChatSessionControlsPresentation.preferredHeight(
                isVerticallyCompact: verticalSizeClass == .compact
            )
        )
        .loopdySurface(
            LoopdyPickerSheetLayout.rootSurfaceRole,
            tint: .none
        )
        .task {
            await controls.loadPickersIfNeeded()
            guard !draft.hasChanges else { return }
            draft = SessionRuntimeSelectionDraft(
                providerID: controls.currentProvider,
                modelID: controls.currentModel,
                reasoningValue: controls.currentReasoningValue
            )
        }
        .overlay {
            if controls.isApplyingSelection {
                LoopdyThinkingOrb(scenario: .working, scale: .inline)
                    .padding(LoopdyTokens.space12)
                    .background(.regularMaterial, in: .circle)
                    .accessibilityLabel("Updating this session")
            }
        }
        .onChange(of: [controls.currentProvider, controls.currentModel, controls.currentReasoningValue]) { _, _ in
            draft.reconcile(providerID: controls.currentProvider, modelID: controls.currentModel,
                            reasoningValue: controls.currentReasoningValue)
        }
    }

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
            HStack(spacing: LoopdyTokens.space12) {
                VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                    Text(controls.hasPinnedModels ? "Pinned models" : "Model & reasoning").loopdyFont(.sectionTitle)
                    Text("This chat only").loopdyFont(.metadata).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
                Button(action: onSeeAllModels) {
                    Image(systemName: "chevron.right")
                        .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See all models")
                .accessibilityIdentifier("chat.models.see-all")
            }
            if (controls.isLoadingModel || controls.modelPicker == nil) && controls.errorMessage == nil {
                LoopdyThinkingOrb(scenario: .searching, scale: .inline, visibleLabel: "Loading models")
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: LoopdyTokens.space8),
                                         count: dynamicTypeSize.isAccessibilitySize ? 1 : (usesWideLayout ? 3 : 2)), spacing: LoopdyTokens.space8) {
                    ForEach(controls.quickModelChoices) { choice in
                        let selected = draft.providerID == choice.providerID && draft.modelID == choice.modelID
                        Button {
                            draft.selectModel(providerID: choice.providerID, modelID: choice.modelID)
                        } label: {
                            VStack(spacing: LoopdyTokens.space8) {
                                AIProviderMarkView(providerID: choice.providerID, providerName: choice.providerName, context: .chatQuickChoice)
                                    .accessibilityHidden(true)
                                Text(ModelNameCatalogStore.shared.displayName(for: choice.modelID))
                                    .loopdyFont(.metadata, weight: .semibold)
                                Text(choice.providerName).loopdyFont(.metadata).foregroundStyle(theme.secondaryText)
                                Image(systemName: "checkmark.circle.fill")
                                    .opacity(selected ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .multilineTextAlignment(.center)
                            .foregroundStyle(selected ? theme.action : theme.primaryText)
                            .padding(LoopdyTokens.space12)
                            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
                            .background(theme.surface, in: .rect(cornerRadius: LoopdyTokens.radius16))
                            .overlay {
                                RoundedRectangle(cornerRadius: LoopdyTokens.radius16)
                                    .stroke(selected ? theme.action : theme.border, lineWidth: LoopdyTokens.hairline)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(controls.isApplyingSelection)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("chat.quick-model.\(choice.id)")
                    }
                }
            }
            Divider()
            Text("Reasoning depth").loopdyFont(.label, weight: .semibold)
            if (controls.isLoadingReasoning || controls.reasoningPicker == nil) && controls.errorMessage == nil {
                LoopdyThinkingOrb(scenario: .searching, scale: .inline, visibleLabel: "Loading reasoning choices")
            } else {
                LoopdyReasoningLevelControl(
                    choices: controls.reasoningOptions.map {
                        LoopdyReasoningChoice(value: $0.value, label: $0.label, detail: $0.detail)
                    },
                    selectedValue: draft.reasoningValue,
                    isEnabled: !controls.isApplyingSelection,
                    accessibilityIdentifier: "chat.reasoning-slider",
                    onSelect: { draft.selectReasoning($0) }
                )
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: LoopdyTokens.space8) { cancelButton; applyButton }
                VStack(spacing: LoopdyTokens.space8) { cancelButton; applyButton }
            }
        }
        .foregroundStyle(theme.primaryText)
    }

    private var cancelButton: some View {
        Button { dismiss() } label: {
            Text("Cancel")
                .loopdyFont(.label, weight: .semibold)
                .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .loopdySurface(.capsuleControl, isInteractive: true)
        .disabled(controls.isApplyingSelection)
    }

    private var applyButton: some View {
        LoopdyModelPickerApplyButton(title: "Apply to chat", hasChanges: draft.hasChanges,
                                    isApplying: controls.isApplyingSelection) {
            Task {
                await controls.apply(draft)
                guard controls.errorMessage == nil, !controls.hasPendingSelection else { return }
                await controls.loadModelPicker()
                guard controls.errorMessage == nil else { return }
                await controls.loadReasoningPicker()
                guard controls.errorMessage == nil else { return }
                onApplied()
            }
        }
        .accessibilityIdentifier("chat.session-controls.apply")
    }

    @LoopdyThemeReader private var theme: LoopdyTheme
}
