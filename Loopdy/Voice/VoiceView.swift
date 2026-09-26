import SwiftUI

struct VoiceView: View {
    @Environment(\.companionStore) private var companionStore
    @Environment(\.companionAgentScope) private var companionAgentScope
    @State private var model: VoiceModel
    @State private var isVoiceVisible = false
    @GestureState private var walkieGestureActive = false
    @State private var walkieGestureGeneration: UInt64?
    @State private var isTranscriptExpanded = false
    @ScaledMetric(relativeTo: .title2) private var captionSize: CGFloat = 24
    let agentID: String?
    let agentImageURL: URL?
    let transcriptRows: [VoiceTranscriptRow]?
    let permissionCenter: PermissionCenter?
    let onEnded: () -> Void
    let onWorkspaceTap: () -> Void

    init(
        model: VoiceModel,
        agentID: String? = nil,
        agentImageURL: URL? = nil,
        transcriptRows: [VoiceTranscriptRow]? = nil,
        showsTranscript: Bool = false,
        permissionCenter: PermissionCenter? = nil,
        onEnded: @escaping () -> Void = {},
        onWorkspaceTap: @escaping () -> Void = {}
    ) {
        _model = State(initialValue: model)
        self.agentID = agentID
        self.agentImageURL = agentImageURL
        self.transcriptRows = transcriptRows
        _isTranscriptExpanded = State(initialValue: showsTranscript)
        self.permissionCenter = permissionCenter
        self.onEnded = onEnded
        self.onWorkspaceTap = onWorkspaceTap
    }

    var body: some View {
        voiceLayout
        .background { VoiceStageBackground(agentColor: agentPersona.color) }
        .accessibilityIdentifier("voice.screen")
        .onAppear {
            isVoiceVisible = true
            model.setReduceMotion(reduceMotion)
            reconcileMonitoring(for: scenePhase)
        }
        .task { await authorizeVoiceInput() }
        .onDisappear {
            isVoiceVisible = false
            walkieGestureGeneration = nil
            model.setMonitoringAllowed(false)
            model.cancelWalkieTalkieCapture()
            model.stopMonitoring()
        }
        .onChange(of: model.status) { _, _ in
            reconcileMonitoring(for: scenePhase)
        }
        .onChange(of: model.isMicrophoneMuted) { _, _ in
            reconcileMonitoring(for: scenePhase)
        }
        .onChange(of: model.meterState) { _, state in
            guard state == .unavailable, let permissionCenter else { return }
            Task {
                await permissionCenter.refresh(.microphone)
                await permissionCenter.refresh(.speech)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                model.cancelWalkieTalkieCapture()
            }
            reconcileMonitoring(for: phase)
        }
        .onChange(of: permissionCenter?.status(for: .microphone).authorization) { _, _ in
            reconcileMonitoring(for: scenePhase)
        }
        .onChange(of: permissionCenter?.status(for: .speech).authorization) { _, _ in
            reconcileMonitoring(for: scenePhase)
        }
        .onChange(of: reduceMotion) { _, enabled in
            model.setReduceMotion(enabled)
            reconcileMonitoring(for: scenePhase)
        }

    }

