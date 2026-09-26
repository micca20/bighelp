import SwiftUI

/// Shared live accent sample used by Settings and first-run onboarding.
struct ThemePreview: View {
    let definition: BighelpThemeDefinition
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 0) {
            conversationPreview(isDark: false, label: "Light")
            conversationPreview(isDark: true, label: "Dark")
        }
        .frame(minHeight: 116)
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.black.opacity(0.08), lineWidth: BighelpTokens.hairline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Light and dark \(definition.name) accent preview")
    }

    private func conversationPreview(
        isDark: Bool,
        label: String
    ) -> some View {
        let palette = BighelpTheme.resolve(definition: definition, appearance: .system,
                                         colorScheme: isDark ? .dark : .light, contrast: contrast)
        let canvas = palette.canvas
        let incoming = Color(uiColor: .systemGray5)
        let primaryText = palette.primaryText
        let secondaryText = palette.secondaryText

        return VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack {
                Text(label)
                    .font(.caption.bold())
                Spacer()
                Image(systemName: "ellipsis")
                    .font(.caption)
            }
            .foregroundStyle(secondaryText)
            HStack {
                Spacer(minLength: BighelpTokens.space20)
                Text("Room for ideas.")
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, BighelpTokens.space8)
                    .padding(.vertical, BighelpTokens.space4)
                    .foregroundStyle(palette.outgoingMessageForeground)
                    .background(palette.outgoingMessageBackground, in: .rect(cornerRadius: 11))
            }
            Text("Let's make it happen.")
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, BighelpTokens.space8)
                .padding(.vertical, BighelpTokens.space4)
                .foregroundStyle(primaryText)
                .background(incoming, in: .rect(cornerRadius: 11))
            Spacer(minLength: 0)
        }
        .padding(BighelpTokens.space12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(canvas)
        .environment(\.colorScheme, isDark ? .dark : .light)
    }
}

struct ThemeSwatch: View {
    let themeID: BighelpThemeID
    let customTheme: CustomTheme?
    let size: CGFloat

    init(themeID: BighelpThemeID, customTheme: CustomTheme? = nil, size: CGFloat) {
        self.themeID = themeID
        self.customTheme = customTheme
        self.size = size
    }

    var body: some View {
        let definition = customTheme?.definition ?? BighelpThemeRegistry.definition(for: themeID)
        let lightAccent = definition.map {
            BighelpTheme.resolve(definition: $0, appearance: .light, colorScheme: .light, contrast: .standard).action
        } ?? Color.accentColor
        let darkAccent = definition.map {
            BighelpTheme.resolve(definition: $0, appearance: .dark, colorScheme: .dark, contrast: .standard).action
        } ?? Color.accentColor

        HStack(spacing: size * 0.08) {
            Circle()
                .fill(lightAccent)
                .environment(\.colorScheme, .light)
            Circle()
                .fill(darkAccent)
                .environment(\.colorScheme, .dark)
        }
        .padding(size * 0.2)
        .frame(width: size, height: size)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: size * 0.28))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.28)
                .stroke(Color(uiColor: .separator), lineWidth: BighelpTokens.hairline)
        }
        .accessibilityHidden(true)
    }
}
