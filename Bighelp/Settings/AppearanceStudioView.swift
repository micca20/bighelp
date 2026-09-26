import SwiftUI

/// Settings › Appearance › Colors: pick a bubble color and a page color for
/// light and dark mode, with a live preview of both. Custom and partner
/// themes (import, export, fonts, logos) stay one tap away under More themes.
@MainActor
struct AppearanceStudioView: View {
    @Bindable var settings: SettingsStore
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space24) {
                preview
                section("Bubble color", caption: "Your messages and buttons") { bubbleGrid }
                section("Light mode", caption: nil) {
                    HStack(spacing: BighelpTokens.space12) {
                        ForEach(BighelpLightBackground.allCases) { choice in
                            backgroundTile(name: choice.name, detail: choice.detail,
                                           theme: theme(.light, light: choice),
                                           isSelected: settings.lightBackground == choice,
                                           identifier: "appearance.light.\(choice.rawValue)") {
                                settings.lightBackground = choice
                            }
                        }
                    }
                }
                section("Dark mode", caption: nil) {
                    HStack(spacing: BighelpTokens.space12) {
                        ForEach(BighelpDarkBackground.allCases) { choice in
                            backgroundTile(name: choice.name, detail: choice.detail,
                                           theme: theme(.dark, dark: choice),
                                           isSelected: settings.darkBackground == choice,
                                           identifier: "appearance.dark.\(choice.rawValue)") {
                                settings.darkBackground = choice
                            }
                        }
                    }
                }
                section("Show", caption: nil) {
                    Picker("Appearance", selection: $settings.appearance) {
                        Text("Automatic").tag(AppAppearance.system)
                        Text("Light").tag(AppAppearance.light)
                        Text("Dark").tag(AppAppearance.dark)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("appearance.mode")
                }
                NavigationLink {
                    BighelpThemePickerView(settings: settings)
                } label: {
                    HStack {
                        Label("More themes", systemImage: "paintpalette")
                            .foregroundStyle(currentTheme.primaryText)
                        Spacer()
                        Text("Custom, import & export")
                            .font(.footnote)
                            .foregroundStyle(currentTheme.secondaryText)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(currentTheme.tertiaryText)
                    }
                    .padding(BighelpTokens.space16)
                    .background(currentTheme.surface, in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("appearance.more-themes")
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.vertical, BighelpTokens.space16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(currentTheme.canvas.ignoresSafeArea())
        .navigationTitle("Colors")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy, value: settings.bubbleColor)
        .animation(.snappy, value: settings.lightBackground)
        .animation(.snappy, value: settings.darkBackground)
        .accessibilityIdentifier("appearance.studio")
    }

    // MARK: Preview

    /// Both modes at once, so a change reads everywhere it applies.
    private var preview: some View {
        HStack(spacing: BighelpTokens.space12) {
            AppearancePreviewCard(theme: theme(.light), title: "Light")
            AppearancePreviewCard(theme: theme(.dark), title: "Dark")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(selectedBubble.name) bubbles, \(settings.lightBackground.name) in light mode, "
            + "\(settings.darkBackground.name) in dark mode")
    }

    // MARK: Bubble colors

    private var selectedBubble: BighelpBubbleColor { settings.bubbleColor ?? .lavender }

    private var bubbleGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BighelpTokens.space12), count: 4),
                  spacing: BighelpTokens.space16) {
            ForEach(BighelpBubbleColor.allCases) { color in
                let isSelected = selectedBubble == color && (settings.bubbleColor != nil || settings.themeID == .bighelp)
                Button {
                    settings.bubbleColor = color == .lavender && settings.themeID == .bighelp ? nil : color
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(Color(hex: color.swatchHex))
                            .frame(width: 44, height: 44)
                            .overlay {
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .padding(3)
                            .overlay(Circle().strokeBorder(isSelected ? currentTheme.primaryText : .clear, lineWidth: 2))
                        Text(color.name)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(currentTheme.primaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(color.name) bubbles")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("appearance.bubble.\(color.rawValue)")
            }
        }
    }

    // MARK: Backgrounds

    private func backgroundTile(name: String, detail: String, theme: BighelpTheme, isSelected: Bool,
                                identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(theme.incomingMessageBackground).frame(width: 64, height: 14)
                    Capsule().fill(theme.action).frame(width: 52, height: 14)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Capsule().fill(theme.incomingMessageBackground).frame(width: 44, height: 14)
                }
                .padding(BighelpTokens.space12)
                .frame(maxWidth: .infinity)
                .background(theme.canvas, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.border.opacity(0.8), lineWidth: 1))
                HStack(spacing: 4) {
                    Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(currentTheme.primaryText)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(currentTheme.action)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(currentTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(BighelpTokens.space12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(currentTheme.surface, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isSelected ? currentTheme.action : .clear, lineWidth: 2))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name). \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, caption: String?,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(currentTheme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                if let caption {
                    Spacer()
                    Text(caption).font(.caption).foregroundStyle(currentTheme.tertiaryText)
                }
            }
            content()
        }
    }

    /// A theme with today's choices, optionally trying a different background.
    private func theme(_ scheme: ColorScheme, light: BighelpLightBackground? = nil,
                       dark: BighelpDarkBackground? = nil) -> BighelpTheme {
        var context = settings.appearanceContext
        context.lightBackground = light ?? settings.lightBackground
        context.darkBackground = dark ?? settings.darkBackground
        return BighelpTheme.resolve(
            appearance: BighelpAppearanceContext(
                appearance: scheme == .dark ? .dark : .light, themeID: context.themeID,
                customTheme: context.customTheme, customLightLogoURL: context.customLightLogoURL,
                customDarkLogoURL: context.customDarkLogoURL, lightBackground: context.lightBackground,
                darkBackground: context.darkBackground, bubbleColor: context.bubbleColor),
            colorScheme: scheme, contrast: contrast)
    }

    @BighelpThemeReader private var currentTheme
}

/// A tiny chat on the chosen background, in one mode.
private struct AppearancePreviewCard: View {
    let theme: BighelpTheme
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(theme.secondaryText)
            bubble("Morning! Want today's plan?", fill: theme.incomingMessageBackground,
                   text: theme.primaryText, alignment: .leading)
            bubble("Yes please ☀️", fill: theme.action, text: theme.actionForeground, alignment: .trailing)
            bubble("On it. Three things…", fill: theme.incomingMessageBackground,
                   text: theme.primaryText, alignment: .leading)
            HStack {
                Capsule().fill(theme.surface).frame(height: 22)
                    .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
                Circle().fill(theme.action).frame(width: 22, height: 22)
                    .overlay(Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.actionForeground))
            }
        }
        .padding(BighelpTokens.space12)
        .frame(maxWidth: .infinity)
        .background(theme.canvas, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(theme.border, lineWidth: 1))
    }

    private func bubble(_ text: String, fill: Color, text textColor: Color, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(textColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(fill, in: .rect(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}
