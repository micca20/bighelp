import SwiftUI

struct LoopdyReasoningChoice: Identifiable, Equatable, Sendable {
    let value: String
    let label: String
    let detail: String

    var id: String { value.isEmpty ? "automatic" : value }
}

struct LoopdyReasoningLevelControl: View {
    let choices: [LoopdyReasoningChoice]
    let selectedValue: String?
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let onSelect: (String) -> Void
    var isEmbedded = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.isEnabled) private var environmentEnabled
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.loopdyUIV2Enabled) private var uiV2Enabled
    @Environment(\.loopdyUIV3Enabled) private var uiV3Enabled
    @GestureState private var dragProgress: CGFloat? = nil
    @State private var lastDragIndex: Int?
    @State private var selectionFeedback = false

    private let thumbDiameter: CGFloat = 28
    private let tickDiameter: CGFloat = 8

    var body: some View {
        if choices.isEmpty {
            unavailableState
        } else {
            Group {
                if uiV3Enabled {
                    nativeControl
                } else if isEmbedded {
                    controlContent
                } else {
                    LoopdyMenuPanel { controlContent.padding(LoopdyTokens.space12) }
                }
            }
            .accessibilityElement(children: uiV3Enabled ? .contain : .ignore)
            .accessibilityLabel("Reasoning level")
            .accessibilityValue(selectedChoice?.label ?? "Not selected")
            .accessibilityHint(canAdjust
                ? "Swipe up or down to change the reasoning level."
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
        VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
            selectionSummary
            discreteTrack
            endpointLabels
        }
    }

    private var nativeControl: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
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
            .font(.body)

            if let selectedChoice {
                Text(selectedChoice.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
            HStack(alignment: .firstTextBaseline, spacing: LoopdyTokens.space8) {
                Text("Reasoning")
                    .loopdyFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: LoopdyTokens.space8)
                Text(positionLabel)
                    .loopdyFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.action)
            }

            Text(selectedChoice?.label ?? "Choose a level")
                .loopdyFont(.sectionTitle, weight: .bold)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text(selectedChoice?.detail ?? "Move the control to select a supported level.")
                .loopdyFont(.metadata)
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
            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
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
        .frame(height: LoopdyTokens.hitTarget)
        // Coordinates below are physical; mirror progress explicitly rather
        // than also mirroring the ZStack leading alignment in RTL locales.
        .environment(\.layoutDirection, .leftToRight)
        .id(choices.map(\.value))
        .animation(
            reduceMotion || dragProgress != nil ? nil : .easeOut(duration: LoopdyTokens.stateDuration),
            value: dragProgress
        )
        .animation(
            reduceMotion || uiV2Enabled ? nil : .easeOut(duration: LoopdyTokens.stateDuration),
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
                        .stroke(theme.surface.opacity(0.7), lineWidth: LoopdyTokens.hairline)
                }
                .frame(width: tickDiameter, height: tickDiameter)
                .offset(
                    x: (usableWidth * visualProgress(for: index)) + ((thumbDiameter - tickDiameter) / 2)
                )
                .accessibilityHidden(true)
        }
    }

    private var endpointLabels: some View {
        HStack(alignment: .top, spacing: LoopdyTokens.space12) {
            Text(choices.first?.label ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
            if choices.count > 1 {
                Text(choices.last?.label ?? "")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .loopdyFont(.metadata, weight: .semibold)
        .foregroundStyle(theme.secondaryText)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
        .accessibilityHidden(true)
    }

    private var unavailableState: some View {
        LoopdyMenuPanel {
            VStack(spacing: LoopdyTokens.space12) {
                Image(systemName: "brain.head.profile")
                    .reflectiveVisionIcon()
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityHidden(true)
                Text("No reasoning controls")
                    .loopdyFont(.label, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Text("The selected model does not offer adjustable reasoning levels.")
                    .loopdyFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 132)
            .padding(LoopdyTokens.space12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(accessibilityIdentifier).unavailable")
    }

    private var selectedIndex: Int? {
        choices.firstIndex(where: { $0.value == selectedValue })
    }

    private var selectedChoice: LoopdyReasoningChoice? {
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

    @LoopdyThemeReader private var theme
}
