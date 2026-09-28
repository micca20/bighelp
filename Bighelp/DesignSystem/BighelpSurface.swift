import Foundation
import SwiftUI

enum BighelpSurfaceRole: CaseIterable, Equatable, Sendable {
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

enum BighelpSurfaceFill: Equatable, Sendable {
    case opaque
    case material
    case liquidGlass
}

enum BighelpSurfaceShape: Equatable, Sendable {
    case roundedRectangle
    case circle
    case capsule
}

enum BighelpSurfaceElevation: Equatable, Sendable {
    case none
    case low
    case medium
    case high
}

enum BighelpSurfaceOutline: Equatable, Sendable {
    case standard
    case increased
}

enum BighelpSurfaceOpaqueBase: Equatable, Sendable {
    case surface
    case raisedSurface
}

enum BighelpSurfaceAccentOverlay: Equatable, Sendable {
    case none
    case restrainedAccent
}

enum BighelpSurfaceTint: Equatable, Sendable {
    case none
    case canvas(opacity: Double)
}

struct BighelpSurfacePresentation: Equatable, Sendable {
    let role: BighelpSurfaceRole
    let fill: BighelpSurfaceFill
    let shape: BighelpSurfaceShape
    let cornerRadius: CGFloat
    let elevation: BighelpSurfaceElevation
    let outline: BighelpSurfaceOutline
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
        role: BighelpSurfaceRole,
        supportsLiquidGlass: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool,
        uiV2Enabled: Bool = false
    ) -> BighelpSurfacePresentation {
        let metadata = role.metadata
        let fill: BighelpSurfaceFill

        if metadata.alwaysOpaque || reduceTransparency || (uiV2Enabled && role == .input) {
            fill = .opaque
        } else if supportsLiquidGlass {
            fill = .liquidGlass
        } else {
            fill = .material
        }

        return BighelpSurfacePresentation(
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

struct BighelpSurfaceRenderingPlan: Equatable, Sendable {
    let opaqueBase: BighelpSurfaceOpaqueBase?
    let accentOverlay: BighelpSurfaceAccentOverlay

    static func resolve(
        for presentation: BighelpSurfacePresentation,
        uiV2Enabled: Bool = false
    ) -> BighelpSurfaceRenderingPlan {
        guard presentation.fill == .opaque else {
            return BighelpSurfaceRenderingPlan(opaqueBase: nil, accentOverlay: .none)
        }

        switch presentation.role {
        case .card:
            return BighelpSurfaceRenderingPlan(opaqueBase: .surface, accentOverlay: .none)
        case .selected:
            return BighelpSurfaceRenderingPlan(
                opaqueBase: uiV2Enabled ? .raisedSurface : .surface,
                accentOverlay: .restrainedAccent
            )
        case .input:
            return BighelpSurfaceRenderingPlan(
                opaqueBase: uiV2Enabled ? .surface : .raisedSurface,
                accentOverlay: .none
            )
        case .menu, .sheet, .navigation, .composer, .circularControl, .capsuleControl:
            return BighelpSurfaceRenderingPlan(
                opaqueBase: .raisedSurface,
                accentOverlay: .none
            )
        }
    }
}

private extension BighelpSurfaceRole {
    struct Metadata {
        let alwaysOpaque: Bool
        let shape: BighelpSurfaceShape
        let cornerRadius: CGFloat
        let elevation: BighelpSurfaceElevation
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

private extension BighelpSurfaceElevation {
    var increased: BighelpSurfaceElevation {
        switch self {
        case .none: .low
        case .low: .medium
        case .medium, .high: .high
        }
    }
}

extension View {
    func bighelpSurface(
        _ role: BighelpSurfaceRole,
        isInteractive: Bool = false,
        tint: BighelpSurfaceTint = .none
    ) -> some View {
        modifier(BighelpSurfaceModifier(
            role: role, isInteractive: isInteractive, tint: tint, themeOverride: nil
        ))
    }
}

private struct BighelpSurfaceModifier: ViewModifier {
    let role: BighelpSurfaceRole
    let isInteractive: Bool
    let tint: BighelpSurfaceTint
    let themeOverride: BighelpTheme?

    @Environment(\.bighelpUIV2Enabled) private var uiV2Enabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appAppearance) private var appAppearance

    func body(content: Content) -> some View {
        let presentation = BighelpSurfacePresentation.resolve(
            role: role,
            supportsLiquidGlass: supportsLiquidGlass,
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased,
            uiV2Enabled: uiV2Enabled
        )
        let theme = themeOverride ?? BighelpTheme.resolve(
            appearance: appAppearance,
            colorScheme: colorScheme,
            contrast: colorSchemeContrast
        )

        surface(content, presentation: presentation, theme: theme)
    }

    private var supportsLiquidGlass: Bool {
        #if compiler(>=6.2) && !os(visionOS) // visionOS has no glassEffect.
        if #available(iOS 26.0, *) {
            return true
        }
        #endif
        return false
    }

    @ViewBuilder
    private func surface(
        _ content: Content,
        presentation: BighelpSurfacePresentation,
        theme: BighelpTheme
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
                .background(material(for: presentation), in: bighelpSurfaceShape(for: presentation))
                .background(tintColor(in: theme), in: bighelpSurfaceShape(for: presentation))
                .surfaceChrome(presentation, theme: theme, uiV2Enabled: uiV2Enabled)
        case .liquidGlass:
            liquidGlassSurface(content, presentation: presentation, theme: theme)
        }
    }

    @ViewBuilder
    private func liquidGlassSurface(
        _ content: Content,
        presentation: BighelpSurfacePresentation,
        theme: BighelpTheme
    ) -> some View {
        #if compiler(>=6.2) && !os(visionOS) // visionOS has no glassEffect.
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
                    .glassEffect(glass.interactive(), in: bighelpSurfaceShape(for: presentation))
            } else {
                content
                    .surfaceChrome(presentation, theme: theme, uiV2Enabled: uiV2Enabled)
                    .glassEffect(glass, in: bighelpSurfaceShape(for: presentation))
            }
        } else {
            content
                .background(material(for: presentation), in: bighelpSurfaceShape(for: presentation))
                .background(tintColor(in: theme), in: bighelpSurfaceShape(for: presentation))
                .surfaceChrome(presentation, theme: theme, uiV2Enabled: uiV2Enabled)
        }
        #else
        content
            .background(material(for: presentation), in: bighelpSurfaceShape(for: presentation))
            .background(tintColor(in: theme), in: bighelpSurfaceShape(for: presentation))
            .surfaceChrome(presentation, theme: theme, uiV2Enabled: uiV2Enabled)
        #endif
    }

