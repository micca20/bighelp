import SwiftUI

enum BighelpTokens {
    enum Palette {
        static let coralHex = "D33F42"
        static let pinkHex = "E44778"
        static let magentaHex = "B7356F"
        static let orangeHex = "F28B32"
        static let goldHex = "F7C84A"
        static let violetHex = "9A6BFF"

        static let coral = Color(hex: coralHex)
        static let pink = Color(hex: pinkHex)
        static let magenta = Color(hex: magentaHex)
        static let orange = Color(hex: orangeHex)
        static let gold = Color(hex: goldHex)
        static let violet = Color(hex: violetHex)

        static let warmIvory = Color(hex: "FFF9F5")
        static let white = Color(hex: "FFFFFF")
        static let nearBlack = Color(hex: "121110")
        static let charcoal = Color(hex: "1C1A19")
        static let raisedCharcoal = Color(hex: "292624")

        static let successHex = "176B37"
        static let warningHex = "A85D00"
        static let dangerHex = "B42318"
        static let informationHex = "1769AA"

        static let success = Color(hex: successHex)
        static let warning = Color(hex: warningHex)
        static let danger = Color(hex: dangerHex)
        static let information = Color(hex: informationHex)
    }

    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32
    static let space40: CGFloat = 40
    static let space48: CGFloat = 48

    static let radius8: CGFloat = 8
    static let radius12: CGFloat = 12
    static let radius16: CGFloat = 16
    static let radius20: CGFloat = 20
    static let radius28: CGFloat = 28
    static let radiusPill: CGFloat = 999

    // Structural component geometry is intentionally theme-independent. Themes
    // change typography, accent color, and icon character—not hit targets or
    // the shape of shared interaction surfaces.
    static let cardCornerRadius = radius20
    static let menuCornerRadius = radius28
    static let composerCornerRadius = radius28
    static let inputCornerRadius = radius16
    static let menuRowCornerRadius = radius12
    static let generatedContentInsetCornerRadius = radius12

    #if os(visionOS)
    /// Eyes need bigger targets than fingers: visionOS asks for 60pt around
    /// each control. 56 keeps rows compact while staying easy to look at.
    static let hitTarget: CGFloat = 56
    static let controlHeight: CGFloat = 56
    #else
    static let hitTarget: CGFloat = 44
    static let controlHeight: CGFloat = 48
    #endif
    static let composerHeight: CGFloat = 52
    static let primaryActionSize: CGFloat = 56

    static let minimumControlSize = hitTarget
    static let composerMinimumHeight = composerHeight
    static let searchMinimumHeight = controlHeight

    static let pressDuration: TimeInterval = 0.12
    static let stateDuration: TimeInterval = 0.18
    static let transitionDuration: TimeInterval = 0.26
    static let sceneDuration: TimeInterval = 0.42

    static let displayTextStyle: Font.TextStyle = .largeTitle
    static let screenTitleTextStyle: Font.TextStyle = .title2
    static let sectionTitleTextStyle: Font.TextStyle = .title3
    static let bodyTextStyle: Font.TextStyle = .body
    static let labelTextStyle: Font.TextStyle = .subheadline
    static let metadataTextStyle: Font.TextStyle = .caption

    static let displayFont: Font = .system(displayTextStyle, design: .default, weight: .bold)
    static let screenTitleFont: Font = .system(screenTitleTextStyle, design: .default, weight: .bold)
    static let sectionTitleFont: Font = .system(sectionTitleTextStyle, weight: .semibold)
    static let bodyFont: Font = .system(bodyTextStyle)
    static let labelFont: Font = .system(labelTextStyle, weight: .semibold)
    static let metadataFont: Font = .system(metadataTextStyle)

    static let hairline: CGFloat = 1
    static let shadowRadius: CGFloat = 12
    static let shadowY: CGFloat = 4
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
