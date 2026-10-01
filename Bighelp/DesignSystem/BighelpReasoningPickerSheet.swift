import SwiftUI

struct BighelpReasoningChoice: Identifiable, Equatable, Sendable {
    let value: String
    let label: String
    let detail: String

    var id: String { value.isEmpty ? "automatic" : value }
}

struct BighelpReasoningLevelControl: View {
    let choices: [BighelpReasoningChoice]
    let selectedValue: String?
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let onSelect: (String) -> Void
    var isEmbedded = false
    /// Mac: start with keyboard focus here, so the arrow keys change the level
    /// right away. Pickers with a search field leave focus in the field.
    var takesKeyboardFocus = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.isEnabled) private var environmentEnabled
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.bighelpUIV2Enabled) private var uiV2Enabled
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @GestureState private var dragProgress: CGFloat? = nil
    @State private var lastDragIndex: Int?
    @State private var selectionFeedback = false
    #if targetEnvironment(macCatalyst)
    @FocusState private var isKeyboardFocused: Bool
    #endif

    private let thumbDiameter: CGFloat = 28
    private let tickDiameter: CGFloat = 8

    var body: some View {
        if choices.isEmpty {
            unavailableState
        } else {
            Group {
                #if targetEnvironment(macCatalyst)
                // A drag track and a pop-up menu both need the mouse; the Mac
                // shows every level to click, and the arrow keys step through them.
                macControl
                #else
                if uiV3Enabled {
                    nativeControl
                } else if isEmbedded {
                    controlContent
                } else {
                    BighelpMenuPanel { controlContent.padding(BighelpTokens.space12) }
                }
                #endif
            }
            .accessibilityElement(children: uiV3Enabled || BighelpPlatform.isMac ? .contain : .ignore)
            .accessibilityLabel("Reasoning level")
            .accessibilityValue(selectedChoice?.label ?? "Not selected")
            .accessibilityHint(canAdjust
                ? (BighelpPlatform.isMac
                    ? "Choose a level. The arrow keys also change it."
                    : "Swipe up or down to change the reasoning level.")
                : choices.count == 1 ? "Only one reasoning level is available." : "Reasoning is currently unavailable.")
            .accessibilityAdjustableAction(adjustSelection)
            .accessibilityIdentifier(accessibilityIdentifier)
            .opacity(isEnabled && environmentEnabled ? 1 : 0.48)
            .disabled(!isEnabled || !environmentEnabled)
            .sensoryFeedback(.selection, trigger: selectionFeedback)
            .onChange(of: dragProgress) { _, progress in
                if progress == nil { lastDragIndex = nil }
            }
            .onChange(of: choices) { _, _ in lastDragIndex = nil }
        }
    }

    private var controlContent: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            selectionSummary
            discreteTrack
            endpointLabels
        }
    }

    private var nativeControl: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            LabeledContent("Reasoning") {
                Picker("Reasoning", selection: Binding(
                    get: { selectedValue ?? choices.first?.value ?? "" },
                    set: onSelect
                )) {
                    ForEach(choices) { choice in
                        Text(choice.label).tag(choice.value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .font(.bighelp(.body))

            if let selectedChoice {
                Text(selectedChoice.detail)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if targetEnvironment(macCatalyst)
    private var macControl: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BighelpTokens.space4) { macChoiceButtons }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: BighelpTokens.scaled(88)), spacing: BighelpTokens.space4)],
                          spacing: BighelpTokens.space4) { macChoiceButtons }
            }
            if let selectedChoice {
                Text(selectedChoice.detail)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable(canAdjust)
        .focused($isKeyboardFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard canAdjust else { return .ignored }
            let towardHigher = switch press.key {
            case .rightArrow: layoutDirection == .leftToRight
            case .leftArrow: layoutDirection == .rightToLeft
            case .upArrow: true
            default: false
            }
            adjustSelection(towardHigher ? .increment : .decrement)
            return .handled
        }
        .onAppear {
            guard takesKeyboardFocus, canAdjust else { return }
            // Focus only takes once the control is in its window.
            Task { @MainActor in isKeyboardFocused = true }
        }
    }

    private var macChoiceButtons: some View {
        ForEach(choices) { choice in
            let selected = choice.value == selectedValue
            Button {
                if !selected { onSelect(choice.value) }
                // After a click the arrow keys carry on from here.
                isKeyboardFocused = true
            } label: {
                Text(choice.label)
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(selected ? theme.actionForeground : theme.primaryText)
                    .padding(.horizontal, BighelpTokens.space12)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.scaled(34))
                    .background(selected ? theme.action : theme.surface, in: .capsule)
                    .overlay {
                        Capsule().stroke(selected ? theme.action : theme.border, lineWidth: BighelpTokens.hairline)
                    }
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("\(accessibilityIdentifier).\(choice.id)")
        }
    }
    #endif

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                Text("Reasoning")
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: BighelpTokens.space8)
                Text(positionLabel)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.action)
            }

            Text(selectedChoice?.label ?? "Choose a level")
                .bighelpFont(.sectionTitle, weight: .bold)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text(selectedChoice?.detail ?? "Move the control to select a supported level.")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var discreteTrack: some View {
        GeometryReader { proxy in
            let usableWidth = max(proxy.size.width - thumbDiameter, 1)
            let progress = dragProgress ?? selectionProgress
            let visualProgress = layoutDirection == .rightToLeft ? 1 - progress : progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.secondaryText.opacity(0.18))
                    .frame(height: 8)
                    .padding(.horizontal, thumbDiameter / 2)

                if uiV2Enabled {
                    LinearGradient(colors: reasoningColors, startPoint: .leading, endPoint: .trailing)
                        .frame(width: usableWidth, height: 8)
                        .mask(alignment: layoutDirection == .rightToLeft ? .trailing : .leading) {
                            Rectangle().frame(width: usableWidth * progress)
                        }
                        .clipShape(.capsule)
                        .padding(.horizontal, thumbDiameter / 2)
                } else {
                    LinearGradient(colors: reasoningColors, startPoint: .leading, endPoint: .trailing)
                        .frame(width: thumbDiameter + (usableWidth * progress), height: 8)
                        .clipShape(.capsule)
                }

                tickMarks(usableWidth: usableWidth)

                Circle()
                    .fill(theme.raisedSurface)
                    .overlay {
                        Circle()
                            .strokeBorder(theme.action, lineWidth: 3)
                    }
                    .shadow(
                        color: theme.primaryText.opacity(colorScheme == .dark ? 0.24 : 0.12),
                        radius: 4,
                        y: 2
                    )
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(x: usableWidth * visualProgress)
            }
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragProgress) { value, progress, transaction in
                        guard uiV2Enabled, canAdjust else { return }
                        transaction.animation = nil
                        progress = normalizedProgress(at: value.location.x, width: usableWidth)
                    }
                    .onChanged { value in
                        guard canAdjust else { return }
                        let index = nearestIndex(at: value.location.x, width: usableWidth)
                        if !uiV2Enabled {
                            if index != selectedIndex { onSelect(choices[index].value) }
                            return
                        }
                        let previousIndex = lastDragIndex ?? selectedIndex
                        if let previousIndex, previousIndex != index {
                            selectionFeedback.toggle()
                        }
                        lastDragIndex = index
                    }
                    .onEnded { value in
                        guard uiV2Enabled, canAdjust else { return }
                        // Commit once on release, not once per drag frame. This
                        // keeps remote applying state from interrupting a drag.
                        let index = nearestIndex(at: value.location.x, width: usableWidth)
                        if index != selectedIndex { onSelect(choices[index].value) }
                        lastDragIndex = nil
                    }
            )
        }
        .frame(height: BighelpTokens.hitTarget)
        // Coordinates below are physical; mirror progress explicitly rather
        // than also mirroring the ZStack leading alignment in RTL locales.
        .environment(\.layoutDirection, .leftToRight)
        .id(choices.map(\.value))
        .animation(
            reduceMotion || dragProgress != nil ? nil : .easeOut(duration: BighelpTokens.stateDuration),
            value: dragProgress
        )
        .animation(
            reduceMotion || uiV2Enabled ? nil : .easeOut(duration: BighelpTokens.stateDuration),
            value: selectedIndex
        )
        .allowsHitTesting(canAdjust)
    }

    private func tickMarks(usableWidth: CGFloat) -> some View {
        ForEach(choices.indices, id: \.self) { index in
            Circle()
                .fill(index <= (displayedIndex ?? -1) ? theme.actionForeground : theme.tertiaryText)
                .overlay {
                    Circle()
                        .stroke(theme.surface.opacity(0.7), lineWidth: BighelpTokens.hairline)
                }
                .frame(width: tickDiameter, height: tickDiameter)
                .offset(
                    x: (usableWidth * visualProgress(for: index)) + ((thumbDiameter - tickDiameter) / 2)
                )
                .accessibilityHidden(true)
        }
    }

    private var endpointLabels: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Text(choices.first?.label ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
            if choices.count > 1 {
                Text(choices.last?.label ?? "")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .bighelpFont(.metadata, weight: .semibold)
        .foregroundStyle(theme.secondaryText)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
        .accessibilityHidden(true)
    }

    private var unavailableState: some View {
        BighelpMenuPanel {
            VStack(spacing: BighelpTokens.space12) {
                Image(systemName: "brain.head.profile")
                    .reflectiveVisionIcon()
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityHidden(true)
                Text("No reasoning controls")
                    .bighelpFont(.label, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Text("The selected model does not offer adjustable reasoning levels.")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 132)
            .padding(BighelpTokens.space12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(accessibilityIdentifier).unavailable")
    }

    private var selectedIndex: Int? {
        choices.firstIndex(where: { $0.value == selectedValue })
    }

    private var selectedChoice: BighelpReasoningChoice? {
        displayedIndex.map { choices[$0] }
    }

    private var selectionProgress: CGFloat {
        guard choices.count > 1, let selectedIndex else { return 0 }
        return progress(for: selectedIndex)
    }

    private var positionLabel: String {
        guard let displayedIndex else { return "\(choices.count) levels" }
        return "\(displayedIndex + 1) of \(choices.count)"
    }

    private func progress(for index: Int) -> CGFloat {
        guard choices.count > 1 else { return 0 }
        return CGFloat(index) / CGFloat(choices.count - 1)
    }

    private var canAdjust: Bool {
        isEnabled && environmentEnabled && choices.count > 1
    }

    private var displayedIndex: Int? {
        guard !choices.isEmpty else { return nil }
        if let dragProgress, canAdjust {
            return Int((dragProgress * CGFloat(choices.count - 1)).rounded())
        }
        return selectedIndex
    }

    private var reasoningColors: [Color] {
        [theme.action, theme.action]
    }

    private func visualProgress(for index: Int) -> CGFloat {
        layoutDirection == .rightToLeft ? 1 - progress(for: index) : progress(for: index)
    }

    private func normalizedProgress(at location: CGFloat, width: CGFloat) -> CGFloat {
        let raw = min(max((location - thumbDiameter / 2) / max(width, 1), 0), 1)
        return layoutDirection == .rightToLeft ? 1 - raw : raw
    }

    private func nearestIndex(at location: CGFloat, width: CGFloat) -> Int {
        Int((normalizedProgress(at: location, width: width) * CGFloat(choices.count - 1)).rounded())
    }

    private func adjustSelection(_ direction: AccessibilityAdjustmentDirection) {
        guard canAdjust else { return }
        if uiV2Enabled, selectedIndex == nil, let first = choices.first {
            onSelect(first.value)
            return
        }
        let currentIndex = selectedIndex ?? 0
        let targetIndex: Int
        switch direction {
        case .increment:
            targetIndex = min(currentIndex + 1, choices.count - 1)
        case .decrement:
            targetIndex = max(currentIndex - 1, 0)
        @unknown default:
            return
        }
        guard targetIndex != selectedIndex else { return }
        if uiV2Enabled, selectedIndex != nil { selectionFeedback.toggle() }
        onSelect(choices[targetIndex].value)
    }

    @BighelpThemeReader private var theme
}
