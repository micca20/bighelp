import Foundation
import SwiftUI

enum LoopdySurfaceRole: CaseIterable, Equatable, Sendable {
    case card
    case menu
    case sheet
    case navigation
    case composer
    case input
    case circularControl
    case capsuleControl
    case selected
}

enum LoopdySurfaceFill: Equatable, Sendable {
    case opaque
    case material
    case liquidGlass
}

enum LoopdySurfaceShape: Equatable, Sendable {
    case roundedRectangle
    case circle
    case capsule
}

enum LoopdySurfaceElevation: Equatable, Sendable {
    case none
    case low
    case medium
    case high
}

enum LoopdySurfaceOutline: Equatable, Sendable {
    case standard
    case increased
}

enum LoopdySurfaceOpaqueBase: Equatable, Sendable {
    case surface
    case raisedSurface
}

enum LoopdySurfaceAccentOverlay: Equatable, Sendable {
    case none
    case restrainedAccent
}

enum LoopdySurfaceTint: Equatable, Sendable {
    case none
    case canvas(opacity: Double)
}

struct LoopdySurfacePresentation: Equatable, Sendable {
    let role: LoopdySurfaceRole
    let fill: LoopdySurfaceFill
    let shape: LoopdySurfaceShape
    let cornerRadius: CGFloat
    let elevation: LoopdySurfaceElevation
    let outline: LoopdySurfaceOutline
    let allowsInteractiveGlass: Bool

    var usesInteractiveGlass: Bool {
        fill == .liquidGlass && allowsInteractiveGlass
    }

    var drawsExplicitOutline: Bool {
        fill != .liquidGlass
    }

    func usesInteractiveGlass(whenRequested isInteractive: Bool) -> Bool {
        isInteractive && usesInteractiveGlass
    }

    static func resolve(
        role: LoopdySurfaceRole,
        supportsLiquidGlass: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool,
        uiV2Enabled: Bool = false
    ) -> LoopdySurfacePresentation {
        let metadata = role.metadata
        let fill: LoopdySurfaceFill

        if metadata.alwaysOpaque || reduceTransparency || (uiV2Enabled && role == .input) {
            fill = .opaque
        } else if supportsLiquidGlass {
            fill = .liquidGlass
        } else {
            fill = .material
        }

        return LoopdySurfacePresentation(
            role: role,
            fill: fill,
            shape: metadata.shape,
            cornerRadius: metadata.cornerRadius,
            elevation: increaseContrast ? metadata.elevation.increased : metadata.elevation,
            outline: increaseContrast ? .increased : .standard,
            allowsInteractiveGlass: metadata.allowsInteractiveGlass
        )
    }
}

struct LoopdySurfaceRenderingPlan: Equatable, Sendable {
    let opaqueBase: LoopdySurfaceOpaqueBase?
    let accentOverlay: LoopdySurfaceAccentOverlay

    static func resolve(
        for presentation: LoopdySurfacePresentation,
        uiV2Enabled: Bool = false
    ) -> LoopdySurfaceRenderingPlan {
        guard presentation.fill == .opaque else {
            return LoopdySurfaceRenderingPlan(opaqueBase: nil, accentOverlay: .none)
        }

        switch presentation.role {
        case .card:
            return LoopdySurfaceRenderingPlan(opaqueBase: .surface, accentOverlay: .none)
        case .selected:
            return LoopdySurfaceRenderingPlan(
                opaqueBase: uiV2Enabled ? .raisedSurface : .surface,
                accentOverlay: .restrainedAccent
            )
        case .input:
            return LoopdySurfaceRenderingPlan(
                opaqueBase: uiV2Enabled ? .surface : .raisedSurface,
                accentOverlay: .none
            )
        case .menu, .sheet, .navigation, .composer, .circularControl, .capsuleControl:
            return LoopdySurfaceRenderingPlan(
                opaqueBase: .raisedSurface,
                accentOverlay: .none
            )
        }
    }
}

private extension LoopdySurfaceRole {
    struct Metadata {
        let alwaysOpaque: Bool
        let shape: LoopdySurfaceShape
        let cornerRadius: CGFloat
        let elevation: LoopdySurfaceElevation
        let allowsInteractiveGlass: Bool
    }

