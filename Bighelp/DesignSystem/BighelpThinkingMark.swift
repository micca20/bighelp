import Foundation
import SwiftUI

/// One deterministic frame of the working blob: how far each lobe reaches, how
/// far the shape has turned and how full it breathes. Tests resolve exact
/// frames without hosting a TimelineView.
struct BighelpThinkingMarkPhasePresentation: Equatable, Sendable {
    static let lobeCount = 6

    /// Radius of each lobe as a fraction of the resting radius.
    let lobes: [Double]
    let rotation: Double
    let breath: Double

    static let quiet = Self(lobes: Array(repeating: 1, count: lobeCount), rotation: 0, breath: 1)

    static func resolve(time: TimeInterval, scenario: BighelpThinkingOrbScenario, speed: Double) -> Self {
        let t = time * max(0, speed) * scenario.thinkingMarkSpeed + scenario.thinkingMarkPhaseOffset * 10
        let lobes = (0..<lobeCount).map { index -> Double in
            let offset = Double(index) * 2 * .pi / Double(lobeCount)
            return 1 + 0.085 * sin(t * 2.1 + offset * 2) + 0.045 * sin(t * 3.3 - offset * 3)
        }
        return Self(lobes: lobes, rotation: t * 0.35, breath: 0.95 + 0.05 * sin(t * 1.6))
    }
}

enum BighelpThinkingMarkAnimationPolicy {
    static func shouldAnimate(
        isPaused: Bool,
        reduceMotion: Bool,
        sceneIsActive: Bool,
        isVisible: Bool
    ) -> Bool {
        !isPaused && !reduceMotion && sceneIsActive && isVisible
    }
}

/// bighelp's working indicator: a small glossy blob in the accent color that
/// gently morphs while work runs, like the agents' own blob avatars. Still,
/// hidden, background and Reduce Motion states draw one quiet round orb.
struct BighelpThinkingMark: View {
    enum Layout: Sendable {
        case square
        /// Kept for callers sized by line height; the blob is square either way.
        case markHeight
    }

    let scenario: BighelpThinkingOrbScenario
    let displaySize: CGFloat
    let speed: Double
    let isPaused: Bool
    let surface: BighelpThinkingOrbSurface
    let accessibilityLabel: String
    var layout: Layout = .square
    var tint: Color? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @BighelpThemeReader private var theme: BighelpTheme

    var body: some View {
        Group {
            if shouldAnimate {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    blob(.resolve(time: timeline.date.timeIntervalSinceReferenceDate, scenario: scenario, speed: speed))
                }
            } else {
                blob(.quiet)
            }
        }
        .frame(width: displaySize, height: displaySize)
        .fixedSize(horizontal: true, vertical: true)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("loopdy.thinking-mark")
    }

    private var shouldAnimate: Bool {
        speed > 0 && BighelpThinkingMarkAnimationPolicy.shouldAnimate(
            isPaused: isPaused,
            reduceMotion: reduceMotion,
            sceneIsActive: scenePhase == .active,
            isVisible: isVisible
        )
    }

    /// The accent by default; black or white when it sits on a filled button.
    private var fill: Color {
        if let tint { return tint }
        switch surface {
        case .automatic: return theme.action
        case .light: return .black
        case .dark: return .white
        }
    }

    private func blob(_ phase: BighelpThinkingMarkPhasePresentation) -> some View {
        let fill = fill
        return Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 * 0.86 * phase.breath
            let shape = BighelpWorkingBlobPath.path(center: center, radius: radius,
                                                    lobes: phase.lobes, rotation: phase.rotation)
            context.fill(shape, with: .linearGradient(
                Gradient(colors: [fill.opacity(0.78), fill]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: size.height)))
            // Gloss, like the agents' orbs and the Ember mark's shine.
            let shine = CGRect(x: center.x - radius * 0.62, y: center.y - radius * 0.66,
                               width: radius * 0.72, height: radius * 0.44)
            context.fill(Path(ellipseIn: shine), with: .color(.white.opacity(0.42)))
        }
    }
}

/// A smooth closed curve through one point per lobe (Catmull-Rom as cubic Béziers).
enum BighelpWorkingBlobPath {
    static func path(center: CGPoint, radius: CGFloat, lobes: [Double], rotation: Double) -> Path {
        let count = lobes.count
        guard count >= 3 else { return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                               width: radius * 2, height: radius * 2)) }
        let points = (0..<count).map { index -> CGPoint in
            let angle = rotation + Double(index) * 2 * .pi / Double(count)
            let reach = radius * CGFloat(lobes[index])
            return CGPoint(x: center.x + reach * CGFloat(cos(angle)), y: center.y + reach * CGFloat(sin(angle)))
        }
        var path = Path()
        path.move(to: points[0])
        for index in 0..<count {
            let p0 = points[(index - 1 + count) % count], p1 = points[index]
            let p2 = points[(index + 1) % count], p3 = points[(index + 2) % count]
            let k: CGFloat = 1.0 / 6.0
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) * k, y: p1.y + (p2.y - p0.y) * k),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) * k, y: p2.y - (p3.y - p1.y) * k))
        }
        path.closeSubpath()
        return path
    }
}

private extension BighelpThinkingOrbScenario {
    var thinkingMarkSpeed: Double {
        switch self {
        case .working: 1
        case .searching: 1.12
        case .reasoning: 0.76
        case .listening: 0.92
        case .connecting: 1.18
        case .coordinating: 0.84
        case .composing: 0.96
        case .waiting: 0.58
        case .shaping: 0.72
        }
    }

    var thinkingMarkPhaseOffset: Double {
        switch self {
        case .working: 0
        case .searching: 0.07
        case .reasoning: 0.14
        case .listening: 0.21
        case .connecting: 0.28
        case .coordinating: 0.35
        case .composing: 0.42
        case .waiting: 0.49
        case .shaping: 0.56
        }
    }
}
