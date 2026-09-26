import SwiftUI

struct LoopdyModelPickerProviderGroup: Identifiable, Equatable {
    let provider: LoopdyLinkModelProvider
    let models: [String]

    var id: String { provider.id }
}

struct LoopdyModelPickerDisclosureState: Equatable, Sendable {
    private var expandedProviderIDs = Set<String>()

    init(expandedProviderIDs: Set<String> = []) {
        self.expandedProviderIDs = expandedProviderIDs
    }

    func isExpanded(_ providerID: String) -> Bool {
        expandedProviderIDs.contains(providerID)
    }

    mutating func toggle(_ providerID: String) {
        if expandedProviderIDs.remove(providerID) == nil {
            expandedProviderIDs.insert(providerID)
        }
    }
}

enum LoopdyModelPickerFiltering {
    @MainActor
    static func groups(
        providers: [LoopdyLinkModelProvider],
        currentProviderID: String?,
        query: String
    ) -> [LoopdyModelPickerProviderGroup] {
        groups(
            providers: providers,
            currentProviderID: currentProviderID,
            query: query,
            displayName: { ModelNameCatalogStore.shared.displayName(for: $0) }
        )
    }

    static func groups(
        providers: [LoopdyLinkModelProvider],
        currentProviderID: String?,
        query: String,
        displayName: (String) -> String
    ) -> [LoopdyModelPickerProviderGroup] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return providers.enumerated()
            .sorted { left, right in
                let leftIsCurrent = left.element.id == currentProviderID
                let rightIsCurrent = right.element.id == currentProviderID
                if leftIsCurrent != rightIsCurrent { return leftIsCurrent }
                return left.offset < right.offset
            }
            .compactMap { _, provider in
                guard !normalizedQuery.isEmpty else {
                    return LoopdyModelPickerProviderGroup(
                        provider: provider,
                        models: provider.models
                    )
                }

                let providerMatches = provider.name.localizedCaseInsensitiveContains(normalizedQuery)
                    || provider.id.localizedCaseInsensitiveContains(normalizedQuery)
                let models = providerMatches
                    ? provider.models
                    : provider.models.filter {
                        $0.localizedCaseInsensitiveContains(normalizedQuery)
                            || displayName($0).localizedCaseInsensitiveContains(normalizedQuery)
                    }
                guard !models.isEmpty else { return nil }
                return LoopdyModelPickerProviderGroup(provider: provider, models: models)
            }
    }
}

enum LoopdyPickerSheetLayout {
    static let rootSurfaceRole: LoopdySurfaceRole = .sheet
    static let panelComponent: LoopdyComponentKind = .menuPanel
    static let rowComponent: LoopdyComponentKind = .menuRow
    static let searchComponent: LoopdyComponentKind = .searchField
    static let dismissButtonStyle: LoopdyIconButtonStyle = .neutralGlass
    static let centersProviderHeaders = true
    static let centersModelRows = true
    static let centersReasoningRows = true
}

struct LoopdyPickerSheetSurfacePresentation: Equatable, Sendable {
    enum Base: Equatable, Sendable {
        case clear
        case canvas
    }

    let base: Base
    let opacity: Double

    static let usesColoredOutline = false

    static func resolve(isDarkMode: Bool) -> Self {
        isDarkMode
            ? LoopdyPickerSheetSurfacePresentation(base: .canvas, opacity: 0.72)
            : LoopdyPickerSheetSurfacePresentation(base: .clear, opacity: 0)
    }

    func color(in theme: LoopdyTheme) -> Color {
        switch base {
        case .clear: .clear
        case .canvas: theme.canvas
        }
    }

    var surfaceTint: LoopdySurfaceTint {
        switch base {
        case .clear:
            .none
        case .canvas:
            .canvas(opacity: opacity)
        }
    }
}

struct LoopdyPickerSheetBackgroundModifier: ViewModifier {
    let usesNativePresentation: Bool
    let legacyTint: LoopdySurfaceTint

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appAppearance) private var appAppearance

    @ViewBuilder
    func body(content: Content) -> some View {
        let theme = LoopdyTheme.resolve(
            appearance: appAppearance,
            colorScheme: colorScheme,
            contrast: colorSchemeContrast
        )
        if usesNativePresentation {
            content
                .background(Color.clear)
                .loopdyTranslucentPresentationBackground(fallback: theme.canvas)
        } else {
            content
                .loopdySurface(LoopdyPickerSheetLayout.rootSurfaceRole, tint: legacyTint)
                .presentationBackground(.clear)
        }
    }
}

