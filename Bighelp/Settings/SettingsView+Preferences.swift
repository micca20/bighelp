import SwiftUI
import UIKit

extension SettingsView {
    /// Settings › Appearance: colors, light and dark, and the rest of the look on one page.
    var appearancePage: some View {
        AppearanceStudioView(settings: settings) {
            NavigationLink {
                ChatLayoutSettingsView()
            } label: {
                AppearanceStudioRow(title: "Chat layout", detail: "Avatar, name, text size and spacing",
                                    systemImage: "text.bubble")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.appearance.chat-layout")
            #if os(visionOS)
            transparency
                .padding(BighelpTokens.space16)
                .background(theme.surface, in: .rect(cornerRadius: 16))
            #endif
            if settings.nerdModeEnabled {
                reflectiveVisionCard
            }
        }
    }

    #if os(visionOS)
    /// How much of the room shows through bighelp's windows.
    private var transparency: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            settingLabel("Transparency", detail: "How much of your space shows through bighelp")
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: "square.fill")
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityHidden(true)
                Slider(value: $settings.windowTransparency, in: 0...1)
                    .accessibilityLabel("Window transparency")
                    .accessibilityValue("\(Int((settings.windowTransparency * 100).rounded())) percent")
                    .accessibilityIdentifier("appearance.transparency")
                Image(systemName: "square.dashed")
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BighelpTokens.hitTarget)
        }
    }
    #endif

    private var reflectiveVisionCard: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Toggle(isOn: Binding(
                get: { settings.reflectiveVisionEnabled },
                set: { enabled in
                    settings.reflectiveVisionEnabled = enabled
                    Task {
                        if enabled {
                            _ = await permissionCenter.authorizeContextualAccess(.camera)
                        }
                        await reflectiveVisionCamera?.update(
                            enabled: enabled
                        )
                        await permissionCenter.refresh(.camera)
                    }
                }
            )) {
                settingLabel("Reflective Vision", detail: "Your blurred surroundings in a few accents. Uses the camera only while on.")
            }
            .accessibilityIdentifier("settings.reflective-vision")

            if settings.reflectiveVisionEnabled {
                HStack(alignment: .top, spacing: BighelpTokens.space8) {
                    Image(systemName: reflectiveVisionCamera?.state.isActive == true
                        ? "camera.aperture"
                        : "camera.fill")
                        .reflectiveVisionIcon()
                        .foregroundStyle(theme.action)
                        .accessibilityHidden(true)
                    Text(reflectiveVisionStatus)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                }
                .accessibilityElement(children: .combine)

                if reflectiveVisionCamera?.state.canOpenSettings == true {
                    Button("Open Camera Settings") {
                        permissionCenter.performRecoveryAction(for: .camera)
                    }
                    .bighelpFont(.label)
                }
            }
        }
        .padding(BighelpTokens.space16)
        .background(theme.surface, in: .rect(cornerRadius: 16))
    }

    private var reflectiveVisionStatus: String {
        reflectiveVisionCamera?.state.statusText
            ?? "The live reflection is available when bighelp is running on a device with camera access."
    }

    var workspace: some View {
        Section("Chat list") {
            Toggle(isOn: $settings.organizeChatsByProjects) {
                settingLabel(
                    "Organize chats by project",
                    detail: "Group chats by their Hermes project."
                )
            }
            .accessibilityIdentifier("settings.organize-chats-by-projects")

            Toggle(isOn: $settings.showCronSessions) {
                settingLabel(
                    "Show scheduled runs",
                    detail: "Include scheduled task runs in Chats."
                )
            }
            .accessibilityIdentifier("settings.show-cron-sessions")
        }
        .listRowBackground(theme.surface)
    }

    var agentBehavior: some View {
        Section("Agent Behavior") {
            Button {
                isPersonalitiesPresented = true
            } label: {
                HStack(spacing: BighelpTokens.space12) {
                    Label("Personalities", systemImage: "theatermasks")
                    Spacer(minLength: BighelpTokens.space8)
                    if let active = personalities.catalog?.activeName, !active.isEmpty {
                        Text(active.capitalized)
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.tertiaryText)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            }
            .accessibilityIdentifier("profile.personalities")
        }
        .listRowBackground(theme.surface)
    }

    var edgeGestures: some View {
        Section {
            Picker("Swipe from left edge", selection: $settings.leftEdgeSwipeAction) {
                ForEach(WorkspaceSwipeAction.allCases) { action in
                    Label(action.title, systemImage: action.systemImage).tag(action)
                }
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("settings.left-edge-swipe")

            Picker("Swipe from right edge", selection: $settings.rightEdgeSwipeAction) {
                ForEach(WorkspaceSwipeAction.allCases) { action in
                    Label(action.title, systemImage: action.systemImage).tag(action)
                }
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("settings.right-edge-swipe")
        } header: {
            Text("Edge Gestures")
        } footer: {
            Text("Start right at the edge of the screen.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }

    private var chatBasics: some View {
        Section {
            Toggle(isOn: $settings.responseHapticsEnabled) {
                settingLabel(
                    "Response haptics",
                    detail: "A light tap as replies arrive."
                )
            }
            .accessibilityIdentifier("settings.chat.response-haptics")

            Toggle(isOn: $settings.reactionsReachAgent) {
                settingLabel(
                    "Agents see your reactions",
                    detail: "Your agent sees them the next time you message it."
                )
            }
            .accessibilityIdentifier("settings.chat.reactions-reach-agent")

            Toggle(isOn: $settings.agentIslandEnabled) {
                settingLabel(
                    "Agent in the Dynamic Island",
                    detail: "Watch your agent work at the top of the screen."
                )
            }
            .accessibilityIdentifier("settings.chat.agent-island")

        }
        .listRowBackground(theme.surface)
    }

    /// Settings › Chat. Nerd Mode adds what chats show and how the chat list and
    /// edge swipes behave; everyday toggles stay first.
    var chatPage: some View {
        Form {
            BighelpDeferredSection { chatBasics }
            if settings.nerdModeEnabled {
                BighelpDeferredSection { chatDetailDefaults }
                BighelpDeferredSection { advancedChat }
                BighelpDeferredSection { workspace }
                BighelpDeferredSection { edgeGestures }
            }
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// How much of an agent's work new chats show. Technical, so it appears
    /// with Nerd Mode's Advanced section rather than the basics.
    var chatDetailDefaults: some View {
        Section {
            Toggle(isOn: $settings.foldCompletedTurns) {
                settingLabel(
                    "Fold finished turns",
                    detail: "Tuck finished work away; answers stay."
                )
            }
            .accessibilityIdentifier("settings.chat.fold-completed-turns")

            Toggle(isOn: $settings.showReasoningByDefault) {
                settingLabel(
                    "Show reasoning",
                    detail: "Thinking and notes between steps, in new chats."
                )
            }
            .accessibilityIdentifier("settings.chat.show-reasoning")

            Toggle(isOn: $settings.showToolCallsByDefault) {
                settingLabel(
                    "Show tool calls",
                    detail: "Show the work trail in new chats."
                )
            }
            .accessibilityIdentifier("settings.chat.show-tool-calls")
        } header: {
            Text("Chat details")
        } footer: {
            Text("For new chats. Each chat can change its own in its ••• menu.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }

    var advancedChat: some View {
        Group {
            Section {

                Toggle(isOn: $settings.autoSuggestionsEnabled) {
                    settingLabel(
                        "Auto suggestions",
                        detail: "Show prompts that help begin a conversation."
                    )
                }

                Toggle(isOn: $settings.messageActionsEnabled) {
                    settingLabel(
                        "Message actions",
                        detail: "Keep actions available alongside messages."
                    )
                }

                Toggle(isOn: $settings.inlineUIEnabled) {
                    settingLabel(
                        "Inline UI",
                        detail: "Show supported weather, task, budget, and approval cards."
                    )
                }

                Toggle(isOn: $settings.showProjectChanges) {
                    settingLabel(
                        "Project changes",
                        detail: "Show file additions and deletions for a chat’s Hermes Project."
                    )
                }
                .accessibilityIdentifier("settings.chat.show-project-changes")

                let availableBrowsers = ChatBrowserPreference.available(canOpenURL: UIApplication.shared.canOpenURL)
                Picker("Open links in", selection: Binding(
                    get: { availableBrowsers.contains(settings.preferredBrowser) ? settings.preferredBrowser : .systemDefault },
                    set: { settings.preferredBrowser = $0 }
                )) {
                    ForEach(availableBrowsers) { browser in
                        Label(browser.title, systemImage: browser.systemImage).tag(browser)
                    }
                }
                .accessibilityIdentifier("settings.chat.browser")

                Picker("While an agent is working", selection: $settings.midSessionChatBehavior) {
                    ForEach(MidSessionChatBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .accessibilityIdentifier("settings.chat.mid-session-behavior")
            } header: {
                Text("More chat options")
            } footer: {
                Text("Hold Send while an agent works to choose for just that message.")
                    .bighelpFont(.metadata)
            }
            .listRowBackground(theme.surface)
        }
    }
}
