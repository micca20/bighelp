import SwiftUI

/// Saved on this device. Chat views read them with `@AppStorage`, so a change
/// shows the next time a chat draws.
enum ChatLayoutPreferences {
    static let avatarSizeKey = "bighelp.chat.avatar-size"
    static let showsAgentNameKey = "bighelp.chat.shows-agent-name"
    static let textSizeKey = "bighelp.chat.text-size"
    static let densityKey = "bighelp.chat.density"

    /// The Pro Max and Plus phones are at least this tall, in points.
    static let tallPhoneHeight: CGFloat = 900
}

/// The agent's avatar at the top of a chat.
enum ChatAvatarSize: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case small
    case medium
    case large

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Auto"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// Auto keeps the large avatar on the tallest phones and uses Medium on the
    /// rest, where the header and bottom bar otherwise crowd the messages.
    func points(screenHeight: CGFloat) -> CGFloat {
        switch self {
        case .small: 44
        case .medium: 60
        case .large: 76
        case .automatic: screenHeight >= ChatLayoutPreferences.tallPhoneHeight ? 76 : 60
        }
    }
}

/// Message text size, on top of the iPhone's own text size setting.
enum ChatTextSize: Int, CaseIterable, Identifiable, Sendable {
    case smaller = -2
    case small = -1
    case standard = 0
    case large = 1
    case larger = 2

    var id: Self { self }

    var title: String {
        switch self {
        case .smaller: "Smaller"
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        case .larger: "Larger"
        }
    }

    var scale: CGFloat {
        switch self {
        case .smaller: 0.85
        case .small: 0.93
        case .standard: 1
        case .large: 1.1
        case .larger: 1.22
        }
    }
}

/// Room around and between messages.
enum ChatDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable
    case compact

    var id: Self { self }

    var title: String {
        switch self {
        case .comfortable: "Comfortable"
        case .compact: "Compact"
        }
    }

    /// Space below a message when the next one is from someone else.
    var messageSpacing: CGFloat { self == .compact ? 10 : BighelpTokens.space16 }
    var bubbleHorizontalPadding: CGFloat {
        self == .compact ? 11 : BighelpV3MessagePresentation.horizontalContentPadding
    }
    var bubbleVerticalPadding: CGFloat { self == .compact ? 7 : 10 }
}

/// Settings › Appearance › Chat layout.
struct ChatLayoutSettingsView: View {
    @AppStorage(ChatLayoutPreferences.avatarSizeKey) private var avatarSize: ChatAvatarSize = .automatic
    @AppStorage(ChatLayoutPreferences.showsAgentNameKey) private var showsAgentName = true
    @AppStorage(ChatLayoutPreferences.textSizeKey) private var textSize: ChatTextSize = .standard
    @AppStorage(ChatLayoutPreferences.densityKey) private var density: ChatDensity = .comfortable
    @AppStorage(LinkPreviewPreferences.enabledKey) private var showsLinkPreviews = true
    @BighelpThemeReader private var theme

    var body: some View {
        Form {
            Section {
                ChatLayoutPreview(avatarSize: avatarSize.points(screenHeight: previewScreenHeight),
                                  showsAgentName: showsAgentName, textSize: textSize, density: density)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }
            .listRowBackground(theme.canvas)

            Section {
                Picker("Avatar size", selection: $avatarSize) {
                    ForEach(ChatAvatarSize.allCases) { Text($0.title).tag($0) }
                }
                .bighelpSegmentedPicker()
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("chat-layout.avatar-size")
                Toggle("Show agent name", isOn: $showsAgentName)
                    .accessibilityIdentifier("chat-layout.shows-name")
            } header: {
                Text("Chat header")
            } footer: {
                Text("Auto keeps the large avatar on the biggest iPhones and uses Medium on the rest. With the name hidden, tap the avatar for the agent's profile, or touch and hold it to switch agents.")
            }
            .listRowBackground(theme.surface)

            Section {
                HStack(spacing: BighelpTokens.space12) {
                    Image(systemName: "textformat.size.smaller")
                        .accessibilityHidden(true)
                    Slider(value: textSizeValue, in: -2...2, step: 1)
                        .accessibilityLabel("Text size")
                        .accessibilityValue(textSize.title)
                        .accessibilityIdentifier("chat-layout.text-size")
                    Image(systemName: "textformat.size.larger")
                        .accessibilityHidden(true)
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                Picker("Spacing", selection: $density) {
                    ForEach(ChatDensity.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("chat-layout.density")
                Toggle("Link previews", isOn: $showsLinkPreviews)
                    .accessibilityIdentifier("chat-layout.link-previews")
            } header: {
                Text("Messages")
            } footer: {
                Text("Text size: \(textSize.title). It adds to your iPhone's own text size setting. Link previews "
                    + "show a web link's picture, title and summary in chats and the Feed. To make one, your "
                    + "iPhone opens that page, without cookies.")
            }
            .listRowBackground(theme.surface)

            Section {
                Button("Reset to defaults") {
                    avatarSize = .automatic
                    showsAgentName = true
                    textSize = .standard
                    density = .comfortable
                    showsLinkPreviews = true
                }
                .accessibilityIdentifier("chat-layout.reset")
            }
            .listRowBackground(theme.surface)
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .foregroundStyle(theme.primaryText)
        .tint(theme.action)
        .navigationTitle("Chat layout")
        .navigationBarTitleDisplayMode(.inline)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        } action: { previewScreenHeight = $0 }
    }

    @State private var previewScreenHeight: CGFloat = 0

    private var textSizeValue: Binding<Double> {
        Binding(get: { Double(textSize.rawValue) },
                set: { textSize = ChatTextSize(rawValue: Int($0.rounded())) ?? .standard })
    }
}

/// A small, static picture of the chat with the chosen layout.
private struct ChatLayoutPreview: View {
    let avatarSize: CGFloat
    let showsAgentName: Bool
    let textSize: ChatTextSize
    let density: ChatDensity
    @BighelpThemeReader private var theme
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 17

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Circle()
                    .fill(theme.action)
                    .frame(width: avatarSize, height: avatarSize)
                if showsAgentName {
                    Text("Your agent")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, BighelpTokens.space16)
                        .padding(.vertical, 6)
                        .background(theme.surface, in: Capsule())
                }
            }
            .padding(.bottom, BighelpTokens.space12)
            .animation(.snappy, value: avatarSize)
            .animation(.snappy, value: showsAgentName)

            bubble("Can you look over my notes before the meeting?", outgoing: true)
                .padding(.bottom, density.messageSpacing)
            bubble("Sure. I added two questions and fixed the dates.", outgoing: false)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of a chat with these settings")
        .accessibilityIdentifier("chat-layout.preview")
    }

    private func bubble(_ text: String, outgoing: Bool) -> some View {
        HStack {
            if outgoing { Spacer(minLength: 40) }
            Text(text)
                .font(.system(size: (bodySize * textSize.scale).rounded()))
                .foregroundStyle(outgoing ? theme.outgoingMessageForeground : theme.primaryText)
                .padding(.horizontal, density.bubbleHorizontalPadding)
                .padding(.vertical, density.bubbleVerticalPadding)
                .background(outgoing ? theme.outgoingMessageBackground : theme.incomingMessageBackground,
                            in: RoundedRectangle(cornerRadius: BighelpV3MessagePresentation.bubbleRadius,
                                                 style: .continuous))
            if !outgoing { Spacer(minLength: 40) }
        }
    }
}
