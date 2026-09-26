import SwiftUI

private enum VoiceSettingsField { case voice, key }

enum CodexLiveVoicePluginAvailability: Equatable, Sendable {
    case unknown
    case missing
    case ready
    case unavailable
}

enum CodexLiveVoiceSettingsPresentation {
    static let title = "Codex Live Voice"
    static let installAccessibilityIdentifier = "settings.install-loopdy-plugin-for-live-voice"

    static func detail(for availability: CodexLiveVoicePluginAvailability) -> String {
        switch availability {
        case .unknown:
            "Codex Live Voice requires the Loopdy plugin. Connect to a paired host to verify plugin readiness."
        case .missing:
            "Codex Live Voice requires the Loopdy plugin on the selected host. Install it to use live voice with your Codex subscription."
        case .ready:
            "The Loopdy plugin is ready for Codex Live Voice on the selected host."
        case .unavailable:
            "Codex Live Voice requires the Loopdy plugin, but this host has not provided a verified readiness result."
        }
    }
}

@MainActor
struct VoiceSettingsView: View {
    @Bindable var settings: SettingsStore
    let agents: [AgentProfile]
    let client: (any VoiceSettingsClient)?
    let scope: String?
    let isCurrent: @MainActor () -> Bool
    @State private var agentID: String
    @State private var store: VoiceSettingsStore?
    @State private var confirmAPIBilling = false
    @FocusState private var focusedField: VoiceSettingsField?
    @Environment(\.scenePhase) private var scenePhase

    init(settings: SettingsStore, agents: [AgentProfile], selectedAgentID: String?,
         client: (any VoiceSettingsClient)?, scope: String?,
         isCurrent: @escaping @MainActor () -> Bool) {
        self.settings = settings
        self.agents = agents
        self.client = client
        self.scope = scope
        self.isCurrent = isCurrent
        _agentID = State(initialValue: agents.first(where: { $0.id == selectedAgentID })?.id
            ?? agents.first(where: \.isDefault)?.id ?? agents.first?.id ?? "")
    }

    @LoopdyThemeReader private var theme

    private var loadTaskID: String {
        (scope ?? "disconnected") + ":" + agentID
    }

    var body: some View {
        Form {
            VoicePreferenceSections(settings: settings, confirmAPIBilling: $confirmAPIBilling)

            if client != nil, scope != nil, !agents.isEmpty {
                Section {
                    Picker("Agent", selection: $agentID) {
                        ForEach(agents) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityIdentifier("voice.settings.agent")
                } header: {
                    Text("Agent")
                } footer: {
                    Text("Speech settings are saved to this agent on the selected host.")
                }
                if agents.contains(where: { $0.id == agentID }) {
                    if let store, store.agentID == agentID {
                        VoiceSettingsEditor(store: store, focusedField: $focusedField)
                    }
                }
            } else {
                Section("Agent speech") {
                    Text("Connect to a host to change its speech provider, API key, and voice.")
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .loopdyFormSurface()
        .environment(\.defaultMinListRowHeight, LoopdyTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .foregroundStyle(theme.primaryText)
        .tint(theme.action)
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Use separately billed API voice?", isPresented: $confirmAPIBilling,
                            titleVisibility: .visible) {
            Button("Use API key provider") { settings.liveVoiceProvider = .apiKey }
            Button("Keep Codex subscription", role: .cancel) {}
        } message: {
            Text("The host's API key may incur separate usage charges. Subscription failures never switch providers automatically.")
        }
        .onChange(of: agents.map(\.id)) { _, ids in
            if !ids.contains(agentID) { agentID = agents.first(where: \.isDefault)?.id ?? ids.first ?? "" }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    focusedField = nil
                    Task { await store?.save() }
                } label: {
                    if store?.isSaving == true { ProgressView() } else { Text("Save") }
                }
                .disabled(store?.canSave != true)
                .accessibilityIdentifier("voice.settings.save")
            }
        }
        .task(id: loadTaskID) {
            store?.invalidate()
            store = nil
            guard let client, scope != nil, agents.contains(where: { $0.id == agentID }) else { return }
            let current = VoiceSettingsStore(agentID: agentID, client: client, isCurrent: isCurrent)
            store = current
            await current.load()
        }
        .onDisappear { store?.invalidate() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store?.clearAPIKey() }
        }
    }
}

@MainActor
private struct VoicePreferenceSections: View {
    @Bindable var settings: SettingsStore
    @Binding var confirmAPIBilling: Bool

    private var provider: Binding<LiveVoiceProvider> {
        Binding(
            get: { settings.liveVoiceProvider },
            set: { value in
                if value == .apiKey { confirmAPIBilling = true }
                else { settings.liveVoiceProvider = value }
            }
        )
    }

