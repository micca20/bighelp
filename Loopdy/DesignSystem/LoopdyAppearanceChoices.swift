import SwiftUI

/// Light mode's page color.
enum LoopdyLightBackground: String, CaseIterable, Identifiable, Sendable {
    case cream, paper

    var id: String { rawValue }
    var name: String { self == .cream ? "Cream" : "Paper" }
    var detail: String { self == .cream ? "Warm and soft" : "Clean, bright white" }
    var neutral: LoopdyTheme { self == .cream ? .light : .paperLight }
}

/// Dark mode's page color.
enum LoopdyDarkBackground: String, CaseIterable, Identifiable, Sendable {
    case graphite, black

    var id: String { rawValue }
    var name: String { self == .graphite ? "Graphite" : "Black" }
    var detail: String { self == .graphite ? "Soft charcoal, easy on the eyes" : "True black, saves battery on OLED" }
    var neutral: LoopdyTheme { self == .graphite ? .graphiteDark : .blackDark }
}

/// Your chat bubble (and button) color. Lavender is bighelp's own, which
/// shifts lighter after dark; the rest keep their hue and adjust for contrast.
enum LoopdyBubbleColor: String, CaseIterable, Identifiable, Sendable {
    case lavender, grape, ocean, sky, teal, mint, lime, sunflower, tangerine, coral, rose, graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .lavender: "Lavender"
        case .grape: "Grape"
        case .ocean: "Ocean"
        case .sky: "Sky"
        case .teal: "Teal"
        case .mint: "Mint"
        case .lime: "Lime"
        case .sunflower: "Sunflower"
        case .tangerine: "Tangerine"
        case .coral: "Coral"
        case .rose: "Rose"
        case .graphite: "Ink"
        }
    }

    /// Nil for Lavender: bighelp's built-in violet/lavender pair is used as is.
    var hex: String? {
        switch self {
        case .lavender: nil
        case .grape: "8E44CF"
        case .ocean: "2F6FEB"
        case .sky: "2BA3E8"
        case .teal: "0E9E97"
        case .mint: "22A565"
        case .lime: "6BA30F"
        case .sunflower: "D99A00"
        case .tangerine: "F2711C"
        case .coral: "F0524F"
        case .rose: "E0457B"
        case .graphite: "3A3A3F"
        }
    }

    /// What the swatch shows (Lavender's daytime violet).
    var swatchHex: String { hex ?? "7B52E0" }
}