    var metadata: Metadata {
        switch self {
        case .card:
            Metadata(
                alwaysOpaque: true,
                shape: .roundedRectangle,
                cornerRadius: 20,
                elevation: .low,
                allowsInteractiveGlass: false
            )
        case .menu:
            Metadata(
                alwaysOpaque: false,
                shape: .roundedRectangle,
                cornerRadius: 28,
                elevation: .high,
                allowsInteractiveGlass: false
            )
        case .sheet:
            Metadata(
                alwaysOpaque: false,
                shape: .roundedRectangle,
                cornerRadius: 28,
                elevation: .high,
                allowsInteractiveGlass: false
            )
        case .navigation:
            Metadata(
                alwaysOpaque: false,
                shape: .roundedRectangle,
                cornerRadius: 28,
                elevation: .medium,
                allowsInteractiveGlass: false
            )
        case .composer:
            Metadata(
                alwaysOpaque: false,
                shape: .roundedRectangle,
                cornerRadius: 28,
                elevation: .medium,
                allowsInteractiveGlass: false
            )
        case .input:
            Metadata(
                alwaysOpaque: false,
                shape: .roundedRectangle,
                cornerRadius: 16,
                elevation: .none,
                allowsInteractiveGlass: true
            )
        case .circularControl:
            Metadata(
                alwaysOpaque: false,
                shape: .circle,
                cornerRadius: 22,
                elevation: .low,
                allowsInteractiveGlass: true
            )
        case .capsuleControl:
            Metadata(
                alwaysOpaque: false,
                shape: .capsule,
                cornerRadius: 999,
                elevation: .low,
                allowsInteractiveGlass: true
            )
        case .selected:
            Metadata(
                alwaysOpaque: true,
                shape: .roundedRectangle,
                cornerRadius: 12,
                elevation: .none,
                allowsInteractiveGlass: false
            )
        }
    }
}

private extension LoopdySurfaceElevation {
    var increased: LoopdySurfaceElevation {
        switch self {
        case .none: .low
        case .low: .medium
        case .medium, .high: .high
        }
    }
}

extension View {
    func loopdySurface(
        _ role: LoopdySurfaceRole,
        isInteractive: Bool = false,
        tint: LoopdySurfaceTint = .none
    ) -> some View {
        modifier(LoopdySurfaceModifier(
            role: role, isInteractive: isInteractive, tint: tint, themeOverride: nil
        ))
    }
}

private struct LoopdySurfaceModifier: ViewModifier {
    let role: LoopdySurfaceRole
    let isInteractive: Bool
    let tint: LoopdySurfaceTint
    let themeOverride: LoopdyTheme?

    @Environment(\.loopdyUIV2Enabled) private var uiV2Enabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appAppearance) private var appAppearance

    func body(content: Content) -> some View {
        let presentation = LoopdySurfacePresentation.resolve(
            role: role,
            supportsLiquidGlass: supportsLiquidGlass,
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased,
            uiV2Enabled: uiV2Enabled
        )
        let theme = themeOverride ?? LoopdyTheme.resolve(
            appearance: appAppearance,
            colorScheme: colorScheme,
            contrast: colorSchemeContrast
        )

        surface(content, presentation: presentation, theme: theme)
    }

    private var supportsLiquidGlass: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return true
        }
        #endif
        return false
    }

    @ViewBuilder
    private func surface(
        _ content: Content,
        presentation: LoopdySurfacePresentation,
        theme: LoopdyTheme
    ) -> some View {
        switch presentation.fill {
        case .opaque:
            content
                .background {
                    opaqueBackground(for: presentation, theme: theme)
                }
                .surfaceChrome(presentation, theme: theme, uiV2Enabled: uiV2Enabled)
        case .material:
            content
                .background(material(for: presentation), in: loopdySurfaceShape(for: presentation))
                .background(tintColor(in: theme), in: loopdySurfaceShape(for: presentation))
                .surfaceChrome(presentation, theme: theme, uiV2Enabled: uiV2Enabled)
        case .liquidGlass:
            liquidGlassSurface(content, presentation: presentation, theme: theme)
        }
    }

    @ViewBuilder
    private func liquidGlassSurface(
        _ content: Content,
        presentation: LoopdySurfacePresentation,
        theme: LoopdyTheme
    ) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let glass: Glass = switch tint {
            case .none:
                .regular
            case .canvas(let opacity):
                .regular.tint(theme.canvas.opacity(opacity))
            }
            if presentation.usesInteractiveGlass(whenRequested: isInteractive) {
                content
                    .surfaceChrome(presentation, theme: theme, uiV2Enabled: uiV2Enabled)
                    .glassEffect(glass.interactive(), in: loopdySurfaceShape(for: presentation))
            } else {
                content
                    .surfaceChrome(presentation, theme: theme, uiV2Enabled: uiV2Enabled)
                    .glassEffect(glass, in: loopdySurfaceShape(for: presentation))
            }
        } else {
            content
                .background(material(for: presentation), in: loopdySurfaceShape(for: presentation))
                .background(tintColor(in: theme), in: loopdySurfaceShape(for: presentation))
                .surfaceChrome(presentation, theme: theme, uiV2Enabled: uiV2Enabled)
        }
        #else
        content
            .background(material(for: presentation), in: loopdySurfaceShape(for: presentation))
            .background(tintColor(in: theme), in: loopdySurfaceShape(for: presentation))
            .surfaceChrome(presentation, theme: theme, uiV2Enabled: uiV2Enabled)
        #endif
    }

    private func tintColor(in theme: LoopdyTheme) -> Color {
        switch tint {
        case .none:
            .clear
        case .canvas(let opacity):
            theme.canvas.opacity(opacity)
        }
    }

    private func opaqueBaseColor(
        for base: LoopdySurfaceOpaqueBase?,
        theme: LoopdyTheme
    ) -> Color {
        switch base {
        case .surface:
            theme.surface
        case .raisedSurface:
            theme.raisedSurface
        case nil:
            .clear
        }
    }

    @ViewBuilder
    private func opaqueBackground(
        for presentation: LoopdySurfacePresentation,
        theme: LoopdyTheme
    ) -> some View {
        let plan = LoopdySurfaceRenderingPlan.resolve(for: presentation, uiV2Enabled: uiV2Enabled)
        let shape = loopdySurfaceShape(for: presentation)

        ZStack {
            shape.fill(opaqueBaseColor(for: plan.opaqueBase, theme: theme))

            if plan.accentOverlay == .restrainedAccent {
                shape.fill(theme.action.opacity(uiV2Enabled ? 0.10 : 0.12))
            }
        }
    }

    private func material(for presentation: LoopdySurfacePresentation) -> Material {
        presentation.outline == .increased ? .thick : .regular
    }
}

