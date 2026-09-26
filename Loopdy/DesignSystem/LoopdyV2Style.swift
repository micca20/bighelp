import SwiftUI

/// Applied by the existing shell theme modifier, including the account gate.
/// Child controls with explicit styles keep ownership of their own geometry.
struct LoopdyV2DefaultsModifier: ViewModifier {
    let theme: LoopdyTheme

    func body(content: Content) -> some View {
        // Keep the root's structural identity stable when the opt-in changes.
        // Native toggles, menus and navigation links retain their platform
        // interaction styles; V2's own button components opt in explicitly.
        content
            .tint(theme.action)
            .foregroundStyle(theme.primaryText)
    }
}

enum LoopdyActionEmphasis {
    case primary
    case secondary
    case quiet
}

/// Use for text actions in V2 branches. Shared icon/pill/menu components already
/// adopt V2 automatically. Labels retain their native Button accessibility.
struct LoopdyV2ButtonStyle: ButtonStyle {
    var emphasis: LoopdyActionEmphasis = .secondary

    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let theme = LoopdyTheme.resolve(
            appearance: appearance, colorScheme: colorScheme, contrast: contrast
        )
        // Destructive actions remain explicitly red and outlined, rather than
        // borrowing an action-ink color that may not contrast with danger.
        let filled = emphasis == .primary && configuration.role != .destructive
        let quiet = emphasis == .quiet
        configuration.label
            .loopdyFont(.label, weight: .semibold)
            .foregroundStyle(configuration.role == .destructive
                ? theme.danger : filled ? theme.actionForeground : theme.primaryText)
            .padding(.horizontal, quiet ? LoopdyTokens.space8 : LoopdyTokens.space16)
            .padding(.vertical, LoopdyTokens.space8)
            .frame(minWidth: LoopdyTokens.hitTarget, minHeight: LoopdyTokens.hitTarget)
            .background(filled ? theme.action : quiet ? .clear : theme.raisedSurface, in: .capsule)
            .overlay {
                if !quiet {
                    Capsule().strokeBorder(
                        filled ? theme.action : contrast == .increased ? theme.primaryText : theme.border,
                        lineWidth: contrast == .increased ? 2 : LoopdyTokens.hairline
                    )
                    .allowsHitTesting(false)
                }
            }
            .contentShape(.capsule)
            .opacity(!isEnabled ? 0.48 : configuration.isPressed ? 0.80 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: LoopdyTokens.pressDuration),
                       value: configuration.isPressed)
    }
}

extension View {
    /// A quiet, theme-owned surface for preference pages and modal editors.
    func loopdyFormSurface() -> some View {
        modifier(LoopdyFormSurfaceModifier())
    }

    /// Replaces native bordered styles only while V2 is enabled. Use at each
    /// explicit action site; a root style cannot override a child's own style.
    func loopdyActionStyle(_ emphasis: LoopdyActionEmphasis = .secondary) -> some View {
        modifier(LoopdyActionStyleModifier(emphasis: emphasis))
    }
}

private struct LoopdyFormSurfaceModifier: ViewModifier {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let theme = LoopdyTheme.resolve(appearance: appearance, colorScheme: colorScheme, contrast: contrast)
        content
            .formStyle(.grouped)
            .loopdyFont(.body)
            .environment(\.defaultMinListRowHeight, LoopdyTokens.hitTarget)
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .tint(theme.action)
    }
}

private struct LoopdyActionStyleModifier: ViewModifier {
    let emphasis: LoopdyActionEmphasis
    @Environment(\.loopdyUIV3Enabled) private var uiV3Enabled
    @Environment(\.loopdyUIV2Enabled) private var uiV2Enabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if uiV3Enabled {
            content.buttonStyle(LoopdyV3ButtonStyle(emphasis: emphasis))
        } else if uiV2Enabled {
            content.buttonStyle(LoopdyV2ButtonStyle(emphasis: emphasis))
        } else {
            switch emphasis {
            case .primary: content.loopdyProminentButtonStyle()
            case .secondary: content.buttonStyle(.bordered)
            case .quiet: content.buttonStyle(.plain)
            }
        }
    }
}

// V3 keeps content on the canvas. Only navigation chrome receives glass;
// collection sections deliberately do not become another layer of cards.
struct LoopdyShellSection<Content: View>: View {
    @Environment(\.loopdyUIV3Enabled) private var uiV3Enabled
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if uiV3Enabled {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, LoopdyTokens.space8)
        } else {
            LoopdyCard { content }
        }
    }
}

extension View {
    /// Applied inside the scroll view, so wide layouts keep one readable column.
    func loopdyShellContentWidth() -> some View {
        modifier(LoopdyShellContentWidthModifier())
    }
}

private struct LoopdyShellContentWidthModifier: ViewModifier {
    @Environment(\.loopdyUIV3Enabled) private var uiV3Enabled

    func body(content: Content) -> some View {
        if uiV3Enabled {
            content
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            content
        }
    }
}

private struct LoopdyV3ButtonStyle: ButtonStyle {
    let emphasis: LoopdyActionEmphasis
    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        let theme = LoopdyTheme.resolve(appearance: appearance, colorScheme: colorScheme, contrast: contrast)
        let filled = emphasis == .primary && configuration.role != .destructive
        let quiet = emphasis == .quiet
        let label = configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(configuration.role == .destructive ? theme.danger
                : filled ? theme.actionForeground : theme.primaryText)
            .padding(.horizontal, quiet ? LoopdyTokens.space8 : LoopdyTokens.space16)
            .padding(.vertical, LoopdyTokens.space8)
            .frame(minWidth: LoopdyTokens.hitTarget, minHeight: LoopdyTokens.hitTarget)
            .contentShape(.rect(cornerRadius: LoopdyTokens.radius12))
            .opacity(!isEnabled ? 0.48 : configuration.isPressed ? 0.8 : 1)

        if quiet {
            label
        } else {
            let fallback = label
                .background(filled ? theme.action : theme.raisedSurface,
                            in: .rect(cornerRadius: LoopdyTokens.radius12))
                .overlay {
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: LoopdyTokens.radius12)
                            .strokeBorder(theme.primaryText, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
            #if compiler(>=6.2)
            if #available(iOS 26.0, *), !reduceTransparency {
                let glass: Glass = filled
                    ? .regular.tint(theme.action).interactive()
                    : .regular.interactive()
                label.glassEffect(
                    glass,
                    in: RoundedRectangle(cornerRadius: LoopdyTokens.radius12, style: .continuous)
                )
            } else {
                fallback
            }
            #else
            fallback
            #endif
        }
    }
}