private struct LoopdyPickerSearchModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String
    @Binding var isPresented: Bool
    let prompt: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $text, isPresented: $isPresented, prompt: prompt)
        } else {
            content
        }
    }
}

struct LoopdyModelPickerApplyPresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case disabled
        case enabled
        case applying
    }

    enum ColorRole: Equatable, Sendable {
        case disabledGray
        case secondaryText
        case action
        case actionForeground
    }

    let state: State
    let background: ColorRole
    let foreground: ColorRole
    let isInteractive: Bool

    static func resolve(hasChanges: Bool, isApplying: Bool) -> Self {
        if isApplying {
            return LoopdyModelPickerApplyPresentation(
                state: .applying,
                background: .action,
                foreground: .actionForeground,
                isInteractive: false
            )
        }
        if hasChanges {
            return LoopdyModelPickerApplyPresentation(
                state: .enabled,
                background: .action,
                foreground: .actionForeground,
                isInteractive: true
            )
        }
        return LoopdyModelPickerApplyPresentation(
            state: .disabled,
            background: .disabledGray,
            foreground: .secondaryText,
            isInteractive: false
        )
    }

    static func disabledBackgroundOpacity(isDarkMode: Bool) -> Double {
        isDarkMode ? 0.28 : 0.10
    }
}

struct LoopdyModelPickerApplyButton: View {
    let title: String
    let hasChanges: Bool
    let isApplying: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let presentation = LoopdyModelPickerApplyPresentation.resolve(
            hasChanges: hasChanges,
            isApplying: isApplying
        )
        Button(action: action) {
            HStack(spacing: LoopdyTokens.space8) {
                if presentation.state == .applying {
                    LoopdyThinkingOrb(
                        scenario: .working,
                        scale: .inline,
                        surface: theme.actionThinkingOrbSurface
                    )
                        .accessibilityHidden(true)
                }
                Text(presentation.state == .applying ? "Applying…" : title)
                    .loopdyFont(.label, weight: .semibold)
            }
            .foregroundStyle(foregroundColor(for: presentation))
            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.controlHeight)
            .background(backgroundColor(for: presentation), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!presentation.isInteractive)
        .accessibilityValue(accessibilityValue(for: presentation))
    }

    private func backgroundColor(
        for presentation: LoopdyModelPickerApplyPresentation
    ) -> Color {
        switch presentation.background {
        case .disabledGray:
            theme.primaryText.opacity(
                LoopdyModelPickerApplyPresentation.disabledBackgroundOpacity(
                    isDarkMode: colorScheme == .dark
                )
            )
        case .action:
            theme.action
        case .secondaryText:
            theme.secondaryText
        case .actionForeground:
            theme.actionForeground
        }
    }

    private func foregroundColor(
        for presentation: LoopdyModelPickerApplyPresentation
    ) -> Color {
        switch presentation.foreground {
        case .secondaryText, .disabledGray:
            theme.secondaryText
        case .action:
            theme.action
        case .actionForeground:
            theme.actionForeground
        }
    }

    private func accessibilityValue(
        for presentation: LoopdyModelPickerApplyPresentation
    ) -> String {
        switch presentation.state {
        case .disabled: "No changes to apply"
        case .enabled: "Ready to apply"
        case .applying: "Applying changes"
        }
    }

    @LoopdyThemeReader private var theme
}

