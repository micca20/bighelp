import SwiftUI

/// Native live voice keeps configuration in Settings. This surface owns only
/// the explicit media lifecycle and the two local audio mute controls.
struct LiveVoiceView: View {
    @State private var model: LiveVoiceModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var captionSize: CGFloat = 24
    let agentID: String?
    let agentImageURL: URL?
    let onEnded: () -> Void
    /// Switches Settings to turn-based voice (listens on the phone, answers
    /// with the host's text-to-speech) and reopens voice. Offered only after
    /// live voice fails.
    let onUseTurnBased: (() -> Void)?

    init(
        model: LiveVoiceModel,
        agentID: String? = nil,
        agentImageURL: URL? = nil,
        onEnded: @escaping () -> Void = {},
        onUseTurnBased: (() -> Void)? = nil
    ) {
        _model = State(initialValue: model)
        self.agentID = agentID
        self.agentImageURL = agentImageURL
        self.onEnded = onEnded
        self.onUseTurnBased = onUseTurnBased
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: LoopdyTokens.space24) {
                        Text(model.phase.title)
                            .loopdyFont(.metadata, weight: .semibold)
                            .foregroundStyle(theme.secondaryText)
                            .accessibilityIdentifier("live-voice.status")
                        Spacer(minLength: LoopdyTokens.space16)
                        AvatarView(
                            stableID: agentID ?? model.agentName,
                            displayName: model.agentName,
                            imageURL: agentImageURL,
                            size: dynamicTypeSize.isAccessibilitySize ? 140 : 200,
                            state: liveState
                        )
                        .accessibilityHidden(true)
                        Text(captionText)
                            .font(.system(size: captionSize, weight: .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(hasCaption ? theme.primaryText : theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .lineLimit(6)
                            .truncationMode(.head)
                            .frame(maxWidth: 520)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.workStatus != .idle {
                            Label(model.workStatus.title, systemImage: model.workStatus.systemImage)
                                .loopdyFont(.label, weight: .semibold)
                                .foregroundStyle(theme.secondaryText)
                        }
                        messages
                        Spacer(minLength: LoopdyTokens.space16)
                        Text("Stopping voice does not cancel work Hermes already accepted.")
                            .loopdyFont(.metadata)
                            .foregroundStyle(theme.tertiaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, LoopdyTokens.space20)
                    .padding(.vertical, LoopdyTokens.space12)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            controls
                .frame(maxWidth: 560)
                .padding(.horizontal, LoopdyTokens.space16)
                .padding(.top, LoopdyTokens.space8)
                .padding(.bottom, LoopdyTokens.space16)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(theme.primaryText)
        .tint(theme.action)
        .background { VoiceStageBackground(agentColor: AgentPersona(stableID: agentID ?? model.agentName).color) }
        .navigationTitle("Live voice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    model.end()
                    onEnded()
                }
                .frame(minWidth: LoopdyTokens.hitTarget, minHeight: LoopdyTokens.hitTarget)
                .accessibilityHint("Stops live audio. Accepted tasks are not cancelled.")
                .accessibilityIdentifier("live-voice.close")
            }
            ToolbarItem(placement: .principal) {
                statusPill
            }
        }
        .onDisappear { model.end() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.end() }
        }
        // Contain, so the controls keep their own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live-voice.screen")
    }

