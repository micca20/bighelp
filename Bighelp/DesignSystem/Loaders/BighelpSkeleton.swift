import SwiftUI

/// How a skeleton arrives.
enum BighelpSkeletonStyle: Equatable, Sendable {
    /// Shown at once; one sweep crosses every block together. The default.
    case steady
    /// The blocks pop in one after another, then sweep like `steady`.
    case assembles
}

extension View {
    /// Turns a real card into its own skeleton while `isLoading`: give the card
    /// placeholder data, and its text and images draw as soft blocks with one
    /// sweep crossing all of them together. No hand-built skeleton layout.
    ///
    /// While loading, the placeholder data is hidden from VoiceOver (it reads
    /// `accessibilityLabel` instead) and nothing inside takes taps. When loading
    /// ends the card is shown as itself, starting fresh with its real data.
    func bighelpSkeleton(isLoading: Bool, style: BighelpSkeletonStyle = .steady,
                         accessibilityLabel: String = "Loading") -> some View {
        modifier(BighelpSkeletonModifier(isLoading: isLoading, style: style, label: accessibilityLabel))
    }
}

/// A plain skeleton shape for the rare layout that has no real view to redact.
/// Put a group of them in a container with `.bighelpSkeleton(isLoading: true)`
/// so one sweep crosses them all.
struct BighelpSkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat = 12
    var cornerRadius: CGFloat = BighelpTokens.radius8
    /// With `.assembles`, the order this block pops in.
    var assembleIndex: Int?

    @BighelpThemeReader private var theme
    @BighelpLoaderMotionReader private var motion
    @State private var hasAppeared = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(BighelpSkeletonPalette.block(in: theme))
            .frame(width: width, height: height)
            .modifier(BighelpSkeletonPop(index: assembleIndex, isShown: hasAppeared || assembleIndex == nil,
                                         moves: motion.moves))
            .onAppear {
                guard let assembleIndex, !hasAppeared else { return }
                if motion.moves {
                    withAnimation(BighelpLoaderCurve.pop.animation(duration: BighelpLoaderTiming.checkPop)
                        .delay(Double(assembleIndex) * BighelpSkeletonPalette.assembleStagger)) {
                        hasAppeared = true
                    }
                } else {
                    hasAppeared = true
                }
            }
            .accessibilityHidden(true)
    }
}

enum BighelpSkeletonPalette {
    static let assembleStagger: TimeInterval = 0.09

    /// The design's skeleton fill: ink at a whisper (6.5% by day, 6% at night).
    static func block(in theme: BighelpTheme) -> Color {
        theme.primaryText.opacity(theme.isDarkPalette ? 0.06 : 0.065)
    }

    /// The sweep's bright middle: near-white by day, a faint lift at night.
    static func sweep(in theme: BighelpTheme) -> Color {
        .white.opacity(theme.isDarkPalette ? 0.07 : 0.85)
    }

    /// The sweep band's width for a container: about the card's width, so on a
    /// phone it reads as one soft pass, never a stripe.
    static func bandWidth(forContainerWidth width: CGFloat) -> CGFloat {
        min(420, max(140, width * 0.8))
    }

    /// The band's leading edge at a point in the 1.7 s sweep: from just off the
    /// leading edge to just past the trailing one.
    static func bandOffset(phase: Double, containerWidth width: CGFloat) -> CGFloat {
        let band = bandWidth(forContainerWidth: width)
        return -band + CGFloat(BighelpLoaderCurve.easeInOut(phase)) * (width + band * 2)
    }
}

private struct BighelpSkeletonModifier: ViewModifier {
    let isLoading: Bool
    let style: BighelpSkeletonStyle
    let label: String

    @BighelpThemeReader private var theme
    @BighelpLoaderMotionReader private var motion
    @State private var hasAppeared = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLoading {
            content
                .redacted(reason: .placeholder)
                .modifier(BighelpSkeletonSurface(sweep: sweep))
                .modifier(BighelpSkeletonPop(index: style == .assembles ? 0 : nil,
                                             isShown: hasAppeared || style == .steady, moves: motion.moves))
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityAddTraits(.updatesFrequently)
                .onAppear {
                    guard style == .assembles, !hasAppeared else { return }
                    withAnimation(motion.moves ? BighelpLoaderCurve.pop.animation(duration: BighelpLoaderTiming.checkPop) : nil) {
                        hasAppeared = true
                    }
                }
        } else {
            content
        }
    }

    private var sweep: some View {
        let shine = BighelpSkeletonPalette.sweep(in: theme)
        return GeometryReader { proxy in
            BighelpLoaderClock(cadence: .soft) { time in
                if !time.isStill {
                    let width = proxy.size.width
                    let band = BighelpSkeletonPalette.bandWidth(forContainerWidth: width)
                    LinearGradient(
                        colors: [.clear, shine, .clear],
                        startPoint: UnitPoint(x: 0, y: 0.42),
                        endPoint: UnitPoint(x: 1, y: 0.58)
                    )
                    .frame(width: band, height: proxy.size.height)
                    .offset(x: BighelpSkeletonPalette.bandOffset(
                        phase: time.phase(BighelpLoaderTiming.skeletonSweep), containerWidth: width))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Greys the redacted card and lays the sweep over what it draws.
private struct BighelpSkeletonSurface<Sweep: View>: ViewModifier {
    let sweep: Sweep

    func body(content: Content) -> some View {
        content
            // Controls keep their tint under redaction (a progress fill, a
            // badge); a skeleton is neutral, so the whole card goes grey.
            .saturation(0)
            // One sweep for the whole card, kept to what the card draws:
            // `sourceAtop` paints only over the card's own pixels inside the
            // group, so no second copy of the card is built for a mask.
            .overlay { sweep.blendMode(.sourceAtop) }
            .compositingGroup()
    }
}

/// The "assembles" arrival: a small rise and grow from 94% into place.
private struct BighelpSkeletonPop: ViewModifier {
    let index: Int?
    let isShown: Bool
    let moves: Bool

    func body(content: Content) -> some View {
        if index == nil {
            content
        } else {
            content
                .opacity(isShown ? 1 : 0)
                .scaleEffect(isShown || !moves ? 1 : 0.94)
                .offset(y: isShown || !moves ? 0 : 4)
        }
    }
}
