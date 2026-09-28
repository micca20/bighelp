#if os(visionOS)
import SwiftUI

/// The values every bighelp window reads, for scenes outside the main window.
struct SpatialSceneEnvironment: ViewModifier {
    let settings: SettingsStore
    let companion: CompanionStore
    let companionAgentScope: String

    func body(content: Content) -> some View {
        content
            .environment(\.appAppearance, settings.appearanceContext)
            .environment(\.companionStore, companion)
            .environment(\.companionAgentScope, companionAgentScope)
            .environment(\.bighelpUIV2Enabled, settings.uiV2Enabled)
            .environment(\.bighelpUIV3Enabled, settings.interfaceVersion == .v3)
            .environment(\.nerdModeEnabled, settings.nerdModeEnabled)
    }
}

/// Your agent standing in the room, in its own volume so it stays put while
/// you use other apps. Look at it and pinch to talk or type (Settings
/// decides); pinch and hold for how to move and anchor it.
struct SpatialAvatarVolume: View {
    @Bindable var model: SpatialAvatarModel
    let settings: SettingsStore

    @Environment(\.openWindow) private var openWindow
    @Environment(\.surfaceSnappingInfo) private var snapping
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme
    @State private var facing: SquareAzimuth = .front
    @FocusState private var isPromptFocused: Bool

    static let avatarSize: CGFloat = 300

    var body: some View {
        VStack(spacing: BighelpTokens.space16) {
            avatar
            statusChip
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .overlay(alignment: .top) { topCard }
        // Turn to face you as you walk around it; no plate under a floating pet.
        .rotation3DEffect(facing.orientation)
        .volumeBaseplateVisibility(.hidden)
        .supportedVolumeViewpoints(.all)
        .onVolumeViewpointChange { _, viewpoint in
            withAnimation(reduceMotion ? nil : .smooth) { facing = viewpoint.squareAzimuth }
        }
        .ornament(visibility: model.isPromptPresented ? .visible : .hidden,
                  attachmentAnchor: .scene(.bottomFront), contentAlignment: .top) {
            promptBar
        }
        .animation(reduceMotion ? nil : .snappy, value: model.isPromptPresented)
        .animation(reduceMotion ? nil : .snappy, value: model.reply)
        .task { await model.connectIfNeeded() }
        .task(id: model.isShowingMoveTip) {
            guard model.isShowingMoveTip else { return }
            try? await Task.sleep(for: .seconds(6))
            model.isShowingMoveTip = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spatial-avatar")
    }

    // MARK: Avatar

    private var avatar: some View {
        AgentLiveAvatar(agentID: model.agent?.id ?? "agent",
                        displayName: model.agent?.name ?? "Your agent",
                        imageURL: model.agent?.imageURL,
                        activity: model.activity,
                        size: Self.avatarSize,
                        restingState: model.restingState)
            .phaseAnimator(reduceMotion ? [0] : [0, 1]) { face, phase in
                // A slow bob, so it reads as someone standing there.
                face.offset(y: phase == 1 ? -6 : 0)
            } animation: { _ in .easeInOut(duration: 2.4) }
            .background(alignment: .bottom) { floorShadow }
            .contentShape(.hoverEffect, .circle)
            .hoverEffect(.highlight)
            .onTapGesture(perform: pinch)
            .onLongPressGesture(minimumDuration: 0.6) { model.isShowingMoveTip = true }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.agent?.name ?? "Your agent")
            .accessibilityValue(model.activity.label)
            .accessibilityHint(settings.spatialAvatarPinchAction == .talk ? "Starts talking" : "Opens a message box")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, pinch)
            .accessibilityIdentifier("spatial-avatar.avatar")
    }