struct LoopdyModelPickerSheet: View {
    let title: String
    let scopeLabel: String
    let providers: [LoopdyLinkModelProvider]
    let currentProviderID: String?
    let currentModelID: String?
    let currentReasoningValue: String?
    let isLoading: Bool
    let isApplying: Bool
    let errorMessage: String?
    let onClearError: () -> Void
    let onRetry: (() -> Void)?
    let onSelect: (String, String) -> Void
    let isModelPinned: ((String, String) -> Bool)?
    let onToggleModelPin: ((String, String) -> Void)?
    let reasoningOptions: [RuntimeReasoningOption]
    let onApply: ((SessionRuntimeSelectionDraft) -> Void)?
    let statusMessage: String?
    let modelUnavailableReason: String?
    let reasoningUnavailableReason: String?
    let modelConfirmation: SessionRuntimeModelConfirmation?
    let onConfirmModel: ((SessionRuntimeModelConfirmation) -> Void)?
    let onCancelModelConfirmation: ((SessionRuntimeModelConfirmation) -> Void)?

    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var disclosure: LoopdyModelPickerDisclosureState
    @State private var draft: SessionRuntimeSelectionDraft
    @State private var isReasoningPresented = false
    @State private var pinMutationRevision = 0
    @State private var isModelConfirmationPresented = false
    @State private var didSubmitModelConfirmation = false
    @Environment(\.loopdyUIV3Enabled) private var uiV3Enabled
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        scopeLabel: String,
        providers: [LoopdyLinkModelProvider],
        currentProviderID: String?,
        currentModelID: String?,
        isLoading: Bool,
        isApplying: Bool,
        errorMessage: String?,
        onClearError: @escaping () -> Void,
        onRetry: (() -> Void)?,
        onSelect: @escaping (String, String) -> Void,
        isModelPinned: ((String, String) -> Bool)? = nil,
        onToggleModelPin: ((String, String) -> Void)? = nil,
        reasoningOptions: [RuntimeReasoningOption] = [],
        currentReasoningValue: String? = nil,
        statusMessage: String? = nil,
        modelUnavailableReason: String? = nil,
        reasoningUnavailableReason: String? = nil,
        modelConfirmation: SessionRuntimeModelConfirmation? = nil,
        onConfirmModel: ((SessionRuntimeModelConfirmation) -> Void)? = nil,
        onCancelModelConfirmation: ((SessionRuntimeModelConfirmation) -> Void)? = nil,
        onApply: ((SessionRuntimeSelectionDraft) -> Void)? = nil
    ) {
        self.title = title
        self.scopeLabel = scopeLabel
        self.providers = providers
        self.currentProviderID = currentProviderID
        self.currentModelID = currentModelID
        self.currentReasoningValue = currentReasoningValue
        self.isLoading = isLoading
        self.isApplying = isApplying
        self.errorMessage = errorMessage
        self.onClearError = onClearError
        self.onRetry = onRetry
        self.onSelect = onSelect
        self.isModelPinned = isModelPinned
        self.onToggleModelPin = onToggleModelPin
        self.reasoningOptions = reasoningOptions
        self.onApply = onApply
        self.statusMessage = statusMessage
        self.modelUnavailableReason = modelUnavailableReason
        self.reasoningUnavailableReason = reasoningUnavailableReason
        self.modelConfirmation = modelConfirmation
        self.onConfirmModel = onConfirmModel
        self.onCancelModelConfirmation = onCancelModelConfirmation
        _disclosure = State(initialValue: LoopdyModelPickerDisclosureState(
            expandedProviderIDs: Set([currentProviderID].compactMap { $0 })
        ))
        _draft = State(initialValue: SessionRuntimeSelectionDraft(
            providerID: currentProviderID,
            modelID: currentModelID,
            reasoningValue: currentReasoningValue
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !uiV3Enabled {
                    ZStack(alignment: .topTrailing) {
                        VStack(alignment: .center, spacing: LoopdyTokens.space4) {
                            Text(isChoosingReasoning ? "Reasoning level" : title)
                                .loopdyFont(.screenTitle, weight: .bold)
                                .foregroundStyle(theme.primaryText)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(scopeLabel)
                                .loopdyFont(.metadata, weight: .semibold)
                                .foregroundStyle(theme.secondaryText)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, LoopdyTokens.hitTarget)

                        LoopdyIconButton(
                            systemImage: isChoosingReasoning ? "chevron.left" : "xmark",
                            accessibilityLabel: isChoosingReasoning
                                ? "Back to model picker"
                                : "Close model picker",
                            style: LoopdyPickerSheetLayout.dismissButtonStyle,
                            action: closeOrReturn
                        )
                        .accessibilityIdentifier("model-picker.dismiss")
                    }
                    .padding(.horizontal, LoopdyTokens.space20)
                    .padding(.top, LoopdyTokens.space20)
                }

                if !uiV3Enabled && !isChoosingReasoning {
                    searchField
                        .padding(.horizontal, LoopdyTokens.space20)
                        .padding(.top, LoopdyTokens.space16)
                        .padding(.bottom, LoopdyTokens.space12)
                }

            ScrollView {
                LazyVStack(alignment: .center, spacing: LoopdyTokens.space16) {
                    if uiV3Enabled {
                        Text(scopeLabel)
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let errorMessage {
                        errorCard(errorMessage)
                    }
                    if let statusMessage {
                        availabilityText(statusMessage, identifier: "model-picker.pending-status")
                    }
                    if let modelUnavailableReason {
                        availabilityText(modelUnavailableReason, identifier: "model-picker.model-unavailable")
                    }

                    if uiV3Enabled, isStagedFlow, searchText.isEmpty {
                        selectionSummary
                    }
                    if isChoosingReasoning {
                        reasoningChoices
                    } else if isLoading && providers.isEmpty {
                        LoopdyThinkingOrb(
                            scenario: .searching,
                            visibleLabel: "Loading configured models"
                        )
                            .loopdyFont(.metadata)
                            .frame(maxWidth: .infinity, minHeight: 180)
                            .accessibilityIdentifier("model-picker.loading")
                    } else if filteredProviders.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        ForEach(filteredProviders) { group in
                            providerSection(group)
                        }
                    }
                }
                .padding(.horizontal, LoopdyTokens.space20)
                .padding(.bottom, LoopdyTokens.space32)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .id(isChoosingReasoning ? "model-picker.reasoning-step" : "model-picker.models-step")
            .scrollIndicators(.visible)

            if isStagedFlow {
                applyBar
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(LoopdyPickerSheetBackgroundModifier(
                usesNativePresentation: uiV3Enabled,
                legacyTint: sheetSurfacePresentation.surfaceTint
            ))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("model-picker.surface")
            .overlay {
                if isApplying {
                    LoopdyCard {
                        LoopdyThinkingOrb(
                            scenario: .working,
                            scale: .inline,
                            visibleLabel: "Updating…"
                        )
                            .loopdyFont(.label)
                    }
                        .accessibilityIdentifier("model-picker.updating")
                }
            }
            .navigationTitle(uiV3Enabled ? title : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(uiV3Enabled ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if uiV3Enabled {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", action: dismiss.callAsFunction)
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("model-picker.dismiss")
                    }
                }
            }
            .modifier(LoopdyPickerSearchModifier(
                isEnabled: uiV3Enabled,
                text: $searchText,
                isPresented: $isSearchPresented,
                prompt: "Search providers and models"
            ))
        }
        .presentationDragIndicator(.visible)
        .onChange(of: [currentProviderID, currentModelID, currentReasoningValue], initial: true) { _, _ in
            draft.reconcile(providerID: currentProviderID, modelID: currentModelID, reasoningValue: currentReasoningValue)
        }
        .onChange(of: modelConfirmation, initial: true) { _, confirmation in
            didSubmitModelConfirmation = false
            isModelConfirmationPresented = confirmation != nil && onConfirmModel != nil
        }
        .onChange(of: isModelConfirmationPresented) { _, isPresented in
            if !isPresented, !didSubmitModelConfirmation, let modelConfirmation {
                onCancelModelConfirmation?(modelConfirmation)
            }
        }
        .confirmationDialog("Confirm model change", isPresented: $isModelConfirmationPresented,
                            titleVisibility: .visible) {
            Button("Change model") {
                guard let modelConfirmation else { return }
                didSubmitModelConfirmation = true
                onConfirmModel?(modelConfirmation)
            }
            Button("Cancel", role: .cancel) {
                if let modelConfirmation { onCancelModelConfirmation?(modelConfirmation) }
            }
        } message: {
            Text(modelConfirmation?.message ?? "")
        }
        .onDisappear {
            if let modelConfirmation { onCancelModelConfirmation?(modelConfirmation) }
        }
    }

    private var isStagedFlow: Bool { onApply != nil }

    private var isChoosingReasoning: Bool {
        isStagedFlow && isReasoningPresented && !uiV3Enabled
    }

    private func closeOrReturn() {
        if isChoosingReasoning {
            isReasoningPresented = false
            draft.showModels()
        } else {
            dismiss()
        }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model").loopdyFont(.metadata).foregroundStyle(theme.secondaryText)
                Text(draft.modelID.map { ModelNameCatalogStore.shared.displayName(for: $0) } ?? "Host default")
                    .loopdyFont(.sectionTitle)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let providerID = draft.providerID,
                   let provider = providers.first(where: { $0.id == providerID }) {
                    Text(provider.name).loopdyFont(.metadata).foregroundStyle(theme.secondaryText)
                }
            }
            if !reasoningOptions.isEmpty {
                Divider()
                reasoningChoices
            } else if let reasoningUnavailableReason {
                availabilityText(reasoningUnavailableReason, identifier: "model-picker.reasoning-unavailable")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model-picker.selection-summary")
    }

    private var applyBar: some View {
        LoopdyModelPickerApplyButton(
            title: "Apply to current chat",
            hasChanges: draft.hasChanges && canApplyDraft && modelConfirmation == nil && statusMessage == nil,
            isApplying: isApplying
        ) {
            onApply?(draft)
        }
        .padding(.horizontal, LoopdyTokens.space20)
        .padding(.vertical, LoopdyTokens.space12)
        .background(colorScheme == .dark ? theme.canvas : theme.raisedSurface, ignoresSafeAreaEdges: [])
        .accessibilityIdentifier("model-picker.apply")
    }

    private var sheetSurfacePresentation: LoopdyPickerSheetSurfacePresentation {
        .resolve(isDarkMode: colorScheme == .dark)
    }

    private var reasoningChoices: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
            LoopdyReasoningLevelControl(
                choices: reasoningOptions.map {
                    LoopdyReasoningChoice(value: $0.value, label: $0.label, detail: $0.detail)
                },
                selectedValue: draft.reasoningValue,
                isEnabled: !isApplying && reasoningUnavailableReason == nil,
                accessibilityIdentifier: "model-picker.reasoning-slider",
                onSelect: chooseReasoning,
                isEmbedded: uiV3Enabled
            )
            if let reasoningUnavailableReason {
                availabilityText(reasoningUnavailableReason, identifier: "model-picker.reasoning-unavailable")
            }
        }
    }

    private var canApplyDraft: Bool {
        let changesModel = draft.providerID != draft.originalProviderID || draft.modelID != draft.originalModelID
        let changesReasoning = draft.reasoningValue != draft.originalReasoningValue
        return (!changesModel || modelUnavailableReason == nil)
            && (!changesReasoning || reasoningUnavailableReason == nil)
    }

    private func availabilityText(_ message: String, identifier: String) -> some View {
        Text(message)
            .loopdyFont(.metadata)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }

    private var searchField: some View {
        LoopdySearchField(
            text: $searchText,
            prompt: "Search providers and models",
            accessibilityLabel: "Search providers and models",
            accessibilityIdentifier: "model-picker.search"
        )
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: LoopdyTokens.space12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .reflectiveVisionIcon()
                .foregroundStyle(theme.danger)
            Text(message)
                .loopdyFont(.metadata)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: LoopdyTokens.space4)
            if let onRetry {
                Button("Retry", action: onRetry)
                    .loopdyFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.action)
                    .frame(minWidth: LoopdyTokens.hitTarget, minHeight: LoopdyTokens.hitTarget)
                    .disabled(isApplying)
                    .accessibilityIdentifier("model-picker.retry")
            }
            Button(action: onClearError) {
                Image(systemName: "xmark")
                    .reflectiveVisionIcon()
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss model picker error")
        }
        .padding(LoopdyTokens.space12)
        .background(theme.danger.opacity(0.08), in: .rect(cornerRadius: LoopdyTokens.radius12))
        .overlay {
            RoundedRectangle(cornerRadius: LoopdyTokens.radius12, style: .continuous)
                .stroke(theme.danger.opacity(0.24), lineWidth: LoopdyTokens.hairline)
        }
    }

    private func providerSection(_ group: LoopdyModelPickerProviderGroup) -> some View {
        let visibleIdentity = AIProviderVisibleIdentity.resolve(
            providerID: group.provider.id,
            providerName: group.provider.name
        )
        return LoopdyMenuPanel {
            VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                Button {
                    disclosure.toggle(group.provider.id)
                } label: {
                    HStack(alignment: .center, spacing: LoopdyTokens.space12) {
                        AIProviderMarkView(
                            providerID: visibleIdentity.rawProviderID,
                            providerName: visibleIdentity.visibleProviderName,
                            context: .modelPickerProviderHeader,
                            size: 36
                        )
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(visibleIdentity.visibleProviderName)
                                .loopdyFont(.label, weight: .semibold)
                                .foregroundStyle(theme.primaryText)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if group.provider.id == currentProviderID {
                                Text("Current provider")
                                    .loopdyFont(.metadata)
                                    .foregroundStyle(theme.action)
                            } else if group.provider.isCustom {
                                Text("Custom provider")
                                    .loopdyFont(.metadata)
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        Spacer(minLength: LoopdyTokens.space8)
                        Image(systemName: providerIsExpanded(group.provider.id)
                              ? "chevron.down"
                              : "chevron.right")
                            .reflectiveVisionIcon()
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, LoopdyTokens.space12)
                    .padding(.vertical, LoopdyTokens.space4)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(providerIsExpanded(group.provider.id) ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("model-picker.provider.\(group.provider.id)")

                if providerIsExpanded(group.provider.id) {
                    ForEach(group.models, id: \.self) { modelID in
                        modelRow(provider: group.provider, modelID: modelID)
                    }
                }
            }
        }
    }

    private func modelRow(provider: LoopdyLinkModelProvider, modelID: String) -> some View {
        let selected = isCurrent(providerID: provider.id, modelID: modelID)
        let _ = pinMutationRevision
        let pinned = isModelPinned?(provider.id, modelID) ?? false
        let displayName = ModelNameCatalogStore.shared.displayName(for: modelID)
        let providerName = AIProviderVisibleIdentity.resolve(
            providerID: provider.id,
            providerName: provider.name
        ).visibleProviderName
        return HStack(alignment: .center, spacing: 0) {
            LoopdyMenuRow(
                isSelected: selected,
                isEnabled: !isApplying && modelUnavailableReason == nil,
                action: { chooseModel(providerID: provider.id, modelID: modelID) }
            ) {
                HStack(alignment: .center, spacing: LoopdyTokens.space12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .loopdyFont(.label)
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if displayName != modelID {
                            Text(modelID)
                                .loopdyFont(.metadata)
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                                .multilineTextAlignment(.leading)
                        }
                        Text(providerName)
                            .loopdyFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: LoopdyTokens.space8)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .reflectiveVisionIcon()
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(selected ? theme.action : theme.tertiaryText)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, LoopdyTokens.space12)
                .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("\(displayName), \(providerName)")
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityIdentifier("model-picker.\(provider.id).\(modelID)")

            if let onToggleModelPin, isModelPinned != nil {
                Button {
                    onToggleModelPin(provider.id, modelID)
                    pinMutationRevision &+= 1
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .reflectiveVisionIcon()
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(pinned ? theme.action : theme.secondaryText)
                        .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(isApplying)
                .accessibilityLabel("\(pinned ? "Unpin model" : "Pin model") \(displayName)")
                .accessibilityIdentifier("model-picker.pin.\(provider.id).\(modelID)")
            }
        }
    }

    private var filteredProviders: [LoopdyModelPickerProviderGroup] {
        LoopdyModelPickerFiltering.groups(
            providers: providers,
            currentProviderID: currentProviderID,
            query: searchText
        )
    }

    private func isCurrent(providerID: String, modelID: String) -> Bool {
        if isStagedFlow {
            return providerID == draft.providerID && modelID == draft.modelID
        }
        return providerID == currentProviderID && modelID == currentModelID
    }

    private func providerIsExpanded(_ providerID: String) -> Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || disclosure.isExpanded(providerID)
    }

    private func chooseModel(providerID: String, modelID: String) {
        if isStagedFlow {
            draft.selectModel(providerID: providerID, modelID: modelID)
            if uiV3Enabled {
                searchText = ""
                isSearchPresented = false
            }
            isReasoningPresented = !uiV3Enabled
        } else {
            onSelect(providerID, modelID)
        }
    }

    private func chooseReasoning(_ value: String) {
        draft.selectReasoning(value)
    }

    @LoopdyThemeReader private var theme
}

enum AIProviderMarkContext: CaseIterable, Equatable, Sendable {
    case agentRuntimeSelection
    case modelPickerProviderHeader
    case chatSessionCompactControl
    case chatQuickChoice
    case chatLegacyModelRow
    case chatLegacyProviderHeader
    case chatActionMenuProviderHeader

    var hasVisibleProviderName: Bool {
        switch self {
        case .modelPickerProviderHeader, .chatQuickChoice,
             .chatLegacyProviderHeader, .chatActionMenuProviderHeader:
            true
        case .agentRuntimeSelection, .chatSessionCompactControl, .chatLegacyModelRow:
            false
        }
    }
}

enum AIProviderMarkLayout {
    static let centersMarksVertically = true

    static func size(
        for context: AIProviderMarkContext,
        isRegularWidth: Bool
    ) -> CGFloat {
        switch (context, isRegularWidth) {
        case (.agentRuntimeSelection, false): 40
        case (.agentRuntimeSelection, true): 48
        case (.modelPickerProviderHeader, false): 44
        case (.modelPickerProviderHeader, true): 52
        case (.chatSessionCompactControl, false): 24
        case (.chatSessionCompactControl, true): 32
        case (.chatQuickChoice, false): 40
        case (.chatQuickChoice, true): 48
        case (.chatLegacyModelRow, false): 40
        case (.chatLegacyModelRow, true): 48
        case (.chatLegacyProviderHeader, false): 32
        case (.chatLegacyProviderHeader, true): 40
        case (.chatActionMenuProviderHeader, false): 36
        case (.chatActionMenuProviderHeader, true): 44
        }
    }
}

struct AIProviderVisibleIdentity: Equatable, Sendable {
    let rawProviderID: String
    let visibleProviderName: String
    let brand: AIProviderBrand

    static func resolve(
        providerID: String,
        providerName: String
    ) -> AIProviderVisibleIdentity {
        let brand = AIProviderBrandRegistry.resolve(id: providerID, name: providerName)
        return AIProviderVisibleIdentity(
            rawProviderID: providerID,
            visibleProviderName: AIProviderBrandRegistry.displayName(
                id: providerID,
                authoritativeName: providerName
            ),
            brand: brand
        )
    }
}

enum AIProviderMarkPresentation: Equatable, Sendable {
    case official(assetName: String)
    case fallback

    static func resolve(
        brand: AIProviderBrand,
        context: AIProviderMarkContext,
        visibleProviderName: String?
    ) -> AIProviderMarkPresentation {
        switch brand.artwork {
        case let .official(assetName):
            return .official(assetName: assetName)
        case .fallback:
            return .fallback
        }
    }
}

struct AIProviderMarkView: View {
    let providerID: String
    let providerName: String
    let context: AIProviderMarkContext
    let size: CGFloat?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.providerLogoStore) private var providerLogoStore

    init(
        providerID: String,
        providerName: String,
        context: AIProviderMarkContext,
        size: CGFloat? = nil
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.context = context
        self.size = size
    }

    private var brand: AIProviderBrand {
        AIProviderBrandRegistry.resolve(id: providerID, name: providerName)
    }

    private var presentation: AIProviderMarkPresentation {
        AIProviderMarkPresentation.resolve(
            brand: brand,
            context: context,
            visibleProviderName: context.hasVisibleProviderName ? providerName : nil
        )
    }

    @ViewBuilder
    var body: some View {
        let resolvedSize = size ?? AIProviderMarkLayout.size(
            for: context,
            isRegularWidth: horizontalSizeClass == .regular
        )
        switch presentation {
        case let .official(assetName):
            officialArtwork(assetName: assetName, resolvedSize: resolvedSize)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(providerName) provider")
        case .fallback:
            ZStack {
                Circle()
                    .fill(Color(uiColor: .secondarySystemBackground))
                Text(brand.monogram)
                    .font(.system(
                        size: max(8, resolvedSize * 0.38),
                        weight: .bold,
                        design: .rounded
                    ))
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.5)
                    .padding(resolvedSize * 0.12)
            }
            .frame(width: resolvedSize, height: resolvedSize, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(providerName) provider")
        }
    }

    @ViewBuilder
    private func officialArtwork(assetName: String, resolvedSize: CGFloat) -> some View {
        let geometry = brand.officialArtworkGeometry
        let image = providerLogoStore?.image(for: assetName, colorScheme: colorScheme)
            .map { Image(uiImage: $0) } ?? Image(decorative: assetName)
        let artwork = image
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .padding(resolvedSize * geometry.insetFraction)
            .frame(width: resolvedSize, height: resolvedSize, alignment: .center)
            .scaleEffect(geometry.opticalScale)
            .frame(width: resolvedSize, height: resolvedSize, alignment: .center)

        if geometry.clipsToFrame {
            artwork.clipped()
        } else {
            artwork
        }
    }
}