    private var voice: Binding<String> {
        Binding(
            get: { settings.liveVoice(for: settings.liveVoiceProvider) },
            set: { settings.setLiveVoice($0, for: settings.liveVoiceProvider) }
        )
    }

    var body: some View {
        Section {
            Picker("Conversation", selection: $settings.voiceConversationMode) {
                Text(VoiceConversationMode.codexLive.title).tag(VoiceConversationMode.codexLive)
                Text(VoiceConversationMode.turnBased.title).tag(VoiceConversationMode.turnBased)
            }
            .accessibilityIdentifier("voice.settings.conversation-mode")
            Text(settings.voiceConversationMode.detail)
                .loopdyFont(.metadata)
                .foregroundStyle(.secondary)
        } header: {
            Text("Conversation")
        }

        if settings.voiceConversationMode == .codexLive {
            Section {
                Picker("Provider", selection: provider) {
                    Text(LiveVoiceProvider.codexSubscription.title)
                        .tag(LiveVoiceProvider.codexSubscription)
                    Text(LiveVoiceProvider.apiKey.title)
                        .tag(LiveVoiceProvider.apiKey)
                }
                .accessibilityIdentifier("voice.settings.live-provider")
                Picker("Voice", selection: voice) {
                    ForEach(settings.liveVoiceProvider.voices, id: \.self) { option in
                        Text(option.capitalized).tag(option)
                    }
                }
                .accessibilityIdentifier("voice.settings.live-voice")
            } header: {
                Text("Live voice")
            } footer: {
                Text("Provider credentials stay on your host. API key voice may incur separate usage charges.")
            }
            HostPluginFeatureSection(feature: .liveVoice)
        } else {
            Section {
                Picker("Speaking mode", selection: $settings.voiceMode) {
                    ForEach(VoiceMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .accessibilityIdentifier("settings.chat.voice-mode")
                Picker("Voice speed", selection: $settings.voiceSpeed) {
                    ForEach(VoiceSpeed.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } header: {
                Text("Turn-based voice")
            } footer: {
                Text(settings.voiceMode.detail)
            }
        }
    }
}

@MainActor
private struct VoiceSettingsEditor: View {
    @Bindable var store: VoiceSettingsStore
    @FocusState.Binding var focusedField: VoiceSettingsField?

    var body: some View {
        Group {
            if let configuration = store.configuration {
                Section {
                    Picker("Provider", selection: Binding(get: { store.providerID }, set: { store.selectProvider($0) })) {
                        ForEach(configuration.providers) { Text($0.title).tag($0.id) }
                    }
                    .accessibilityIdentifier("voice.settings.provider")
                    .disabled(store.isSaving || store.isLoading)

                    if store.supportsEditing {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Voice ID")
                            TextField(store.providerID == "openai" ? "For example, alloy" : "ElevenLabs voice ID", text: $store.voiceID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .voice)
                                .accessibilityIdentifier("voice.settings.voice-id")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("API key")
                            SecureField(store.selectedProvider?.apiKeyConfigured == true
                                ? "Saved — enter a replacement" : "Enter API key", text: $store.apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .privacySensitive()
                                .focused($focusedField, equals: .key)
                                .accessibilityIdentifier("voice.settings.api-key")
                        }
                        Text(store.selectedProvider?.apiKeyConfigured == true ? "API key saved on host" : "API key required")
                            .loopdyFont(.metadata)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("voice.settings.key-status")
                    } else {
                        Text("This agent uses \(store.selectedProvider?.title ?? store.providerID). Choose OpenAI or ElevenLabs to edit its voice and key here.")
                            .loopdyFont(.metadata)
                            .foregroundStyle(.secondary)
                    }
                } header: { Text("Agent speech") }
                footer: {
                    Text("Leave the API key blank to keep the saved key. Changes apply to this agent’s next spoken reply.")
                }
                .disabled(store.isSaving)
            }

            if store.isLoading {
                Section { ProgressView("Loading voice settings…") }
            }
            if let error = store.errorMessage {
                Section {
                    Text(error).loopdyFont(.metadata)
                    Button("Reload settings") { Task { await store.load() } }
                        .disabled(store.isLoading || store.isSaving)
                }
            }
            if let confirmation = store.confirmation {
                Section {
                    Label(confirmation, systemImage: "checkmark.circle")
                        .accessibilityIdentifier("voice.settings.confirmation")
                }
            }
        }

    }
}

private extension VoiceSpeed {
    var title: String {
        switch self {
        case .slow: "Slow"
        case .normal: "Normal"
        case .fast: "Fast"
        }
    }
}
