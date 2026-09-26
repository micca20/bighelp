import SwiftUI
import UIKit

enum LoopdyLogoColor: Equatable, Sendable {
    case assetOriginal
    case themePrimaryText
    case fixedHex(String)
}

struct LoopdyLogoPresentation: Equatable, Sendable {
    let mark: LoopdyLogoColor
    let wordmark: LoopdyLogoColor
    let usesReflectiveMaterial: Bool

    static func resolve(
        themeID: LoopdyThemeID,
        colorScheme: ColorScheme
    ) -> Self {
        guard themeID == .nous || themeID == .superpilot else {
            return LoopdyLogoPresentation(
                mark: .assetOriginal,
                wordmark: .themePrimaryText,
                usesReflectiveMaterial: true
            )
        }

        let monochromeHex = colorScheme == .dark ? "FFFFFF" : "000000"
        return LoopdyLogoPresentation(
            mark: .fixedHex(monochromeHex),
            wordmark: .fixedHex(monochromeHex),
            usesReflectiveMaterial: false
        )
    }
}

struct LoopdyLogo: View {
    enum Presentation {
        case full
        case mark
    }

    let presentation: Presentation
    let height: CGFloat
    let usesMonochromeMark: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAppearance) private var appAppearance

    init(presentation: Presentation = .full, height: CGFloat = 32, usesMonochromeMark: Bool = false) {
        self.presentation = presentation
        self.height = height
        self.usesMonochromeMark = usesMonochromeMark
    }

    var body: some View {
        Group {
            if let customLogoImage {
                Image(uiImage: customLogoImage)
                    .resizable()
                    .scaledToFit()
                    .frame(height: height)
            } else {
                // The Ember identity replaces the legacy infinity artwork.
                switch presentation {
                case .full:
                    EmberLockup(markSize: height)
                case .mark:
                    EmberMark(size: height)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EmberBrand.appName)
        .accessibilityIdentifier(
            customLogoImage == nil ? "loopdy.brand-logo" : "loopdy.custom-theme-logo"
        )
    }

    @ViewBuilder
    private var mark: some View {
        switch logoPresentation.mark {
        case .assetOriginal:
            Image("LoopdyMarkColor")
                .resizable()
                .renderingMode(usesMonochromeMark ? .template : .original)
                .foregroundStyle(color(for: .themePrimaryText))
                .scaledToFit()
        case .themePrimaryText, .fixedHex:
            Image("LoopdyMarkColor")
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(color(for: logoPresentation.mark))
                .scaledToFit()
        }
    }

    private var wordmark: some View {
        Image("LoopdyWordmarkMask")
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(color(for: logoPresentation.wordmark))
            .scaledToFit()
    }

    private var logoPresentation: LoopdyLogoPresentation {
        .resolve(themeID: theme.themeID, colorScheme: colorScheme)
    }

    private var customLogoImage: UIImage? {
        let url = colorScheme == .dark
            ? appAppearance.customDarkLogoURL
            : appAppearance.customLightLogoURL
        guard let url else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private func color(for role: LoopdyLogoColor) -> Color {
        switch role {
        case .assetOriginal, .themePrimaryText:
            theme.primaryText
        case .fixedHex(let hex):
            Color(hex: hex)
        }
    }

    @LoopdyThemeReader private var theme
}

enum LoopdyAnimatedMarkPolicy {
    static func shouldAnimate(
        isActive: Bool,
        reduceMotion: Bool,
        sceneIsActive: Bool,
        isVisible: Bool
    ) -> Bool {
        isActive && !reduceMotion && sceneIsActive && isVisible
    }
}

/// The canonical infinity mark with a restrained traveling highlight for
/// real active work. Terminal, hidden, background, and Reduce Motion states
/// render one quiet static mark instead of consuming animation work.
struct LoopdyAnimatedMark: View {
    let isActive: Bool
    var height: CGFloat = 20

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var body: some View {
        LoopdyThinkingMark(
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
        LoopdyAnimatedMarkPolicy.shouldAnimate(
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
