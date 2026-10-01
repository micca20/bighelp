import SwiftUI
import UIKit

/// Light mode's page color.
enum BighelpLightBackground: String, CaseIterable, Identifiable, Sendable {
    case cream, paper

    var id: String { rawValue }
    var name: String { self == .cream ? "Cream" : "Paper" }
    var detail: String { self == .cream ? "Warm and soft" : "Clean, bright white" }
    var neutral: BighelpTheme { self == .cream ? .light : .paperLight }
}

/// Dark mode's page color.
enum BighelpDarkBackground: String, CaseIterable, Identifiable, Sendable {
    case graphite, black

    var id: String { rawValue }
    var name: String { self == .graphite ? "Graphite" : "Black" }
    var detail: String { self == .graphite ? "Soft charcoal, easy on the eyes" : "True black, saves battery on OLED" }
    var neutral: BighelpTheme { self == .graphite ? .graphiteDark : .blackDark }
}

/// Your chat bubble (and button) color. Lavender is bighelp's own, which
/// shifts lighter after dark; the rest keep their hue and adjust for contrast.
enum BighelpBubbleColor: String, CaseIterable, Identifiable, Sendable {
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

/// A bubble color you pick yourself, kept as six-digit hex ("0E7C66"). Like
/// the others it keeps its hue and adjusts only as far as contrast needs.
enum BighelpCustomBubbleColor {
    static func validated(_ value: String?) -> String? {
        guard var hex = value?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex.uppercased()
    }

    /// The picker's color in sRGB; wide-gamut values are clamped.
    static func hex(from color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: nil)
        return [red, green, blue]
            .map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }
            .joined()
    }
}
