import SwiftUI
import UIKit

enum MidSessionSendPresentation {
    static let unlockHoldDuration = ChatComposerInteractionPolicy.sendOptionsLongPressDuration

    static func alternatives(
        defaultBehavior: MidSessionChatBehavior
    ) -> [MidSessionChatBehavior] {
        MidSessionChatBehavior.allCases.filter { $0 != defaultBehavior }
    }

    static func unlockProgress(elapsed: TimeInterval) -> Double {
        guard unlockHoldDuration > 0 else { return 1 }
        return min(max(elapsed / unlockHoldDuration, 0), 1)
    }
}

enum AdaptiveComposerActionPresentation {
    static let tintOpacity = 0.82
    /// Painted circle inside the 44pt hit area, matching the attach control.
    static let diameter: CGFloat = ComposerFieldMetrics.controlDiameter
}

struct AdaptiveComposerActionButton: View {
    @Environment(\.loopdyUIV3Enabled) private var uiV3Enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatSurfaceCapabilities) private var capabilities
    let action: ChatComposerPrimaryAction
    private var effectiveAction: ChatComposerPrimaryAction { capabilities.resolve(action) }
    let isBusy: Bool
    let canSend: Bool
    let canStop: Bool
    let onVoice: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let defaultMidSessionBehavior: MidSessionChatBehavior?
    let onMidSessionSend: (MidSessionChatBehavior) -> Void
    var allowedMidSessionBehaviors: [MidSessionChatBehavior] = [.steer, .queued, .interruptAndSend]
    /// Plain-language reason Send is unavailable (read by VoiceOver).
    var unavailableReason: String? = nil

    @State private var isMidSessionOptionsPresented = false
    @State private var unlockProgress: Double = 0
    @State private var holdThresholdReached = false
    @State private var optionsAppeared = false
    @State private var touchIsActive = false
    @State private var touchActiveWhenOptionsAppeared = false
    private let holdObservationEnabled = ProcessInfo.processInfo.arguments.contains("-observe-send-hold")

    var body: some View {
        Group {
            if midSessionAlternatives.isEmpty {
                Button(action: perform) {
                    actionContent
                        .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                        .contentShape(.interaction, Rectangle())
                }
                .buttonStyle(.loopdyPress)
                .disabled(!isEnabled)
            } else {
                actionContent
                    .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                    .contentShape(.interaction, Rectangle())
                    .gesture(midSessionHoldGesture)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            guard isEnabled, !holdThresholdReached else { return }
                            perform()
                        }
                    )
                    .accessibilityAddTraits(.isButton)
                    .disabled(!isEnabled)
            }
        }
        .overlay {
            Circle()
                .trim(from: 0, to: unlockProgress)
                .stroke(
                    uiV3Enabled
                        ? (effectiveAction == .stop
                            ? theme.danger
                            : theme.action)
                        : theme.actionForeground,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(
                    width: AdaptiveComposerActionPresentation.diameter + 6,
                    height: AdaptiveComposerActionPresentation.diameter + 6
                )
                .opacity(unlockProgress > 0 ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .accessibilityIdentifier("chat.send.unlock-progress")
        }
        .sheet(isPresented: $isMidSessionOptionsPresented, onDismiss: {
            holdThresholdReached = false
            touchIsActive = false
            unlockProgress = 0
            optionsAppeared = false
            touchActiveWhenOptionsAppeared = false
        }) {
            MidSessionSendOptionsSheet(
                defaultBehavior: defaultMidSessionBehavior ?? .steer,
                alternatives: midSessionAlternatives,
                onSelect: onMidSessionSend
            )
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
            .onAppear {
                guard holdObservationEnabled else { return }
                optionsAppeared = true
                touchActiveWhenOptionsAppeared = touchIsActive
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityActions {
            ForEach(midSessionAlternatives) { behavior in
                Button("\(behavior.title): \(behavior.detail)") {
                    onMidSessionSend(behavior)
                }
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
        // Confirms the mid-session hold unlocked before the options sheet rises.
        .sensoryFeedback(.impact(weight: .medium), trigger: holdThresholdReached) { _, reached in reached }
    }

    @ViewBuilder
    private var actionContent: some View {
        let content = ZStack {
            Image(systemName: actionSystemImage)
                .font(.system(size: 16, weight: .bold))
                .contentTransition(.symbolEffect(.replace.downUp))
                .opacity(isBusy ? 0 : 1)
            LoopdyThinkingOrb(
                scenario: .composing,
                scale: .inline,
                surface: uiV3Enabled ? .automatic : theme.actionThinkingOrbSurface
            )
                .accessibilityHidden(true)
                .opacity(isBusy ? 1 : 0)
        }
        .foregroundStyle(actionForeground)
        .frame(width: AdaptiveComposerActionPresentation.diameter, height: AdaptiveComposerActionPresentation.diameter)
        .animation(reduceMotion ? nil : .snappy(duration: LoopdyTokens.stateDuration), value: actionSystemImage)
        .animation(reduceMotion ? nil : .easeInOut(duration: LoopdyTokens.stateDuration), value: isBusy)
        content
            .background { actionBackground }
            .opacity(isEnabled || isBusy ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: LoopdyTokens.stateDuration), value: isEnabled)
    }

    private var actionForeground: Color {
        switch effectiveAction {
        case .voice: theme.primaryText
        case .send: theme.actionForeground
        case .stop: .white
        }
    }

    /// Solid circles: accent for Send, danger for Stop, and the quiet incoming
    /// neutral for the voice shortcut shown while the draft is empty.
    private var actionBackground: some View {
        let fill = switch effectiveAction {
        case .voice: theme.incomingMessageBackground
        case .send: theme.action
        case .stop: theme.danger
        }
        return Circle()
            .fill(fill)
            .overlay {
                if colorSchemeContrast == .increased, effectiveAction == .voice {
                    Circle().strokeBorder(theme.primaryText, lineWidth: 1.5)
                }
            }
    }

    private var midSessionHoldGesture: some Gesture {
        LongPressGesture(
            minimumDuration: MidSessionSendPresentation.unlockHoldDuration,
            maximumDistance: MidSessionSendHoldStateMachine.maximumDistance
        )
        .onChanged { _ in
            guard isEnabled else { return }
            touchIsActive = true
            withAnimation(reduceMotion ? nil : .linear(duration: MidSessionSendPresentation.unlockHoldDuration)) {
                unlockProgress = 1
            }
        }
        .onEnded { _ in
            guard isEnabled else { return }
            holdThresholdReached = true
            isMidSessionOptionsPresented = true
        }
    }

    private var isEnabled: Bool {
        guard !isBusy else { return false }
        return switch effectiveAction {
        case .voice: true
        case .send: canSend
        case .stop: canStop
        }
    }

    private var accessibilityLabel: String {
        if isBusy { return effectiveAction == .stop ? "Stopping response" : "Sending message" }
        return switch effectiveAction {
        case .voice: "Open voice chat"
        case .send: isQueueingAttachments ? "Queue attachment" : "Send message"
        case .stop: "Stop response"
        }
    }

    private var accessibilityValue: String {
        if isBusy { return effectiveAction == .stop ? "Stopping" : "Sending" }
        if let defaultMidSessionBehavior, effectiveAction == .send {
            let base = "Default during this active turn: \(defaultMidSessionBehavior.title)"
            guard holdObservationEnabled else { return base }
            return base
                + " thresholdReached=\(holdThresholdReached)"
                + " optionsAppeared=\(optionsAppeared)"
                + " touchActiveWhenOptionsAppeared=\(touchActiveWhenOptionsAppeared)"
        }
        if isEnabled { return "Available" }
        if effectiveAction == .send, let unavailableReason { return "Unavailable, " + unavailableReason }
        return "Unavailable"
    }

    private var accessibilityHint: String {
        if isQueueingAttachments { return "Queues the attachment after the current turn without interrupting it." }
        guard !midSessionAlternatives.isEmpty else { return "" }
        return "Press and hold for 1 second to unlock \(midSessionAlternatives.map(\.title).joined(separator: " or "))."
    }

    private var midSessionAlternatives: [MidSessionChatBehavior] {
        guard effectiveAction == .send, let defaultMidSessionBehavior else { return [] }
        return MidSessionSendPresentation.alternatives(defaultBehavior: defaultMidSessionBehavior)
            .filter { allowedMidSessionBehaviors.contains($0) && capabilities.allows($0) }
    }

    private func perform() {
        switch effectiveAction {
        case .voice:
            onVoice()
        case .send:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSend()
        case .stop:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            onStop()
        }
    }

    private var isQueueingAttachments: Bool {
        defaultMidSessionBehavior == .queued && allowedMidSessionBehaviors == [.queued]
    }

    private var actionSystemImage: String {
        switch effectiveAction {
        case .voice: uiV3Enabled ? "mic" : "waveform"
        case .send: isQueueingAttachments ? "clock.arrow.circlepath" : "arrow.up"
        case .stop: "stop.fill"
        }
    }

    private var accessibilityIdentifier: String {
        switch effectiveAction {
        case .voice: "chat.voice"
        case .send: "chat.send"
        case .stop: "chat.stop"
        }
    }

    @LoopdyThemeReader private var theme: LoopdyTheme

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
}

private struct MidSessionSendOptionsSheet: View {
    let defaultBehavior: MidSessionChatBehavior
    let alternatives: [MidSessionChatBehavior]
    let onSelect: (MidSessionChatBehavior) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
            VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                Text("Send another way")
                    .loopdyFont(.sectionTitle, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Text("Tap sends with \(defaultBehavior.title). Choose a one-time alternative below.")
                    .loopdyFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
            }

            VStack(spacing: LoopdyTokens.space8) {
                ForEach(alternatives) { behavior in
                    Button {
                        dismiss()
                        onSelect(behavior)
                    } label: {
                        VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                            Text(behavior.title)
                                .loopdyFont(.label)
                                .foregroundStyle(theme.primaryText)
                            Text(behavior.detail)
                                .loopdyFont(.metadata)
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget, alignment: .leading)
                        .padding(.horizontal, LoopdyTokens.space12)
                        .padding(.vertical, LoopdyTokens.space8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .loopdySurface(.capsuleControl, isInteractive: true)
                    .accessibilityLabel(behavior.title)
                    .accessibilityHint(behavior.detail)
                    .accessibilityIdentifier("chat.send.mid-session.\(behavior.rawValue)")
                }
            }
        }
        .padding(LoopdyTokens.space20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LoopdyThemeCanvas(theme: theme).ignoresSafeArea())
        .accessibilityIdentifier("chat.send.mid-session.options")
    }

    @LoopdyThemeReader private var theme: LoopdyTheme

}