    private var voiceLayout: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: LoopdyTokens.space8) {
                WorkspaceMenuButton(accessibilityIdentifier: "voice.workspace-menu", action: onWorkspaceTap)
                authoritativeStatus
                    .frame(maxWidth: .infinity)
                // Balances the menu button so the status pill stays centered.
                Color.clear.frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
            }
            .padding(.horizontal, LoopdyTokens.space16)
            .padding(.vertical, LoopdyTokens.space8)
            .loopdyShellContentWidth()
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: LoopdyTokens.space24) {
                        Spacer(minLength: LoopdyTokens.space24)
                        orb(size: stageAvatarSize)
                        caption
                        VoiceWaveformBars(level: waveformLevel, color: agentPersona.color)
                        endFailure
                        permissionRecovery
                        Spacer(minLength: LoopdyTokens.space16)
                        transcript
                    }
                    .padding(.horizontal, LoopdyTokens.space20)
                    .padding(.bottom, LoopdyTokens.space16)
                    .frame(minHeight: proxy.size.height)
                    .loopdyShellContentWidth()
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            controls
                .frame(maxWidth: 620)
                .padding(.horizontal, LoopdyTokens.space16)
                .padding(.top, LoopdyTokens.space8)
                .padding(.bottom, LoopdyTokens.space16)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("voice.controls")
        }
    }

    /// The avatar owns the stage; large accessibility text sizes give some of
    /// that room back to the caption.
    private var stageAvatarSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 140 : 200
    }

    /// The one line that matters right now: what the agent is saying, else what
    /// you are saying, else the last finished turn.
    private var caption: some View {
        Text(captionText)
            .font(.system(size: captionSize, weight: .semibold))
            .tracking(-0.2)
            .foregroundStyle(hasCaption ? theme.primaryText : theme.secondaryText)
            .multilineTextAlignment(.center)
            .lineLimit(6)
            .truncationMode(.head)
            .frame(maxWidth: 520)
            .padding(.horizontal, LoopdyTokens.space12)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("voice.caption")
    }

    private var captionText: String {
        if let draft = model.liveAgentTranscript, !draft.isEmpty { return draft }
        if let partial = model.partialUserTranscript, !partial.isEmpty { return partial }
        if let last = displayedTranscriptRows.last { return last.text }
        return "Start speaking when you’re ready"
    }

    private var hasCaption: Bool {
        !(model.liveAgentTranscript ?? "").isEmpty
            || !(model.partialUserTranscript ?? "").isEmpty
            || !displayedTranscriptRows.isEmpty
    }

    /// Bars follow real audio: playback while the agent speaks, otherwise the
    /// microphone meter. Muted or inactive sessions rest.
    private var waveformLevel: Double {
        guard model.isActive else { return 0 }
        if model.isPlaybackActive { return model.isAgentAudioMuted ? 0 : model.outputLevel }
        guard !model.isMicrophoneMuted, model.meterState == .monitoring else { return 0 }
        return Double(model.inputLevel)
    }

    private var agentPersona: AgentPersona {
        AgentPersona(stableID: agentID ?? model.agentName)
    }

    /// Voice status mapped onto the shared avatar vocabulary.
    private var liveState: AgentLiveState {
        switch model.status {
        case .listening: .listening
        case .working: .thinking
        case .speaking: .speaking
        case .paused, .unavailable: .idle
        }
    }

    private var statusText: String {
        switch model.status {
        case .listening, .working, .speaking: liveState.label
        case .paused, .unavailable: model.status.label
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space12) {
            Button {
                isTranscriptExpanded.toggle()
            } label: {
                HStack(spacing: LoopdyTokens.space8) {
                    Text("Transcript")
                        .loopdyFont(.label, weight: .semibold)
                    Spacer(minLength: LoopdyTokens.space8)
                    Image(systemName: "chevron.down")
                        .loopdyFont(.metadata, weight: .semibold)
                        .rotationEffect(.degrees(isTranscriptExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Transcript")
            .accessibilityValue(isTranscriptExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("voice.transcript.toggle")
            if isTranscriptExpanded {
                if displayedTranscriptRows.isEmpty,
                   model.partialUserTranscript == nil, model.liveAgentTranscript == nil {
                    Text("Start speaking when you’re ready")
                        .loopdyFont(.body)
                        .foregroundStyle(theme.secondaryText)
                }
                ForEach(displayedTranscriptRows) { row in
                    transcriptCard(row)
                }
                if let partial = model.partialUserTranscript, !partial.isEmpty {
                    transcriptCard(VoiceTranscriptRow(id: "voice-partial-user", speaker: "You", time: "Now", text: partial), isLive: true)
                }
                if let draft = model.liveAgentTranscript, !draft.isEmpty {
                    transcriptCard(VoiceTranscriptRow(id: "voice-partial-agent", speaker: model.agentName, time: "Now", text: draft), isLive: true)
                }
                Label("Choose your speaking mode in Voice settings.", systemImage: "slider.horizontal.3")
                    .loopdyFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice.transcript")
    }

    @ViewBuilder
    private func orb(size: CGFloat) -> some View {
        if let companionStore, companionStore.isEnabled {
            let companionSide = size * CGFloat(min(1, companionStore.sizeScale))
            CompanionAvatar(
                appearance: voiceCompanionAppearance(from: companionStore),
                reaction: voiceCompanionReaction,
                isAnimating: isVoiceVisible && scenePhase == .active && model.isActive,
                audioLevel: model.isPlaybackActive ? model.outputLevel : 0
            )
            .frame(width: companionSide, height: companionSide)
            .allowsHitTesting(false)
            .accessibilityIdentifier("companion-voice")
            // The voice controls own a fixed safe slot; larger preferences stop
            // at that slot instead of covering status text or the End button.
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity)
        } else {
            AvatarView(
                stableID: agentID ?? model.agentName,
                displayName: model.agentName,
                imageURL: agentImageURL,
                size: size,
                state: liveState
            )
            .scaleEffect(avatarPulseScale)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: avatarPulseScale)
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity)
        }
    }

    private func voiceCompanionAppearance(from store: CompanionStore) -> CompanionAppearance {
        guard let agentID, !companionAgentScope.isEmpty else { return store.defaultAppearance }
        return store.appearance(
            for: CompanionStore.agentKey(agentScope: companionAgentScope, agentID: agentID)
        )
    }

    private var voiceCompanionReaction: CompanionReaction {
        CompanionVoiceSignal.reaction(
            status: model.status,
            playbackActive: model.isPlaybackActive,
            microphoneMonitoring: voiceInputIsAuthorized && !model.isMicrophoneMuted
                && model.meterState == .monitoring
        )
    }

    private func reconcileMonitoring(for phase: ScenePhase) {
        let allowed = isVoiceVisible && phase == .active && voiceInputIsAuthorized
        model.setMonitoringAllowed(allowed)
        guard allowed,
              model.isActive,
              !model.isMicrophoneMuted,
              model.allowsInputMonitoring,
              voiceInputIsAuthorized
        else {
            model.stopMonitoring()
            return
        }
        Task { await model.startMonitoring() }
    }

    private var voiceInputIsAuthorized: Bool {
        guard let permissionCenter else { return true }
        return permissionCenter.status(for: .microphone).authorization == .authorized
            && permissionCenter.status(for: .speech).authorization == .authorized
    }

    private func authorizeVoiceInput() async {
        guard let permissionCenter else {
            reconcileMonitoring(for: scenePhase)
            return
        }
        guard await permissionCenter.authorizeContextualAccess(.microphone) else {
            model.stopMonitoring()
            return
        }
        guard await permissionCenter.authorizeContextualAccess(.speech) else {
            model.stopMonitoring()
            return
        }
        reconcileMonitoring(for: scenePhase)
    }

    private var authoritativeStatus: some View {
        HStack(spacing: LoopdyTokens.space8) {
            Circle()
                .fill(statusIndicatorColor)
                .frame(width: 8, height: 8)
            Text("\(model.agentName) · \(statusText)")
                .loopdyFont(.label, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(theme.primaryText)
        .padding(.horizontal, LoopdyTokens.space16)
        .padding(.vertical, VoiceViewPresentation.statusVerticalPadding)
        .background(theme.surface.opacity(theme.isDarkPalette ? 0.72 : 0.6), in: .capsule)
        .overlay {
            Capsule()
                .stroke(theme.border, lineWidth: LoopdyTokens.hairline)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.status.label)
        .accessibilityValue(model.status == .working ? "In progress" : "")
        .accessibilityIdentifier("voice.status")
    }

    private var statusIndicatorColor: Color {
        switch model.status {
        case .listening, .working, .speaking:
            liveState.dotColor
        case .paused:
            theme.warning
        case .unavailable:
            theme.danger
        }
    }

    /// A subtle, level-driven breath while the microphone hears you.
    private var avatarPulseScale: CGFloat {
        guard !reduceMotion, model.status == .listening, !model.isMicrophoneMuted else { return 1 }
        return 1 + CGFloat(min(max(model.inputLevel, 0), 1)) * 0.04
    }

    private var displayedTranscriptRows: [VoiceTranscriptRow] {
        transcriptRows ?? model.transcriptRows
    }

    private func transcriptCard(
        _ row: VoiceTranscriptRow,
        isLive: Bool = false
    ) -> some View {
        transcriptRowContent(row, isLive: isLive)
            .padding(.vertical, LoopdyTokens.space12)
            .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.speaker), \(row.time), \(row.text)\(isLive ? ", live" : "")")
    }

    private func transcriptRowContent(_ row: VoiceTranscriptRow, isLive: Bool) -> some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
            HStack(alignment: .firstTextBaseline, spacing: LoopdyTokens.space8) {
                Text(row.speaker)
                    .loopdyFont(.label)
                    .foregroundStyle(theme.primaryText)
                if isLive {
                    Text("Live")
                        .loopdyFont(.metadata, weight: .semibold)
                        .foregroundStyle(theme.action)
                }
                Spacer(minLength: LoopdyTokens.space8)
                Text(row.time)
                    .loopdyFont(.metadata)
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiaryText)
            }
            Text(row.text)
                .loopdyFont(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var endFailure: some View {
        if let message = model.endErrorMessage ?? model.turnErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .loopdyFont(.body, weight: .semibold)
                .foregroundStyle(theme.danger)
                .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget, alignment: .leading)
                .padding(.horizontal, LoopdyTokens.space4)
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var permissionRecovery: some View {
        if let permissionCenter {
            let microphone = permissionCenter.status(for: .microphone).authorization
            let speech = permissionCenter.status(for: .speech).authorization
            if microphone == .denied || microphone == .restricted {
                ContextualPermissionRecoveryView(center: permissionCenter, kind: .microphone)
            } else if speech == .denied || speech == .restricted {
                ContextualPermissionRecoveryView(center: permissionCenter, kind: .speech)
            }
        }
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: LoopdyTokens.space20) {
            agentAudioControl
            endControl
            if model.mode == .walkieTalkie {
                walkieTalkieControl
            } else {
                microphoneControl
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var agentAudioControl: some View {
        voiceControl(
            title: "Agent audio",
            actionName: model.isAgentAudioMuted ? "Unmute" : "Mute",
            systemImage: model.isAgentAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            isSelected: model.isAgentAudioMuted,
            accessibilityLabel: model.isAgentAudioMuted ? "Unmute agent audio" : "Mute agent audio",
            accessibilityValue: model.isAgentAudioMuted ? "Muted" : "Unmuted",
            action: model.toggleAgentAudio
        )
        .accessibilityIdentifier("voice.agent-audio")
    }

    private var microphoneControl: some View {
        voiceControl(
            title: "Microphone",
            actionName: model.isMicrophoneMuted ? "Unmute" : "Mute",
            systemImage: model.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
            isSelected: model.isMicrophoneMuted,
            accessibilityLabel: model.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone",
            accessibilityValue: model.isMicrophoneMuted ? "Muted" : "Unmuted",
            action: model.toggleMicrophone
        )
        .accessibilityIdentifier("voice.microphone")
    }

    private var walkieTalkieControl: some View {
        voiceControlLabel(
            title: "Speak",
            actionName: model.isWalkieTalkieCapturing ? "Release" : "Hold",
            systemImage: model.isWalkieTalkieCapturing ? "waveform.circle.fill" : "mic.fill",
            isSelected: model.isWalkieTalkieCapturing
        )
        .contentShape(.rect)
        .disabled(
            model.isMicrophoneMuted
                || !model.isActive
                || !(model.status == .listening
                    || (model.status == .working && model.isAgentRunActive))
        )
        .gesture(walkieTalkieGesture)
        .onChange(of: walkieGestureActive) { wasActive, active in
            guard wasActive, !active, let generation = walkieGestureGeneration else { return }
            Task { @MainActor in
                await Task.yield()
                guard walkieGestureGeneration == generation else { return }
                walkieGestureGeneration = nil
                model.cancelWalkieTalkieCapture()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(model.isWalkieTalkieCapturing ? .isSelected : [])
        .accessibilityLabel(model.isWalkieTalkieCapturing ? "Send speech" : "Start speaking")
        .accessibilityValue(model.isWalkieTalkieCapturing ? "Recording" : "Ready")
        .accessibilityHint(
            model.isWalkieTalkieCapturing
                ? "Double tap to send this voice turn."
                : "Hold while speaking and release to send. With VoiceOver, double tap to start."
        )
        .accessibilityAction { toggleAccessibleWalkieTalkieCapture() }
        .accessibilityIdentifier("voice.walkie-talkie.speak")
    }

    private var walkieTalkieGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($walkieGestureActive) { _, active, _ in active = true }
            .onChanged { _ in
                guard !model.isWalkieTalkieCapturing else { return }
                guard let generation = model.armWalkieTalkieCapture() else { return }
                walkieGestureGeneration = generation
                Task {
                    _ = await model.startArmedWalkieTalkieCapture(generation: generation)
                }
            }
            .onEnded { value in
                walkieGestureGeneration = nil
                let distance = hypot(value.translation.width, value.translation.height)
                _ = model.endWalkieTalkieCapture(submit: distance <= 50)
            }
    }

    private func toggleAccessibleWalkieTalkieCapture() {
        if model.isWalkieTalkieCapturing {
            _ = model.endWalkieTalkieCapture(submit: true)
            return
        }
        guard let generation = model.armWalkieTalkieCapture() else { return }
        Task {
            _ = await model.startArmedWalkieTalkieCapture(generation: generation)
        }
    }

    private var endControl: some View {
        Button(role: .destructive) {
            Task {
                if await model.end() {
                    onEnded()
                }
            }
        } label: {
            HStack(spacing: LoopdyTokens.space8) {
                if model.isEndPending {
                    LoopdyThinkingOrb(
                        scenario: .working,
                        scale: .inline,
                        surface: theme.actionThinkingOrbSurface
                    )
                    .accessibilityHidden(true)
                } else {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(model.isEndPending ? "Ending…" : "End")
                    .loopdyFont(.body, weight: .semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, LoopdyTokens.space24)
            .frame(minWidth: 112, minHeight: VoiceViewPresentation.controlMinimumHeight)
            .background(Self.endRed, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .opacity(model.isActive || model.isEndPending ? 1 : 0.5)
        .disabled(model.isEndPending || !model.isActive)
        .accessibilityLabel("End voice chat")
        .accessibilityValue(model.isEndPending ? "Ending" : model.endErrorMessage == nil ? "Ready" : "Failed. Double tap to retry")
        .accessibilityHint("Ends voice chat and returns to the chat canvas.")
        .accessibilityIdentifier("voice.end")
    }

    private static let endRed = Color(hex: "D33F42")

    private func voiceControl(
        title: String,
        actionName: String,
        systemImage: String,
        isSelected: Bool,
        accessibilityLabel: String,
        accessibilityValue: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            voiceControlLabel(
                title: title,
                actionName: actionName,
                systemImage: systemImage,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A 64pt circular control. `title`/`actionName` stay in the signature for
    /// the callers' VoiceOver copy; the circle itself is icon-only like the kit.
    private func voiceControlLabel(
        title: String,
        actionName: String,
        systemImage: String,
        isSelected: Bool
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
            .frame(
                width: VoiceViewPresentation.controlMinimumHeight,
                height: VoiceViewPresentation.controlMinimumHeight
            )
            .background(isSelected ? theme.action : theme.surface, in: .circle)
            .overlay {
                Circle()
                    .stroke(isSelected ? theme.action : theme.border, lineWidth: LoopdyTokens.hairline)
            }
            .contentShape(.circle)
    }

    @LoopdyThemeReader private var theme

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

#Preview("Voice - Listening") {
    VoiceView(
        model: VoiceModel(
            conversationID: "preview-listening",
            client: VoiceFixtureClient(confirmationDelay: .zero)
        )
    )
}

#Preview("Voice - Unavailable, Landscape", traits: .landscapeLeft) {
    VoiceView(
        model: VoiceModel(
            conversationID: "preview-unavailable",
            status: .unavailable,
            client: VoiceFixtureClient(confirmationDelay: .zero)
        )
    )
    .dynamicTypeSize(.accessibility2)
}
