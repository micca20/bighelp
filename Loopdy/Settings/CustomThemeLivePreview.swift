import SwiftUI


/// A labeled, noninteractive sample, not a second settings state. Theme data
/// supplies only the action accent; system colors and type own every neutral.
struct CustomThemeLivePreview: View {
    let palette: LoopdyTheme
    let isDark: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    private var livePalette: LoopdyTheme {
        palette.resolvedForLivePresentation(colorScheme: isDark ? .dark : .light, contrast: contrast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space12) {
            Text("Conversation")
                .font(.headline)
                .foregroundStyle(primaryText)

            HStack {
                Spacer(minLength: LoopdyTokens.space20)
                Text("Accent follows this theme.")
                    .font(.body)
                    .foregroundStyle(livePalette.outgoingMessageForeground)
                    .padding(.horizontal, LoopdyTokens.space12)
                    .padding(.vertical, LoopdyTokens.space8)
                    .background(livePalette.outgoingMessageBackground, in: .rect(cornerRadius: LoopdyTokens.radius16))
            }

            Text("Incoming messages stay neutral.")
                .font(.body)
                .foregroundStyle(primaryText)
                .padding(.horizontal, LoopdyTokens.space12)
                .padding(.vertical, LoopdyTokens.space8)
                .background(incomingSurface, in: .rect(cornerRadius: LoopdyTokens.radius16))

            Divider()

            Label("Links and primary actions use the accent", systemImage: "arrow.up.right.square")
                .font(.subheadline)
                .foregroundStyle(livePalette.action)

            Text("Every theme keeps the same adaptive canvas, cards, type, icons, and layout.")
                .font(.footnote)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LoopdyTokens.space16)
        .background(canvas, in: .rect(cornerRadius: LoopdyTokens.radius20))
        .overlay {
            RoundedRectangle(cornerRadius: LoopdyTokens.radius20)
                .stroke(separator, lineWidth: LoopdyTokens.hairline)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live accent preview, sample content")
        .environment(\.colorScheme, isDark ? .dark : .light)
    }

    private var canvas: Color { livePalette.canvas }
    private var incomingSurface: Color { Color(uiColor: .systemGray5) }
    private var primaryText: Color { livePalette.primaryText }
    private var secondaryText: Color { livePalette.secondaryText }
    private var separator: Color { livePalette.separator }
}

extension CustomThemeColorField {
    var editorLabel: String {
        switch self {
        case .accent: "Actions & selections"
        case .lightBackground: "Light document: Background"
        case .lightPrimaryText: "Light document: Primary text"
        case .lightSecondaryText: "Light document: Secondary text"
        case .lightTertiaryText: "Light document: Tertiary text"
        case .darkBackground: "Dark document: Background"
        case .darkPrimaryText: "Dark document: Primary text"
        case .darkSecondaryText: "Dark document: Secondary text"
        case .darkTertiaryText: "Dark document: Tertiary text"
        }
    }
}
