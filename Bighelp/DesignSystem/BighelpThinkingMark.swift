import Foundation
import SwiftUI

/// Pure animation values for one deterministic frame of the branded thinking mark.
/// Tests can resolve an exact cycle phase without hosting a TimelineView.
struct BighelpThinkingMarkPhasePresentation: Equatable, Sendable {
    let normalizedPhase: Double
    let primaryStreakPhase: Double
    let secondaryStreakPhase: Double
    let highlightOpacity: Double
    let warmBurstOpacity: Double

    static let quiet = Self(
        normalizedPhase: 0,
        primaryStreakPhase: 0.18,
        secondaryStreakPhase: 0.68,
        highlightOpacity: 0,
        warmBurstOpacity: 0.28
    )

    static func resolve(cyclePhase: Double) -> Self {
        let phase = normalized(cyclePhase)
        let shimmer = 0.72 + 0.22 * (0.5 + 0.5 * sin(phase * .pi * 4))
        let burstDistance = circularDistance(from: phase, to: 0.78)
        let burstProgress = max(0, 1 - burstDistance / 0.085)
        let easedBurst = burstProgress * burstProgress * (3 - 2 * burstProgress)

        return Self(
            normalizedPhase: phase,
            primaryStreakPhase: phase,
            secondaryStreakPhase: normalized(phase + 0.47),
            highlightOpacity: shimmer,
            warmBurstOpacity: 0.10 + 0.90 * easedBurst
        )
    }

    static func resolve(
        time: TimeInterval,
        scenario: BighelpThinkingOrbScenario,
        speed: Double
    ) -> Self {
        let effectiveSpeed = max(0, speed) * scenario.thinkingMarkSpeed
        let phase = time * effectiveSpeed / 6.4 + scenario.thinkingMarkPhaseOffset
        return resolve(cyclePhase: phase)
    }

    private static func normalized(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private static func circularDistance(from lhs: Double, to rhs: Double) -> Double {
        let distance = abs(lhs - rhs)
        return min(distance, 1 - distance)
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

/// The canonical bighelp alpha silhouette, animated by light traveling along
/// its asymmetric stem and two lobes. The asset remains the only visible mask.
struct BighelpThinkingMark: View {
    enum Layout: Sendable {
        case square
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var body: some View {
        Group {
            if shouldAnimate {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    renderedMark(
                        phase: .resolve(
                            time: timeline.date.timeIntervalSinceReferenceDate,
                            scenario: scenario,
                            speed: speed
                        )
                    )
                }
            } else {
                renderedMark(phase: .quiet)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
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

    private var containerSize: CGSize {
        switch layout {
        case .square:
            CGSize(width: displaySize, height: displaySize)
        case .markHeight:
            CGSize(
                width: displaySize * BighelpThinkingMarkGeometry.assetAspectRatio,
                height: displaySize
            )
        }
    }

    private var baseColor: Color {
        if let tint { return tint }
        switch surface {
        case .automatic:
            return colorScheme == .dark ? .white : .black
        case .light:
            return .black
        case .dark:
            return .white
        }
    }

    private func renderedMark(phase: BighelpThinkingMarkPhasePresentation) -> some View {
        ZStack {
            markMask
                .foregroundStyle(baseColor.opacity(0.52))

            GeometryReader { geometry in
                let imageRect = BighelpThinkingMarkGeometry.imageRect(in: geometry.size)
                let trackWidth = max(1.1, imageRect.width * 0.072)
                let dash = [imageRect.width * 0.18, imageRect.width * 0.53]
                let travel = (dash[0] + dash[1]) * 5

                BighelpThinkingMarkTrack()
                    .stroke(
                        Color.white.opacity(phase.highlightOpacity * 0.28),
                        style: StrokeStyle(
                            lineWidth: trackWidth * 1.9,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: dash,
                            dashPhase: -CGFloat(phase.primaryStreakPhase) * travel
                        )
                    )
                    .blur(radius: max(0.45, trackWidth * 0.34))

                BighelpThinkingMarkTrack()
                    .stroke(
                        LinearGradient(
                            colors: tint.map { [$0.opacity(0.65), .white, $0, $0.opacity(0.75)] }
                                ?? [.cyan, .white, .purple, .pink],
                            startPoint: .leading,
                            endPoint: .trailing
                        ).opacity(phase.highlightOpacity),
                        style: StrokeStyle(
                            lineWidth: trackWidth,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: dash,
                            dashPhase: -CGFloat(phase.primaryStreakPhase) * travel
                        )
                    )

                BighelpThinkingMarkTrack()
                    .stroke(
                        (tint ?? Color(red: 1, green: 0.76, blue: 0.20))
                            .opacity(phase.highlightOpacity * 0.48),
                        style: StrokeStyle(
                            lineWidth: trackWidth * 0.72,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: dash,
                            dashPhase: -CGFloat(phase.secondaryStreakPhase) * travel
                        )
                    )
            }
            .mask(markAlphaMask)

            if let tint {
                markMask
                    .foregroundStyle(tint)
                    .opacity(phase.warmBurstOpacity)
            } else {
                Image("BighelpMarkColor")
                    .resizable()
                    .scaledToFit()
                    .opacity(phase.warmBurstOpacity)
            }
        }
        .compositingGroup()
    }

    private var markMask: some View {
        Image("BighelpMarkColor")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
    }

    private var markAlphaMask: some View {
        Image("BighelpMarkColor")
            .resizable()
            .scaledToFit()
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

private enum BighelpThinkingMarkGeometry {
    static let assetAspectRatio: CGFloat = 269 / 200

    static func imageRect(in size: CGSize) -> CGRect {
        let availableAspectRatio = size.width / max(size.height, 0.001)
        if availableAspectRatio > assetAspectRatio {
            let width = size.height * assetAspectRatio
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }

        let height = size.width / assetAspectRatio
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }
}

/// A motion guide only. The canonical asset alpha is always applied afterward,
/// so this path can illuminate the mark but can never replace its silhouette.
private struct BighelpThinkingMarkTrack: Shape {
    func path(in rect: CGRect) -> Path {
        let imageRect = BighelpThinkingMarkGeometry.imageRect(in: rect.size)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: imageRect.minX + imageRect.width * x,
                y: imageRect.minY + imageRect.height * y
            )
        }

        var path = Path()
        path.move(to: point(0.142, 0.08))
        path.addLine(to: point(0.142, 0.48))
        path.addCurve(
            to: point(0.36, 0.77),
            control1: point(0.142, 0.72),
            control2: point(0.25, 0.85)
        )
        path.addCurve(
            to: point(0.60, 0.43),
            control1: point(0.45, 0.70),
            control2: point(0.50, 0.54)
        )
        path.addCurve(
            to: point(0.91, 0.61),
            control1: point(0.73, 0.29),
            control2: point(0.91, 0.40)
        )
        path.addCurve(
            to: point(0.60, 0.77),
            control1: point(0.91, 0.82),
            control2: point(0.72, 0.89)
        )
        path.addLine(to: point(0.38, 0.46))
        path.addCurve(
            to: point(0.142, 0.50),
            control1: point(0.27, 0.32),
            control2: point(0.16, 0.36)
        )
        return path
    }
}
