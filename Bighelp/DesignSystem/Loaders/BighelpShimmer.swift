import SwiftUI

extension View {
    /// A soft highlight that sweeps across secondary-colored text while
    /// `isActive`: "Browsing the web…", "Setting it up…". Works on any text or
    /// label; the text takes the shimmer's colors while it runs.
    ///
    /// Still loaders (Reduce Motion, a background scene, Low Power Mode) show
    /// plain `base` text. When `isActive` is false the view keeps its own colors.
    /// - Parameters:
    ///   - base: the resting color, secondary text by default.
    ///   - highlight: the moving highlight, primary text by default. On a filled
    ///     button pass the button's ink (`base` at 70%, `highlight` at 100%).
    func bighelpShimmer(isActive: Bool, base: Color? = nil, highlight: Color? = nil) -> some View {
        modifier(BighelpShimmerModifier(isActive: isActive, base: base, highlight: highlight))
    }
}

/// Where the highlight sits at a moment. The gradient is 2.6 times the text's
/// width, its highlight a quarter of that, and it travels from just before the
/// text to just past it in one linear pass.
enum BighelpShimmerGeometry {
    static let span = 2.6
    static let stops: [(location: Double, isHighlight: Bool)] = [
        (0, false), (0.38, false), (0.5, true), (0.62, false), (1, false),
    ]

    /// The gradient's leading edge, in units of the text's width.
    static func start(phase: Double) -> Double {
        -(span - 1) * (1 - phase)
    }

    /// The highlight's center, in units of the text's width.
    static func highlightCenter(phase: Double) -> Double {
        start(phase: phase) + span / 2
    }
}

private struct BighelpShimmerModifier: ViewModifier {
    let isActive: Bool
    let base: Color?
    let highlight: Color?

    @BighelpThemeReader private var theme

    func body(content: Content) -> some View {
        if isActive {
            // The text is drawn once in the base color; each frame only moves a
            // highlight masked by a copy of it. Restyling the text itself every
            // frame would make it lay out its glyphs again on every frame.
            let base = base ?? theme.secondaryText
            let highlight = highlight ?? theme.primaryText
            content
                .foregroundStyle(base)
                .overlay {
                    BighelpLoaderClock(cadence: .soft) { time in
                        if !time.isStill {
                            Self.band(at: time, highlight: highlight)
                        }
                    }
                    .mask { content }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            content
        }
    }

    private static func band(at time: BighelpLoaderTime, highlight: Color) -> LinearGradient {
        let start = BighelpShimmerGeometry.start(phase: time.phase(BighelpLoaderTiming.shimmer))
        let stops = BighelpShimmerGeometry.stops.map {
            Gradient.Stop(color: $0.isHighlight ? highlight : highlight.opacity(0), location: $0.location)
        }
        return LinearGradient(
            stops: stops,
            startPoint: UnitPoint(x: start, y: 0.4),
            endPoint: UnitPoint(x: start + BighelpShimmerGeometry.span, y: 0.6)
        )
    }
}
