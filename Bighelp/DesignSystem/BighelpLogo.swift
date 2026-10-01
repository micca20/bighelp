import SwiftUI
import UIKit

struct BighelpLogo: View {
    enum Presentation {
        case full
        case mark
    }

    let presentation: Presentation
    let height: CGFloat

    init(presentation: Presentation = .full, height: CGFloat = 32) {
        self.presentation = presentation
        self.height = height
    }

    var body: some View {
        Group {
            switch presentation {
            case .full:
                EmberLockup(markSize: height)
            case .mark:
                EmberMark(size: height)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EmberBrand.appName)
        .accessibilityIdentifier("loopdy.brand-logo")
    }
}

enum BighelpAnimatedMarkPolicy {
    static func shouldAnimate(
        isActive: Bool,
        reduceMotion: Bool,
        sceneIsActive: Bool,
        isVisible: Bool
    ) -> Bool {
        isActive && !reduceMotion && sceneIsActive && isVisible
    }
}

/// The working blob for real active work (tool calls, thinking). Finished,
/// hidden, background and Reduce Motion states draw one quiet, dimmed orb.
struct BighelpAnimatedMark: View {
    let isActive: Bool
    var height: CGFloat = 20

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var body: some View {
        BighelpThinkingMark(
            scenario: .working,
            displaySize: height,
            speed: 1,
            isPaused: !shouldAnimate,
            surface: .automatic,
            accessibilityLabel: "Working…",
            layout: .markHeight
        )
        .opacity(isActive ? 1 : 0.58)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .accessibilityHidden(true)
        .accessibilityIdentifier("loopdy.animated-mark")
    }

    private var shouldAnimate: Bool {
        BighelpAnimatedMarkPolicy.shouldAnimate(
            isActive: isActive,
            reduceMotion: reduceMotion,
            sceneIsActive: scenePhase == .active,
            isVisible: isVisible
        )
    }
}

private enum BrandMeasurements {
    static let markToWordmarkHeight: CGFloat = 176.0 / 186.0
    static let gapToHeight: CGFloat = 63.0 / 186.0
}
