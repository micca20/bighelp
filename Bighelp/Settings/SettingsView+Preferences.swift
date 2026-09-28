import SwiftUI
import UIKit

extension SettingsView {
    var appearanceBasics: some View {
        Section {
            ThemeSelectionLink(settings: settings)
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("settings.appearance")
            NavigationLink {
                ChatLayoutSettingsView()
            } label: {
                settingLabel("Chat layout", detail: "Avatar, name, text size and spacing")
            }
            .accessibilityIdentifier("settings.appearance.chat-layout")
        } header: {
            Text("Appearance")
        } footer: {
            EmptyView()
        }
        .listRowBackground(theme.surface)
    }

    var appearance: some View { appearanceBasics }

    var advancedAppearance: some View {
        Group {
            Section {
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reflective Vision UI")
                            .foregroundStyle(theme.primaryText)
                        Text("Live, blurred surroundings in selected accents")
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
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
            } header: {
                Text("Appearance")
            } footer: {
                Text("Reflective Vision is optional, uses the camera only while active, and stays on this device. Saved theme document data remains available for editing and transfer.")
                    .bighelpFont(.metadata)
            }
            .listRowBackground(theme.surface)
        }
    }

    private var reflectiveVisionStatus: String {
        reflectiveVisionCamera?.state.statusText
            ?? "The live reflection is available when bighelp is running on a device with camera access."
    }

    var workspace: some View {
        Section("Workspace") {
            Button(action: onOpenSessions) {
                Label("Sessions", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(theme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            }
            .accessibilityLabel("Open sessions")
            .accessibilityIdentifier("profile.sessions")
            Button(action: onOpenScheduledTasks) {
                Label("Scheduled Tasks", systemImage: "calendar.badge.clock")
                    .foregroundStyle(theme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            }
            .accessibilityLabel("Open scheduled tasks")
            .accessibilityIdentifier("profile.scheduled-tasks")

            Toggle(isOn: $settings.organizeChatsByProjects) {
                settingLabel(
                    "Organize Chats by Projects",
                    detail: "Group chats by their Hermes project in Sessions and Quick Workspace."
                )
            }
            .accessibilityIdentifier("settings.organize-chats-by-projects")

            Toggle(isOn: $settings.showCronSessions) {
                settingLabel(
                    "Show Scheduled Runs",
                    detail: "Include cron sessions in Chats and Quick Workspace."
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
            Text("Start at the very edge of the screen. The left edge opens Quick Workspace by default; the right edge stays off until you choose an action.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }

    /// What the microphone in a chat opens, right on the Settings page, with
    /// the speech provider and voice one tap further.
    private var voiceBasics: some View {
        Section {
            Picker("Voice mode", selection: $settings.voiceConversationMode) {
                Text(VoiceConversationMode.turnBased.title).tag(VoiceConversationMode.turnBased)
                Text(VoiceConversationMode.codexLive.title).tag(VoiceConversationMode.codexLive)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("settings.voice.mode")

            NavigationLink {
                VoiceSettingsView(settings: settings, agents: agents,
                    selectedAgentID: agentDirectory?.selectedAgentID,
                    client: voiceSettingsClient, scope: voiceSettingsScope,
                    isCurrent: voiceSettingsIsCurrent)
            } label: {
                if settings.voiceConversationMode == .codexLive {
                    settingLabel("GPT Live 1 settings", detail: "Sign-in and voice")
                } else {
                    settingLabel("Speech provider and voice", detail: "Each agent's voice, including ones that run on your computer")
                }
            }
            .accessibilityIdentifier("settings.chat.voice-settings")
        } header: {
            Text("Voice")
        } footer: {
            Text("TTS listens on this phone and reads replies aloud with your agent's speech provider. GPT Live 1 is a live conversation with OpenAI.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }

    var voiceExperience: some View { voiceBasics }

    /// Which providers the Provider Usage overlay shows.
    var providerUsageSection: some View {
        Section {
            NavigationLink {
                // Pushed screens don't reliably inherit the store; hand it over.
                ProviderUsageSettingsView().environment(\.providerUsage, providerUsage)
            } label: {
                settingLabel("Show and hide providers", detail: "Choose which plans and balances Provider Usage shows")
            }
            .accessibilityIdentifier("settings.provider-usage")
        } header: {
            Text("Provider Usage")
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
                    detail: "React to a reply and your agent may answer."
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

        } header: {
            Text("Chat")
        }
        .listRowBackground(theme.surface)
    }

    var chatExperience: some View { chatBasics }

    /// How much of an agent's work new chats show. Technical, so it appears
    /// with Nerd Mode's Advanced section rather than the basics.
    var chatDetailDefaults: some View {
        Section {
            Toggle(isOn: $settings.foldCompletedTurns) {
                settingLabel(
                    "Fold Completed Turns",
                    detail: "Tuck finished work away; messages stay."
                )
            }
            .accessibilityIdentifier("settings.chat.fold-completed-turns")

            Toggle(isOn: $settings.showReasoningByDefault) {
                settingLabel(
                    "Show reasoning",
                    detail: "Expand thinking in new chats."
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
            Text("Reasoning and tool calls apply to new chats. Each chat can change its own from the ••• menu.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }

    /// Everything a person rarely changes lives on one page, reached from a
    /// single row, so the first Settings screen stays short.
    var advancedLink: some View {
        Section {
            NavigationLink {
                Form {
                    advancedChat
                    advancedAppearance
                    localCache
                }
                .modifier(ClearCacheConfirmation(
                    isPresented: $isClearCacheConfirmationPresented,
                    onConfirm: clearLocalCache
                ))
                .bighelpFormSurface()
                .scrollContentBackground(.hidden)
                .background(theme.canvas.ignoresSafeArea())
                .navigationTitle("Advanced")
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label {
                    Text("Advanced")
                } icon: {
                    BighelpIconTile(systemName: "slider.horizontal.3", tint: .gray)
                }
            }
            .accessibilityIdentifier("settings.advanced")
        } footer: {
            Text("Suggestions, inline cards, links, Reflective Vision and local data.")
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
                Text("Chat")
            } footer: {
                Text("Hold Send during a live turn to choose a different behavior for only that message.")
                    .bighelpFont(.metadata)
            }
            .listRowBackground(theme.surface)
        }
    }
}

private extension AppAppearance {
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