    /// A soft shadow on the floor of the volume grounds the avatar in the room.
    private var floorShadow: some View {
        Ellipse()
            .fill(RadialGradient(colors: [.black.opacity(0.35), .clear], center: .center,
                                 startRadius: 0, endRadius: Self.avatarSize * 0.36))
            .frame(width: Self.avatarSize * 0.8, height: Self.avatarSize * 0.8)
            .rotation3DEffect(.degrees(90), axis: (x: 1, y: 0, z: 0))
            .offset(y: Self.avatarSize * 0.42)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var statusChip: some View {
        HStack(spacing: BighelpTokens.space8) {
            if snapping.isSnapped {
                Image(systemName: "pin.fill")
                    .accessibilityLabel("Anchored")
            }
            if let name = model.agent?.name {
                Text(name).fontWeight(.semibold)
                Text("·").foregroundStyle(.secondary)
            }
            Text(model.status(pinch: settings.spatialAvatarPinchAction))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
        .glassBackgroundEffect(in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("spatial-avatar.status")
    }

    // MARK: Reply, tip and errors

    @ViewBuilder
    private var topCard: some View {
        if model.isShowingMoveTip {
            card {
                Label {
                    Text("Pinch and hold the bar under me, then drag to move me. Let go near a table and I'll stay anchored there.")
                } icon: {
                    Image(systemName: "hand.pinch")
                }
                .font(.callout)
            }
            .accessibilityIdentifier("spatial-avatar.move-tip")
        } else if let message = model.errorMessage {
            card {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
            .accessibilityIdentifier("spatial-avatar.error")
        } else if let reply = model.reply {
            card {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    // A glance; Open chat has the whole answer.
                    Text(reply)
                        .font(.body)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("spatial-avatar.reply.text")
                    HStack {
                        Button("Open chat", systemImage: "bubble.left.and.bubble.right", action: openChat)
                            .accessibilityIdentifier("spatial-avatar.reply.open")
                        Spacer()
                        Button("Done", systemImage: "checkmark") { model.dismissReply() }
                            .accessibilityIdentifier("spatial-avatar.reply.done")
                    }
                    .font(.callout)
                    .buttonStyle(.borderless)
                }
            }
            .accessibilityIdentifier("spatial-avatar.reply")
        }
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(BighelpTokens.space16)
            .frame(maxWidth: 420, alignment: .leading)
            .glassBackgroundEffect(in: .rect(cornerRadius: 24))
            .offset(z: 24)
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
    }

    // MARK: Typing

    private var promptBar: some View {
        HStack(alignment: .bottom, spacing: BighelpTokens.space12) {
            TextField("Message \(model.agent?.name ?? "your agent")", text: $model.draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($isPromptFocused)
                .onSubmit(send)
                .submitLabel(.send)
                .accessibilityIdentifier("spatial-avatar.prompt.field")
            Button("Send", systemImage: "arrow.up", action: send)
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSubmitting)
                .accessibilityIdentifier("spatial-avatar.prompt.send")
            Button("Close", systemImage: "xmark") {
                model.isPromptPresented = false
                isPromptFocused = false
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .accessibilityIdentifier("spatial-avatar.prompt.close")
        }
        .padding(BighelpTokens.space12)
        .frame(width: 520)
        .glassBackgroundEffect(in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spatial-avatar.prompt")
    }

    // MARK: Actions

    private func pinch() {
        switch model.pinch(settings.spatialAvatarPinchAction) {
        case .prompt:
            isPromptFocused = true
        case .voice:
            Task {
                guard let voice = await model.startVoice(settings) else { return }
                openWindow(id: SpatialAvatarSceneID.voice, value: voice.id)
            }
        case .retrying:
            Task { await model.connectIfNeeded() }
        }
    }

    private func send() {
        isPromptFocused = false
        Task { await model.send() }
    }

    private func openChat() {
        guard model.openConversation() else { return }
        model.dismissReply()
        // Brings the main window back if it was closed; the chat is already selected.
        if !model.isMainWindowOpen { openWindow(id: SpatialAvatarSceneID.main) }
    }
}

/// Voice for the avatar's chat, in a panel that opens beside it. It's the same
/// voice screen as in a chat, so both voice modes behave the same.
struct SpatialAvatarVoicePanel: View {
    let model: SpatialAvatarModel
    let presentationID: String?
    let settings: SettingsStore
    let permissionCenter: PermissionCenter

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let voice = model.voice, voice.id == presentationID {
                VoicePresentationContainer(
                    presentation: voice,
                    agentID: model.agent?.id,
                    agentImageURL: model.agent?.imageURL,
                    permissionCenter: permissionCenter,
                    onEnded: close,
                    onWorkspaceTap: openChat,
                    onUseTurnBased: useTTS,
                    chatActivity: { model.activity }
                )
            } else {
                // A voice panel restored after a relaunch has nothing to show.
                Color.clear.onAppear { dismissWindow() }
            }
        }
        .onDisappear {
            if model.voice?.id == presentationID { model.endVoice() }
        }
    }

    private func close() {
        model.endVoice()
        dismissWindow()
    }

    private func openChat() {
        guard model.openConversation() else { return }
        if !model.isMainWindowOpen { openWindow(id: SpatialAvatarSceneID.main) }
    }

    private func useTTS() {
        settings.voiceConversationMode = .turnBased
        model.endVoice()
        dismissWindow()
        Task {
            guard let voice = await model.startVoice(settings) else { return }
            openWindow(id: SpatialAvatarSceneID.voice, value: voice.id)
        }
    }
}

/// Hooks on the main window: Settings finds the avatar, the avatar knows
/// whether it must reopen this window, and it steps into the room once, the
/// first time a computer is connected.
struct SpatialAvatarMainWindowHooks: ViewModifier {
    let model: SpatialAvatarModel
    let canIntroduce: Bool

    @Environment(\.openWindow) private var openWindow
    @AppStorage("bighelp.spatial-avatar.introduced") private var introduced = false

    func body(content: Content) -> some View {
        content
            .environment(\.spatialAvatar, model)
            .onAppear { model.isMainWindowOpen = true }
            .onDisappear { model.isMainWindowOpen = false }
            .onChange(of: canIntroduce, initial: true) { _, ready in
                guard ready, !introduced, !model.isVolumeOpen else { return }
                introduced = true
                openWindow(id: SpatialAvatarSceneID.avatar)
            }
    }
}

/// The avatar's volume and its voice panel, next to the main window.
struct SpatialAvatarScenes: Scene {
    let model: SpatialAvatarModel
    let settings: SettingsStore
    let companion: CompanionStore
    let companionAgentScope: String
    let permissionCenter: PermissionCenter

    var body: some Scene {
        WindowGroup(id: SpatialAvatarSceneID.avatar) {
            SpatialAvatarVolume(model: model, settings: settings)
                .modifier(SpatialSceneEnvironment(settings: settings, companion: companion,
                                                  companionAgentScope: companionAgentScope))
                .onAppear { model.isVolumeOpen = true }
                .onDisappear { model.isVolumeOpen = false }
        }
        .windowStyle(.volumetric)
        // About the size of a small pet on a desk.
        .defaultSize(width: 0.36, height: 0.44, depth: 0.28, in: .meters)
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, context in
            // Beside bighelp at first; after that it stays wherever you put it.
            if let main = context.windows.first(where: { $0.id == SpatialAvatarSceneID.main }) {
                return WindowPlacement(.trailing(main))
            }
            return WindowPlacement()
        }

        WindowGroup(id: SpatialAvatarSceneID.voice, for: String.self) { $presentationID in
            SpatialAvatarVoicePanel(model: model, presentationID: presentationID,
                                    settings: settings, permissionCenter: permissionCenter)
                .modifier(SpatialSceneEnvironment(settings: settings, companion: companion,
                                                  companionAgentScope: companionAgentScope))
        }
        .defaultSize(width: 400, height: 560)
        .defaultWindowPlacement { _, context in
            // Beside the avatar, so you keep looking at who you're talking to.
            if let avatar = context.windows.first(where: { $0.id == SpatialAvatarSceneID.avatar }) {
                return WindowPlacement(.trailing(avatar))
            }
            return WindowPlacement(.utilityPanel)
        }
        .restorationBehavior(.disabled)
    }
}
#endif