    private func tintColor(in theme: BighelpTheme) -> Color {
        switch tint {
        case .none:
            .clear
        case .canvas(let opacity):
            theme.canvas.opacity(opacity)
        }
    }

    private func opaqueBaseColor(
        for base: BighelpSurfaceOpaqueBase?,
        theme: BighelpTheme
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
        for presentation: BighelpSurfacePresentation,
        theme: BighelpTheme
    ) -> some View {
        let plan = BighelpSurfaceRenderingPlan.resolve(for: presentation, uiV2Enabled: uiV2Enabled)
        let shape = bighelpSurfaceShape(for: presentation)

        ZStack {
            shape.fill(opaqueBaseColor(for: plan.opaqueBase, theme: theme))

            if plan.accentOverlay == .restrainedAccent {
                shape.fill(theme.action.opacity(uiV2Enabled ? 0.10 : 0.12))
            }
        }
    }

    private func material(for presentation: BighelpSurfacePresentation) -> Material {
        presentation.outline == .increased ? .thick : .regular
    }
}

private extension View {
    func surfaceChrome(
        _ presentation: BighelpSurfacePresentation,
        theme: BighelpTheme,
        uiV2Enabled: Bool
    ) -> some View {
        let shape = bighelpSurfaceShape(for: presentation)
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
                        lineWidth: presentation.outline == .increased ? 2 : BighelpTokens.hairline
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
        for elevation: BighelpSurfaceElevation,
        theme: BighelpTheme
    ) -> Double {
        switch elevation {
        case .none: 0
        case .low: theme.cardShadowOpacity
        case .medium, .high: theme.navigationShadowOpacity
        }
    }

    private func shadowRadius(for elevation: BighelpSurfaceElevation) -> CGFloat {
        switch elevation {
        case .none: 0
        case .low: 6
        case .medium: 12
        case .high: 18
        }
    }

    private func shadowY(for elevation: BighelpSurfaceElevation) -> CGFloat {
        switch elevation {
        case .none: 0
        case .low: 2
        case .medium: 4
        case .high: 8
        }
    }
}

private func bighelpSurfaceShape(for presentation: BighelpSurfacePresentation) -> AnyShape {
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
