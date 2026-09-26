import SwiftUI

extension EnvironmentValues {
    /// Mirrors Settings › Nerd Mode so any surface can hide technical detail
    /// (token context, subagents, project diffs) from everyday use.
    @Entry var nerdModeEnabled = false
}

/// Everyday settings stay on the first page. Host administration (files,
/// gateways, plugins, logs, ...) is revealed only by the Nerd Mode toggle.
extension SettingsView {
    var assistantBasics: some View {
        Section {
            if let onOpenWorkspaceDestination {
                routeRow("Default model", detail: "The model new chats start with",
                         symbol: "cpu", identifier: "settings.default-model") {
                    onOpenWorkspaceDestination(.models)
                }
                routeRow("AI providers", detail: "Sign in to model providers or add API keys",
                         symbol: "key.fill", tint: Color(hex: "F28B32"), identifier: "settings.providers") {
                    onOpenWorkspaceDestination(.keys)
                }
            }
            Button {
                isPersonalitiesPresented = true
            } label: {
                rowLabel("Personalities", detail: personalityDetail, symbol: "theatermasks.fill", tint: Color(hex: "B7356F"))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile.personalities")
        } header: {
            Text("Assistants")
        } footer: {
            Text("Each agent can override its model from Agents › Edit.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }

    private var personalityDetail: String {
        guard let active = personalities.catalog?.activeName, !active.isEmpty else { return "How agents sound" }
        return active.capitalized
    }

    var nerdModeToggle: some View {
        Section {
            Toggle(isOn: $settings.nerdModeEnabled) {
                HStack(spacing: BighelpTokens.space12) {
                    BighelpIconTile(systemName: "wrench.adjustable.fill", tint: .gray)
                    settingLabel("Nerd Mode", detail: "Show advanced host and developer tools")
                }
            }
            .accessibilityIdentifier("settings.nerd-mode")
        } footer: {
            Text(settings.nerdModeEnabled
                 ? "Advanced tools are shown below. Turn this off anytime to keep things simple."
                 : "Files, gateways, plugins, logs and other host tools stay out of the way until you need them.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }

    @ViewBuilder
    var nerdModeSections: some View {
        chatDetailDefaults
        Section("Advanced") {
            if let onOpenRoute {
                routeRow("Hermes tools", detail: "Files, gateways, plugins, MCP, memory and more",
                         symbol: "square.grid.2x2.fill", identifier: "settings.advanced.hermes-tools") {
                    onOpenRoute(.workspaceHub)
                }
                routeRow("Activity", detail: "Inbox, approvals and running work",
                         symbol: "waveform.path", tint: Color(hex: "1769AA"), identifier: "settings.advanced.activity") {
                    onOpenRoute(.workspaceActivity)
                }
                routeRow("Skills & tools", detail: "What agents can use",
                         symbol: "wrench.and.screwdriver.fill", tint: Color(hex: "1E7A4E"),
                         identifier: "settings.advanced.skills") {
                    onOpenRoute(.skillsAndTools)
                }
                if hostRegistry?.connectionMode != .independent {
                    routeRow("Direct Links", detail: "Paired devices",
                             symbol: "link", tint: Color(hex: "9A6BFF"), identifier: "settings.advanced.links") {
                        onOpenRoute(.bighelpLinkDevices)
                    }
                }
            }
            if let onOpenWorkspaceDestination {
                routeRow("Diagnostics", detail: "Host logs", symbol: "stethoscope",
                         tint: .gray, identifier: "settings.advanced.diagnostics") {
                    onOpenWorkspaceDestination(.logs)
                }
            }
            NavigationLink {
                BighelpDeferredSection {
                    settingsPage(title: "Chats & Gestures") {
                        workspace
                        edgeGestures
                    }
                }
            } label: {
                rowLabel("Chats & gestures", detail: "Projects, scheduled runs and edge swipes",
                         symbol: "hand.draw.fill", tint: Color(hex: "F28B32"), showsChevron: false)
            }
            .accessibilityIdentifier("settings.advanced.workspace")
            NavigationLink {
                BighelpDeferredSection {
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
                .navigationTitle("Display & Data")
                .navigationBarTitleDisplayMode(.inline)
                }
            } label: {
                rowLabel("Display & data", detail: "Suggestions, inline cards, links and local cache",
                         symbol: "slider.horizontal.3", tint: .gray, showsChevron: false)
            }
            .accessibilityIdentifier("settings.advanced")
        }
        .listRowBackground(theme.surface)
    }

    func routeRow(_ title: String, detail: String, symbol: String, tint: Color? = nil,
                  identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            rowLabel(title, detail: detail, symbol: symbol, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    func rowLabel(_ title: String, detail: String, symbol: String, tint: Color? = nil,
                  showsChevron: Bool = true) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                Text(detail)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: BighelpTokens.space8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 52)
        .contentShape(.rect)
    }
}