    /// "● Agent · state" — the same pill as turn-based voice.
    private var statusPill: some View {
        HStack(spacing: LoopdyTokens.space8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)
            Text("\(model.agentName) · \(statusText)")
                .loopdyFont(.label, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(theme.primaryText)
        .padding(.horizontal, LoopdyTokens.space16)
        .padding(.vertical, LoopdyTokens.space8)
        .background(theme.surface.opacity(theme.isDarkPalette ? 0.72 : 0.6), in: .capsule)
        .overlay { Capsule().stroke(theme.border, lineWidth: LoopdyTokens.hairline) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.agentName), \(statusText)")
        .accessibilityAddTraits(.isHeader)
    }

    /// Derived only from live-call facts: delegated Hermes work, streaming
    /// assistant speech, or an open microphone.
    private var liveState: AgentLiveState {
        guard model.phase == .live else { return .idle }
        if model.workStatus == .working { return .thinking }
        if !model.assistantCaption.isEmpty { return .speaking }
        return model.isMuted ? .idle : .listening
    }

    private var statusText: String {
        model.phase == .live ? liveState.label : model.phase.title
    }

    private var statusDotColor: Color {
        switch model.phase {
        case .live: liveState.dotColor
        case .failed: theme.danger
        case .interrupted, .preparing, .connecting: theme.warning
        case .idle, .ended: AgentLiveState.idle.dotColor
        }
    }

    private var captionText: String {
        if !model.assistantCaption.isEmpty { return model.assistantCaption }
        if !model.userCaption.isEmpty { return model.userCaption }
        if let last = model.transcripts.last { return last.text }
        if model.isCallOpen { return "Start speaking when you’re ready" }
        return model.phase == .failed ? "Live voice didn’t connect" : "Tap Start to talk live"
    }

    private var hasCaption: Bool {
        !model.assistantCaption.isEmpty || !model.userCaption.isEmpty || !model.transcripts.isEmpty
    }

    @ViewBuilder
    private var controls: some View {
        if model.isCallOpen {
            HStack(alignment: .center, spacing: LoopdyTokens.space20) {
                audioButton(
                    title: model.isMuted ? "Unmute microphone" : "Mute microphone",
                    systemImage: model.isMuted ? "mic.slash.fill" : "mic.fill",
                    isSelected: model.isMuted,
                    identifier: "live-voice.mute"
                ) { model.setMuted(!model.isMuted) }
                    .disabled(!model.canControlAudio)

                Button(role: .destructive) { model.end() } label: {
                    HStack(spacing: LoopdyTokens.space8) {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .accessibilityHidden(true)
                        Text("End")
                            .loopdyFont(.body, weight: .semibold)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, LoopdyTokens.space24)
                    .frame(minWidth: 112, minHeight: 64)
                    .background(Color(hex: "D33F42"), in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop live voice")
                .accessibilityHint("Stops microphone and playback. Accepted tasks continue independently.")
                .accessibilityIdentifier("live-voice.end")

                audioButton(
                    title: model.isSpeakerMuted ? "Unmute speaker" : "Mute speaker",
                    systemImage: model.isSpeakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    isSelected: model.isSpeakerMuted,
                    identifier: "live-voice.speaker"
                ) { model.setSpeakerMuted(!model.isSpeakerMuted) }
                    .disabled(!model.canControlAudio)
            }
        } else {
            VStack(spacing: LoopdyTokens.space12) {
                Button { model.start() } label: {
                    Label(model.phase == .failed ? "Try again" : "Start live voice",
                          systemImage: model.phase == .failed ? "arrow.clockwise" : "waveform")
                        .loopdyFont(.body, weight: .semibold)
                        .foregroundStyle(theme.actionForeground)
                        .padding(.horizontal, LoopdyTokens.space24)
                        .frame(maxWidth: 320, minHeight: 56)
                        .background(theme.action, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .opacity(model.canStart ? 1 : 0.5)
                .disabled(!model.canStart)
                .accessibilityIdentifier("live-voice.start")
                if model.phase == .failed, let onUseTurnBased {
                    Button("Use turn-based voice", action: onUseTurnBased)
                        .loopdyFont(.body, weight: .semibold)
                        .foregroundStyle(theme.action)
                        .frame(minHeight: LoopdyTokens.hitTarget)
                        .accessibilityHint("Listens on this phone and answers in the voice set up on your computer. You can switch back in Settings › Voice.")
                        .accessibilityIdentifier("live-voice.use-turn-based")
                }
            }
        }
    }

    private func audioButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
                .frame(width: 64, height: 64)
                .background(isSelected ? theme.action : theme.surface, in: .circle)
                .overlay {
                    Circle().stroke(isSelected ? theme.action : theme.border, lineWidth: LoopdyTokens.hairline)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Muted" : "On")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var messages: some View {
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(theme.danger)
                .loopdyFont(.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("live-voice.error")
        }
        if let cleanup = model.cleanupMessage {
            Text(cleanup)
                .foregroundStyle(theme.secondaryText)
                .loopdyFont(.metadata)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @LoopdyThemeReader private var theme
}