private extension View {
    func surfaceChrome(
        _ presentation: LoopdySurfacePresentation,
        theme: LoopdyTheme,
        uiV2Enabled: Bool
    ) -> some View {
        let shape = loopdySurfaceShape(for: presentation)
        let outlineColor = uiV2Enabled
            ? (presentation.outline == .increased ? theme.primaryText : theme.border)
            : Color.primary.opacity(presentation.outline == .increased ? 0.36 : 0.12)
        // V2 reading surfaces stay flat; functional chrome retains native depth.
        let isFlatContent = uiV2Enabled
            && [.card, .input, .selected].contains(presentation.role)

        return clipShape(shape)
            .overlay {
                if presentation.drawsExplicitOutline || (uiV2Enabled && presentation.outline == .increased) {
                    shape.stroke(
                        outlineColor,
                        lineWidth: presentation.outline == .increased ? 2 : LoopdyTokens.hairline
                    )
                    .allowsHitTesting(!uiV2Enabled)
                }
            }
            .shadow(
                color: theme.elevationShadow.opacity(
                    presentation.fill == .liquidGlass || isFlatContent ? 0 : shadowOpacity(
                    for: presentation.elevation,
                    theme: theme
                )),
                radius: shadowRadius(for: presentation.elevation),
                y: shadowY(for: presentation.elevation)
            )
    }

    private func shadowOpacity(
        for elevation: LoopdySurfaceElevation,
        theme: LoopdyTheme
    ) -> Double {
        switch elevation {
        case .none: 0
        case .low: theme.cardShadowOpacity
        case .medium, .high: theme.navigationShadowOpacity
        }
    }

    private func shadowRadius(for elevation: LoopdySurfaceElevation) -> CGFloat {
        switch elevation {
        case .none: 0
        case .low: 6
        case .medium: 12
        case .high: 18
        }
    }

    private func shadowY(for elevation: LoopdySurfaceElevation) -> CGFloat {
        switch elevation {
        case .none: 0
        case .low: 2
        case .medium: 4
        case .high: 8
        }
    }
}

private func loopdySurfaceShape(for presentation: LoopdySurfacePresentation) -> AnyShape {
    switch presentation.shape {
    case .roundedRectangle:
        AnyShape(RoundedRectangle(
            cornerRadius: presentation.cornerRadius,
            style: .continuous
        ))
    case .circle:
        AnyShape(Circle())
    case .capsule:
        AnyShape(Capsule())
    }
}
