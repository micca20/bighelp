import Foundation
import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case light
    case dark

    var id: Self { self }
}

struct BighelpThemeID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var id: String { rawValue }

    static let bighelp = BighelpThemeID(rawValue: "loopdy")
    static let nous = BighelpThemeID(rawValue: "nous")
    static let superpilot = BighelpThemeID(rawValue: "superpilot")
}

enum BighelpThemeTypeface: String, Codable, Equatable, Sendable {
    case system
    case monospaced
    case rounded
    case serif
}

enum BighelpThemeIconStyle: String, Codable, Equatable, Sendable {
    case soft
    case technical
    case crisp
}

enum BighelpIconRenderingMode: Equatable, Sendable {
    case hierarchical
    case monochrome
}

enum BighelpIconSymbolVariant: Equatable, Sendable {
    case filled
    case outline
}

enum BighelpIconGlyphWeight: Equatable, Sendable {
    case regular
    case semibold
}

enum BighelpIconInnerWell: Equatable, Sendable {
    case tintedCircle
    case outlinedRoundedRectangle
    case none
}

struct BighelpIconPresentation: Equatable, Sendable {
    let renderingMode: BighelpIconRenderingMode
    let symbolVariant: BighelpIconSymbolVariant
    let glyphWeight: BighelpIconGlyphWeight
    let innerWell: BighelpIconInnerWell

    static func resolve(style: BighelpThemeIconStyle) -> BighelpIconPresentation {
        switch style {
        case .soft:
            BighelpIconPresentation(
                renderingMode: .hierarchical,
                symbolVariant: .filled,
                glyphWeight: .semibold,
                innerWell: .tintedCircle
            )
        case .technical:
            BighelpIconPresentation(
                renderingMode: .monochrome,
                symbolVariant: .outline,
                glyphWeight: .regular,
                innerWell: .outlinedRoundedRectangle
            )
        case .crisp:
            BighelpIconPresentation(
                renderingMode: .monochrome,
                symbolVariant: .outline,
                glyphWeight: .semibold,
                innerWell: .none
            )
        }
    }
}

struct BighelpThemeTypography: Codable, Equatable, Sendable {
    let displayFontNames: [String]
    let bodyFontNames: [String]
    let emphasizedBodyFontNames: [String]
    let codeFontNames: [String]
    let brandFontNames: [String]

    // Empty candidates select Apple's system font, preserving Dynamic Type.
    // Other built-in themes and user-created themes keep their explicit faces.
    static let bighelp = BighelpThemeTypography(
        displayFontNames: [], bodyFontNames: [], emphasizedBodyFontNames: [],
        codeFontNames: [], brandFontNames: []
    )

    static let nous = BighelpThemeTypography(
        displayFontNames: ["Sigurd Variable", "SigurdVariable", "Sigurd-Variable"],
        bodyFontNames: ["Rules Variable", "RulesVariable", "Rules-Variable"],
        emphasizedBodyFontNames: ["Rules Variable", "RulesVariable", "Rules-Variable"],
        codeFontNames: [],
        brandFontNames: ["Rules Variable", "RulesVariable", "Rules-Variable"]
    )

    static let superpilot = BighelpThemeTypography(
        displayFontNames: ["Segoe UI Semibold", "SegoeUI-Semibold"],
        bodyFontNames: ["Segoe UI", "SegoeUI", "SegoeUI-Regular"],
        emphasizedBodyFontNames: ["Segoe UI Semibold", "SegoeUI-Semibold"],
        codeFontNames: ["Segoe UI Mono", "SegoeUIMono-Regular"],
        brandFontNames: ["Segoe UI Semibold", "SegoeUI-Semibold"]
    )
}

enum CustomThemeFontChoice: String, CaseIterable, Identifiable, Codable, Equatable, Sendable {
    case system
    case rounded
    case serif
    case monospaced
    case notoSans

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .monospaced: "Monospaced"
        case .notoSans: "Noto Sans"
        }
    }

    fileprivate var typeface: BighelpThemeTypeface {
        switch self {
        case .system, .notoSans: .system
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }

    fileprivate var typography: BighelpThemeTypography {
        switch self {
        case .notoSans:
            BighelpThemeTypography(
                displayFontNames: ["Noto Sans SemiBold"],
                bodyFontNames: ["Noto Sans"],
                emphasizedBodyFontNames: ["Noto Sans SemiBold"],
                codeFontNames: ["Noto Sans"],
                brandFontNames: ["Noto Sans SemiBold"]
            )
        case .system, .rounded, .serif, .monospaced:
            BighelpThemeTypography(
                displayFontNames: [],
                bodyFontNames: [],
                emphasizedBodyFontNames: [],
                codeFontNames: [],
                brandFontNames: []
            )
        }
    }
}

enum CustomThemeColorField: String, Equatable, Sendable {
    case accent
    case lightBackground
    case lightPrimaryText
    case lightSecondaryText
    case lightTertiaryText
    case darkBackground
    case darkPrimaryText
    case darkSecondaryText
    case darkTertiaryText
}

enum CustomThemeValidationError: Error, Equatable, Sendable {
    case invalidName
    case invalidDescription
    case invalidColor(CustomThemeColorField)
    case insufficientContrast(CustomThemeColorField)
    case invalidLogoMetadata
}

enum CustomThemeLogoFormat: String, Codable, Equatable, Sendable {
    case png
    case jpeg
    case heic

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }
}

struct CustomThemeLogo: Codable, Equatable, Sendable {
    let id: UUID
    let format: CustomThemeLogoFormat
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int

    var fileName: String {
        "custom-theme-logo-\(id.uuidString.lowercased()).\(format.fileExtension)"
    }
}

enum CustomThemeLogoVariant: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct CustomThemePalette: Codable, Equatable, Sendable {
    let backgroundHex: String
    let primaryTextHex: String
    let secondaryTextHex: String
    let tertiaryTextHex: String
}

struct CustomTheme: Codable, Equatable, Identifiable, Sendable {
    static let maximumNameLength = 40
    static let maximumDescriptionLength = 120
    static let minimumTextContrast = 4.5

    let id: UUID
    let name: String
    let description: String?
    let font: CustomThemeFontChoice
    let accentHex: String
    let light: CustomThemePalette
    let dark: CustomThemePalette
    let lightLogo: CustomThemeLogo?
    let darkLogo: CustomThemeLogo?

    /// Compatibility alias for themes created before separate appearance logos.
    var logo: CustomThemeLogo? { lightLogo ?? darkLogo }

    init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        font: CustomThemeFontChoice,
        accentHex: String,
        light: CustomThemePalette,
        dark: CustomThemePalette,
        logo: CustomThemeLogo? = nil,
        lightLogo: CustomThemeLogo? = nil,
        darkLogo: CustomThemeLogo? = nil
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.count <= Self.maximumNameLength,
              normalizedName.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw CustomThemeValidationError.invalidName
        }

        self.id = id
        self.name = normalizedName
        if let description {
            let normalizedDescription = description
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
            guard normalizedDescription.count <= Self.maximumDescriptionLength,
                  normalizedDescription.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  })
            else { throw CustomThemeValidationError.invalidDescription }
            self.description = normalizedDescription.isEmpty ? nil : normalizedDescription
        } else {
            self.description = nil
        }
        self.font = font
        self.accentHex = try Self.normalize(accentHex, field: .accent)
        self.light = try Self.normalized(
            light,
            fields: (
                background: .lightBackground,
                primary: .lightPrimaryText,
                secondary: .lightSecondaryText,
                tertiary: .lightTertiaryText
            )
        )
        self.dark = try Self.normalized(
            dark,
            fields: (
                background: .darkBackground,
                primary: .darkPrimaryText,
                secondary: .darkSecondaryText,
                tertiary: .darkTertiaryText
            )
        )
        let resolvedLightLogo = lightLogo ?? logo
        let resolvedDarkLogo = darkLogo ?? logo
        for logo in [resolvedLightLogo, resolvedDarkLogo].compactMap({ $0 }) {
            let (pixelCount, overflow) = logo.pixelWidth.multipliedReportingOverflow(
                by: logo.pixelHeight
            )
            guard logo.pixelWidth > 0,
                  logo.pixelHeight > 0,
                  logo.byteCount > 0,
                  logo.byteCount <= CustomThemeLogoStore.maximumByteCount,
                  logo.pixelWidth <= CustomThemeLogoStore.maximumDimension,
                  logo.pixelHeight <= CustomThemeLogoStore.maximumDimension,
                  !overflow,
                  pixelCount <= CustomThemeLogoStore.maximumPixelCount
            else { throw CustomThemeValidationError.invalidLogoMetadata }
        }
        self.lightLogo = resolvedLightLogo
        self.darkLogo = resolvedDarkLogo
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case font
        case accentHex
        case light
        case dark
        case logo
        case lightLogo
        case darkLogo
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                name: container.decode(String.self, forKey: .name),
                description: container.decodeIfPresent(String.self, forKey: .description),
                font: container.decode(CustomThemeFontChoice.self, forKey: .font),
                accentHex: container.decode(String.self, forKey: .accentHex),
                light: container.decode(CustomThemePalette.self, forKey: .light),
                dark: container.decode(CustomThemePalette.self, forKey: .dark),
                logo: container.decodeIfPresent(CustomThemeLogo.self, forKey: .logo),
                lightLogo: container.decodeIfPresent(CustomThemeLogo.self, forKey: .lightLogo),
                darkLogo: container.decodeIfPresent(CustomThemeLogo.self, forKey: .darkLogo)
            )
        } catch let error as CustomThemeValidationError {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: "Invalid custom theme: \(error)"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(font, forKey: .font)
        try container.encode(accentHex, forKey: .accentHex)
        try container.encode(light, forKey: .light)
        try container.encode(dark, forKey: .dark)
        try container.encodeIfPresent(lightLogo, forKey: .lightLogo)
        try container.encodeIfPresent(darkLogo, forKey: .darkLogo)
    }

    var themeID: BighelpThemeID {
        BighelpThemeID(rawValue: "custom.\(id.uuidString.lowercased())")
    }

    func replacingLogo(
        _ logo: CustomThemeLogo?,
        variant: CustomThemeLogoVariant? = nil
    ) throws -> CustomTheme {
        try CustomTheme(
            id: id,
            name: name,
            description: description,
            font: font,
            accentHex: accentHex,
            light: light,
            dark: dark,
            lightLogo: variant == .dark ? lightLogo : logo,
            darkLogo: variant == .light ? darkLogo : logo
        )
    }

    var definition: BighelpThemeDefinition {
        let lightTheme = Self.makeTheme(palette: light, isDark: false, themeID: themeID, font: font, accentHex: accentHex)
        let darkTheme = Self.makeTheme(palette: dark, isDark: true, themeID: themeID, font: font, accentHex: accentHex)
        return BighelpThemeDefinition(
            id: themeID,
            name: name,
            summary: description ?? "Custom theme using \(font.title).",
            light: lightTheme,
            lightHighContrast: lightTheme,
            dark: darkTheme,
            darkHighContrast: darkTheme
        )
    }

    /// A non-persistable editor preview. Syntax is checked, but low-contrast
    /// drafts remain visible so people can understand and correct them. Saving
    /// still goes through CustomTheme's full contrast and metadata validation.
    static func previewPalette(
        palette: CustomThemePalette,
        accentHex: String,
        font: CustomThemeFontChoice,
        isDark: Bool
    ) throws -> BighelpTheme {
        let normalizedPalette = try CustomThemePalette(
            backgroundHex: normalize(palette.backgroundHex, field: isDark ? .darkBackground : .lightBackground),
            primaryTextHex: normalize(palette.primaryTextHex, field: isDark ? .darkPrimaryText : .lightPrimaryText),
            secondaryTextHex: normalize(palette.secondaryTextHex, field: isDark ? .darkSecondaryText : .lightSecondaryText),
            tertiaryTextHex: normalize(palette.tertiaryTextHex, field: isDark ? .darkTertiaryText : .lightTertiaryText)
        )
        return try makeTheme(
            palette: normalizedPalette, isDark: isDark,
            themeID: BighelpThemeID(rawValue: "custom-editor-preview"),
            font: font, accentHex: normalize(accentHex, field: .accent)
        )
    }

    private static func makeTheme(
        palette: CustomThemePalette,
        isDark: Bool,
        themeID: BighelpThemeID,
        font: CustomThemeFontChoice,
        accentHex: String
    ) -> BighelpTheme {
        BighelpTheme(
            themeID: themeID,
            typeface: font.typeface,
            typography: font.typography,
            iconStyle: .soft,
            cornerScale: 1,
            backgroundAccentHexes: [accentHex, palette.backgroundHex],
            canvasHex: palette.backgroundHex,
            surfaceHex: Self.blend(
                palette.backgroundHex,
                toward: palette.primaryTextHex,
                fraction: 0.04
            ),
            raisedSurfaceHex: Self.blend(
                palette.backgroundHex,
                toward: palette.primaryTextHex,
                fraction: 0.08
            ),
            primaryTextHex: palette.primaryTextHex,
            secondaryTextHex: palette.secondaryTextHex,
            tertiaryTextHex: palette.tertiaryTextHex,
            borderHex: Self.blend(
                palette.backgroundHex,
                toward: palette.primaryTextHex,
                fraction: 0.18
            ),
            separatorHex: Self.blend(
                palette.backgroundHex,
                toward: palette.primaryTextHex,
                fraction: 0.12
            ),
            actionHex: accentHex,
            actionForegroundHex: Self.contrastingForeground(for: accentHex),
            actionGlowHex: accentHex,
            elevationShadowHex: "000000",
            actionGlowOpacity: isDark ? 0.34 : 0.24,
            cardShadowOpacity: isDark ? 0.24 : 0.07,
            navigationShadowOpacity: isDark ? 0.34 : 0.14,
            successHex: isDark ? "63C982" : "176B37",
            warningHex: isDark ? "F3B24F" : "A85D00",
            dangerHex: isDark ? "FF7A70" : "B42318",
            informationHex: accentHex,
            focusHex: accentHex
        )
    }

    private static func normalized(
        _ palette: CustomThemePalette,
        fields: (
            background: CustomThemeColorField,
            primary: CustomThemeColorField,
            secondary: CustomThemeColorField,
            tertiary: CustomThemeColorField
        )
    ) throws -> CustomThemePalette {
        let background = try normalize(palette.backgroundHex, field: fields.background)
        let primary = try normalize(palette.primaryTextHex, field: fields.primary)
        let secondary = try normalize(palette.secondaryTextHex, field: fields.secondary)
        let tertiary = try normalize(palette.tertiaryTextHex, field: fields.tertiary)

        for (text, field) in [
            (primary, fields.primary),
            (secondary, fields.secondary),
            (tertiary, fields.tertiary),
        ] where contrastRatio(text, background) < minimumTextContrast {
            throw CustomThemeValidationError.insufficientContrast(field)
        }

        return CustomThemePalette(
            backgroundHex: background,
            primaryTextHex: primary,
            secondaryTextHex: secondary,
            tertiaryTextHex: tertiary
        )
    }

    private static func normalize(
        _ value: String,
        field: CustomThemeColorField
    ) throws -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("#") {
            normalized.removeFirst()
        }
        normalized = normalized.uppercased()
        let hexadecimalCharacters = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard normalized.count == 6,
              normalized.unicodeScalars.allSatisfy({ hexadecimalCharacters.contains($0) })
        else {
            throw CustomThemeValidationError.invalidColor(field)
        }
        return normalized
    }

    private static func contrastRatio(_ firstHex: String, _ secondHex: String) -> Double {
        let first = luminance(firstHex)
        let second = luminance(secondHex)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func luminance(_ hex: String) -> Double {
        let channels = rgb(hex).map { channel -> Double in
            let component = Double(channel) / 255
            return component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return (0.2126 * channels[0]) + (0.7152 * channels[1]) + (0.0722 * channels[2])
    }

    private static func contrastingForeground(for backgroundHex: String) -> String {
        contrastRatio("FFFFFF", backgroundHex) >= contrastRatio("000000", backgroundHex)
            ? "FFFFFF"
            : "000000"
    }

    private static func blend(
        _ sourceHex: String,
        toward targetHex: String,
        fraction: Double
    ) -> String {
        let source = rgb(sourceHex)
        let target = rgb(targetHex)
        return zip(source, target).map { sourceChannel, targetChannel in
            let value = Double(sourceChannel)
                + ((Double(targetChannel) - Double(sourceChannel)) * fraction)
            return String(format: "%02X", Int(value.rounded()))
        }.joined()
    }

    private static func rgb(_ hex: String) -> [Int] {
        let value = Int(hex, radix: 16) ?? 0
        return [
            (value >> 16) & 0xFF,
            (value >> 8) & 0xFF,
            value & 0xFF,
        ]
    }
}

struct BighelpTheme: Codable, Equatable, Sendable {
    let themeID: BighelpThemeID
    let typeface: BighelpThemeTypeface
    let typography: BighelpThemeTypography
    let iconStyle: BighelpThemeIconStyle
    let cornerScale: CGFloat
    let backgroundAccentHexes: [String]
    let canvasHex: String
    let surfaceHex: String
    let raisedSurfaceHex: String
    let primaryTextHex: String
    let secondaryTextHex: String
    let tertiaryTextHex: String
    let borderHex: String
    let separatorHex: String
    let actionHex: String
    let actionForegroundHex: String
    let actionGlowHex: String
    let elevationShadowHex: String
    let actionGlowOpacity: Double
    let cardShadowOpacity: Double
    let navigationShadowOpacity: Double
    let successHex: String
    let warningHex: String
    let dangerHex: String
    let informationHex: String
    let focusHex: String
    // Raw theme definitions remain exact, Codable design documents. Only
    // values returned by `resolve` opt into the shared live visual system.
    private var resolvesLiveSemantics = false

    private enum CodingKeys: String, CodingKey {
        case themeID
        case typeface
        case typography
        case iconStyle
        case cornerScale
        case backgroundAccentHexes
        case canvasHex
        case surfaceHex
        case raisedSurfaceHex
        case primaryTextHex
        case secondaryTextHex
        case tertiaryTextHex
        case borderHex
        case separatorHex
        case actionHex
        case actionForegroundHex
        case actionGlowHex
        case elevationShadowHex
        case actionGlowOpacity
        case cardShadowOpacity
        case navigationShadowOpacity
        case successHex
        case warningHex
        case dangerHex
        case informationHex
        case focusHex
    }

    init(
        themeID: BighelpThemeID = .bighelp,
        typeface: BighelpThemeTypeface = .system,
        typography: BighelpThemeTypography = .bighelp,
        iconStyle: BighelpThemeIconStyle = .crisp,
        cornerScale: CGFloat = 1,
        backgroundAccentHexes: [String] = ["FF5A4F", "FFB326", "ED4672"],
        canvasHex: String,
        surfaceHex: String,
        raisedSurfaceHex: String,
        primaryTextHex: String,
        secondaryTextHex: String,
        tertiaryTextHex: String,
        borderHex: String,
        separatorHex: String,
        actionHex: String,
        actionForegroundHex: String,
        actionGlowHex: String,
        elevationShadowHex: String,
        actionGlowOpacity: Double,
        cardShadowOpacity: Double,
        navigationShadowOpacity: Double,
        successHex: String,
        warningHex: String,
        dangerHex: String,
        informationHex: String,
        focusHex: String
    ) {
        self.themeID = themeID
        self.typeface = typeface
        self.typography = typography
        self.iconStyle = iconStyle
        self.cornerScale = cornerScale
        self.backgroundAccentHexes = backgroundAccentHexes
        self.canvasHex = canvasHex
        self.surfaceHex = surfaceHex
        self.raisedSurfaceHex = raisedSurfaceHex
        self.primaryTextHex = primaryTextHex
        self.secondaryTextHex = secondaryTextHex
        self.tertiaryTextHex = tertiaryTextHex
        self.borderHex = borderHex
        self.separatorHex = separatorHex
        self.actionHex = actionHex
        self.actionForegroundHex = actionForegroundHex
        self.actionGlowHex = actionGlowHex
        self.elevationShadowHex = elevationShadowHex
        self.actionGlowOpacity = actionGlowOpacity
        self.cardShadowOpacity = cardShadowOpacity
        self.navigationShadowOpacity = navigationShadowOpacity
        self.successHex = successHex
        self.warningHex = warningHex
        self.dangerHex = dangerHex
        self.informationHex = informationHex
        self.focusHex = focusHex
    }

    /// Live chrome uses the Ember neutrals (cream by day, "after dark" at night)
    /// carried in the resolved hexes. Raw partner/custom definitions remain
    /// directly renderable by theme editors and import/export flows.
    private var usesNativeSystemPalette: Bool { false }

    var canvas: Color {
        usesNativeSystemPalette ? Color(uiColor: .systemBackground) : Color(hex: canvasHex)
    }
    var surface: Color {
        usesNativeSystemPalette ? Color(uiColor: .secondarySystemBackground) : Color(hex: surfaceHex)
    }
    var raisedSurface: Color {
        usesNativeSystemPalette ? Color(uiColor: .systemBackground) : Color(hex: raisedSurfaceHex)
    }
    var primaryText: Color {
        usesNativeSystemPalette ? Color(uiColor: .label) : Color(hex: primaryTextHex)
    }
    var secondaryText: Color {
        usesNativeSystemPalette ? Color(uiColor: .secondaryLabel) : Color(hex: secondaryTextHex)
    }
    var tertiaryText: Color {
        usesNativeSystemPalette ? Color(uiColor: .tertiaryLabel) : Color(hex: tertiaryTextHex)
    }
    var border: Color {
        usesNativeSystemPalette ? Color(uiColor: .separator) : Color(hex: borderHex)
    }
    var separator: Color {
        usesNativeSystemPalette ? Color(uiColor: .separator) : Color(hex: separatorHex)
    }
    var action: Color { Color(hex: actionHex) }
    var actionForeground: Color {
        guard resolvesLiveSemantics, themeID != .bighelp else { return Color(hex: actionForegroundHex) }
        let accent = liveActionUIColor
        return Color(uiColor: UIColor { traits in
            let resolvedAccent = accent.resolvedColor(with: traits)
            return Self.readableForeground(against: resolvedAccent)
        })
    }
    /// Outgoing messages always use white ink. Keep that policy separate from
    /// action/link ink, which must remain readable on neutral native surfaces.
    /// The authored accent is darkened only when its white-text contrast needs it;
    /// stored theme documents and the shared action API remain unchanged.
    var outgoingMessageForeground: Color { .white }
    var outgoingMessageBackground: Color {
        if themeID == .bighelp { return Color(hex: Self.emberOutgoingHex) }
        return accessibleOutgoingMessageBackground(
            accent: resolvesLiveSemantics ? liveActionUIColor : Self.uiColor(hex: actionHex)
        )
    }

    private func accessibleOutgoingMessageBackground(accent: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            Self.whiteTextBubbleBackground(
                accent.resolvedColor(with: traits),
                minimumContrast: 4.6
            )
        })
    }
    var actionGlow: Color { Color(hex: actionGlowHex) }

    /// Agent replies sit on a warm neutral that matches the canvas.
    var incomingMessageBackground: Color {
        Color(hex: isDarkPalette ? "292624" : "F3ECE6")
    }

    var isDarkPalette: Bool {
        let value = UInt64(canvasHex, radix: 16) ?? 0
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.4
    }

    static let emberOutgoingHex = "7B52E0"
    var elevationShadow: Color { Color(hex: elevationShadowHex) }
    var success: Color {
        usesNativeSystemPalette ? Color(uiColor: .systemGreen) : Color(hex: successHex)
    }
    var warning: Color {
        usesNativeSystemPalette ? Color(uiColor: .systemOrange) : Color(hex: warningHex)
    }
    var danger: Color {
        usesNativeSystemPalette ? Color(uiColor: .systemRed) : Color(hex: dangerHex)
    }
    var information: Color {
        usesNativeSystemPalette ? Color(uiColor: .systemBlue) : Color(hex: informationHex)
    }
    var focus: Color {
        resolvesLiveSemantics ? action : Color(hex: focusHex)
    }
    var backgroundAccents: [Color] {
        resolvesLiveSemantics
            ? [surface, raisedSurface]
            : backgroundAccentHexes.map(Color.init(hex:))
    }

    var cardBackground: Color { surface }
    var navigationBackground: Color { raisedSurface }
    var statusBackground: Color { raisedSurface }

    private var liveActionUIColor: UIColor { Self.uiColor(hex: actionHex) }

    private static func uiColor(hex: String) -> UIColor {
        let value = UInt64(hex, radix: 16) ?? 0
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func whiteTextBubbleBackground(
        _ accent: UIColor,
        minimumContrast: CGFloat
    ) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        guard accent.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return UIColor(red: 0, green: 0.32, blue: 0.68, alpha: 1)
        }

        func whiteContrast(scale: CGFloat) -> CGFloat {
            let luminance = 0.2126 * linearChannel(red * scale)
                + 0.7152 * linearChannel(green * scale)
                + 0.0722 * linearChannel(blue * scale)
            return 1.05 / (luminance + 0.05)
        }

        guard whiteContrast(scale: 1) < minimumContrast else { return accent }
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<14 {
            let midpoint = (lower + upper) / 2
            if whiteContrast(scale: midpoint) >= minimumContrast {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        return UIColor(red: red * lower, green: green * lower, blue: blue * lower, alpha: alpha)
    }

    private static func readableForeground(against background: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard background.getRed(&red, green: &green, blue: &blue, alpha: nil) else {
            return .label
        }
        let luminance = 0.2126 * linearChannel(red)
            + 0.7152 * linearChannel(green)
            + 0.0722 * linearChannel(blue)
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return whiteContrast >= blackContrast ? .white : .black
    }

    private static func linearChannel(_ channel: CGFloat) -> CGFloat {
        channel <= 0.04045
            ? channel / 12.92
            : CGFloat(pow(Double((channel + 0.055) / 1.055), 2.4))
    }

    static let light = BighelpTheme(
        canvasHex: "FFF9F5",
        surfaceHex: "FFFFFF",
        raisedSurfaceHex: "FFFFFF",
        primaryTextHex: "1C1A19",
        secondaryTextHex: "6F6762",
        tertiaryTextHex: "8F8781",
        borderHex: "E9E1DB",
        separatorHex: "EDE6E0",
        actionHex: "7B52E0",
        actionForegroundHex: "FFFFFF",
        actionGlowHex: "7B52E0",
        elevationShadowHex: "1C1A19",
        actionGlowOpacity: 0.30,
        cardShadowOpacity: 0.06,
        navigationShadowOpacity: 0.12,
        successHex: "1E7A4E",
        warningHex: "A85D00",
        dangerHex: "D33F42",
        informationHex: "1769AA",
        focusHex: "9A6BFF"
    )

    static let lightHighContrast = BighelpTheme(
        canvasHex: "FFFFFF",
        surfaceHex: "FFFFFF",
        raisedSurfaceHex: "FFFFFF",
        primaryTextHex: "000000",
        secondaryTextHex: "3F3A36",
        tertiaryTextHex: "514B47",
        borderHex: "6F6660",
        separatorHex: "8A817B",
        actionHex: "5E36C7",
        actionForegroundHex: "FFFFFF",
        actionGlowHex: "5E36C7",
        elevationShadowHex: "1B1917",
        actionGlowOpacity: 0.35,
        cardShadowOpacity: 0.12,
        navigationShadowOpacity: 0.20,
        successHex: "0E572B",
        warningHex: "7A4200",
        dangerHex: "8F1710",
        informationHex: "0D568D",
        focusHex: "5E36C7"
    )

    static let dark = BighelpTheme(
        canvasHex: "121110",
        surfaceHex: "1E1C1B",
        raisedSurfaceHex: "292624",
        primaryTextHex: "F5F2EF",
        secondaryTextHex: "A39B95",
        tertiaryTextHex: "857D77",
        borderHex: "33302E",
        separatorHex: "292624",
        actionHex: "C9B6FF",
        actionForegroundHex: "1C1A19",
        actionGlowHex: "9A6BFF",
        elevationShadowHex: "000000",
        actionGlowOpacity: 0.35,
        cardShadowOpacity: 0.20,
        navigationShadowOpacity: 0.30,
        successHex: "5BC98A",
        warningHex: "F3B24F",
        dangerHex: "FF8A7A",
        informationHex: "69B7ED",
        focusHex: "C9B6FF"
    )

    /// Light "Paper": white pages and cool neutral grays.
    static let paperLight = BighelpTheme(
        canvasHex: "FFFFFF",
        surfaceHex: "F4F4F6",
        raisedSurfaceHex: "FFFFFF",
        primaryTextHex: "1C1C1E",
        secondaryTextHex: "6C6C72",
        tertiaryTextHex: "8C8C92",
        borderHex: "E3E3E8",
        separatorHex: "EBEBEF",
        actionHex: "7B52E0",
        actionForegroundHex: "FFFFFF",
        actionGlowHex: "7B52E0",
        elevationShadowHex: "1C1C1E",
        actionGlowOpacity: 0.28,
        cardShadowOpacity: 0.06,
        navigationShadowOpacity: 0.12,
        successHex: "1E7A4E",
        warningHex: "A85D00",
        dangerHex: "D33F42",
        informationHex: "1769AA",
        focusHex: "9A6BFF"
    )

    /// Dark "Graphite": a soft, washed charcoal instead of pure black.
    static let graphiteDark = BighelpTheme(
        canvasHex: "1C1C1F",
        surfaceHex: "27272B",
        raisedSurfaceHex: "313136",
        primaryTextHex: "F4F4F6",
        secondaryTextHex: "A3A3AA",
        tertiaryTextHex: "85858C",
        borderHex: "3B3B41",
        separatorHex: "2E2E33",
        actionHex: "C9B6FF",
        actionForegroundHex: "1C1A19",
        actionGlowHex: "9A6BFF",
        elevationShadowHex: "000000",
        actionGlowOpacity: 0.35,
        cardShadowOpacity: 0.22,
        navigationShadowOpacity: 0.30,
        successHex: "5BC98A",
        warningHex: "F3B24F",
        dangerHex: "FF8A7A",
        informationHex: "69B7ED",
        focusHex: "C9B6FF"
    )

    /// Dark "Black": true black pages for OLED screens.
    static let blackDark = BighelpTheme(
        canvasHex: "000000",
        surfaceHex: "151516",
        raisedSurfaceHex: "1F1F21",
        primaryTextHex: "F5F5F7",
        secondaryTextHex: "A1A1A6",
        tertiaryTextHex: "838388",
        borderHex: "2E2E31",
        separatorHex: "1E1E20",
        actionHex: "C9B6FF",
        actionForegroundHex: "1C1A19",
        actionGlowHex: "9A6BFF",
        elevationShadowHex: "000000",
        actionGlowOpacity: 0.38,
        cardShadowOpacity: 0.30,
        navigationShadowOpacity: 0.38,
        successHex: "5BC98A",
        warningHex: "F3B24F",
        dangerHex: "FF8A7A",
        informationHex: "69B7ED",
        focusHex: "C9B6FF"
    )

    static let darkHighContrast = BighelpTheme(
        canvasHex: "000000",
        surfaceHex: "1C1A19",
        raisedSurfaceHex: "292624",
        primaryTextHex: "FFFFFF",
        secondaryTextHex: "E5DED9",
        tertiaryTextHex: "CFC6C0",
        borderHex: "B8AEA7",
        separatorHex: "817871",
        actionHex: "DCCFFF",
        actionForegroundHex: "1C1A19",
        actionGlowHex: "DCCFFF",
        elevationShadowHex: "000000",
        actionGlowOpacity: 0.40,
        cardShadowOpacity: 0.32,
        navigationShadowOpacity: 0.45,
        successHex: "82E39E",
        warningHex: "FFD06D",
        dangerHex: "FF9B93",
        informationHex: "8FD0FF",
        focusHex: "DCCFFF"
    )

    static let nousLight = BighelpTheme(
        themeID: .nous,
        typeface: .monospaced,
        typography: .nous,
        iconStyle: .technical,
        cornerScale: 0.72,
        backgroundAccentHexes: ["0071A9", "DFF5FF", "FFFFFF"],
        canvasHex: "FFFFFF",
        surfaceHex: "F7F7F7",
        raisedSurfaceHex: "FFFFFF",
        primaryTextHex: "061B27",
        secondaryTextHex: "34515F",
        tertiaryTextHex: "607C89",
        borderHex: "A8D8E8",
        separatorHex: "D2EAF3",
        actionHex: "0071A9",
        actionForegroundHex: "FFFFFF",
        actionGlowHex: "22A7E3",
        elevationShadowHex: "003B59",
        actionGlowOpacity: 0.24,
        cardShadowOpacity: 0.07,
        navigationShadowOpacity: 0.14,
        successHex: "087A67",
        warningHex: "9A5A00",
        dangerHex: "B3263D",
        informationHex: "0071A9",
        focusHex: "00A7E8"
    )

    static let nousDark = BighelpTheme(
        themeID: .nous,
        typeface: .monospaced,
        typography: .nous,
        iconStyle: .technical,
        cornerScale: 0.72,
        backgroundAccentHexes: ["00A7E8", "003E5F", "EAF9FF"],
        canvasHex: "000000",
        surfaceHex: "121212",
        raisedSurfaceHex: "1C1C1C",
        primaryTextHex: "F5FCFF",
        secondaryTextHex: "BEDCE8",
        tertiaryTextHex: "82A9B9",
        borderHex: "23576B",
        separatorHex: "173F50",
        actionHex: "35B8F2",
        actionForegroundHex: "00141F",
        actionGlowHex: "35B8F2",
        elevationShadowHex: "000000",
        actionGlowOpacity: 0.34,
        cardShadowOpacity: 0.24,
        navigationShadowOpacity: 0.34,
        successHex: "65D5B9",
        warningHex: "FFC568",
        dangerHex: "FF7C8F",
        informationHex: "70D0FA",
        focusHex: "35B8F2"
    )

    static let superpilotLight = BighelpTheme(
        themeID: .superpilot,
        typeface: .rounded,
        typography: .superpilot,
        iconStyle: .crisp,
        cornerScale: 1.24,
        backgroundAccentHexes: ["A9C9FF", "F5B6E7", "FFCCA8"],
        canvasHex: "FFFFFF",
        surfaceHex: "F7F7F7",
        raisedSurfaceHex: "FFFFFF",
        primaryTextHex: "11162B",
        secondaryTextHex: "5F6272",
        tertiaryTextHex: "888A98",
        borderHex: "E2DEE8",
        separatorHex: "ECE8F0",
        actionHex: "6552D9",
        actionForegroundHex: "FFFFFF",
        actionGlowHex: "8F7DF1",
        elevationShadowHex: "3B315E",
        actionGlowOpacity: 0.22,
        cardShadowOpacity: 0.07,
        navigationShadowOpacity: 0.12,
        successHex: "247B48",
        warningHex: "BD6A14",
        dangerHex: "C43E5C",
        informationHex: "3568D4",
        focusHex: "6552D9"
    )

    static let superpilotDark = BighelpTheme(
        themeID: .superpilot,
        typeface: .rounded,
        typography: .superpilot,
        iconStyle: .crisp,
        cornerScale: 1.24,
        backgroundAccentHexes: ["375B9D", "6F356F", "8F4B39"],
        canvasHex: "000000",
        surfaceHex: "121212",
        raisedSurfaceHex: "1C1C1C",
        primaryTextHex: "FAF8FF",
        secondaryTextHex: "CAC6D5",
        tertiaryTextHex: "95909F",
        borderHex: "3A3746",
        separatorHex: "2B2934",
        actionHex: "9B8CFF",
        actionForegroundHex: "100D20",
        actionGlowHex: "9B8CFF",
        elevationShadowHex: "000000",
        actionGlowOpacity: 0.34,
        cardShadowOpacity: 0.26,
        navigationShadowOpacity: 0.36,
        successHex: "69D590",
        warningHex: "F0B66B",
        dangerHex: "FF8098",
        informationHex: "86AFFF",
        focusHex: "B1A5FF"
    )

    static func resolve(
        themeID: BighelpThemeID = .bighelp,
        appearance: AppAppearance,
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> BighelpTheme {
        let definition = BighelpThemeRegistry.definition(for: themeID)
            ?? BighelpThemeRegistry.definition(for: .bighelp)!
        return resolve(
            definition: definition,
            appearance: appearance,
            colorScheme: colorScheme,
            contrast: contrast
        )
    }

    /// Projects a stored theme into the one live native visual language. The
    /// selected light/dark action ink is the sole palette variation; canvas,
    /// cards, labels, type, symbols, geometry, and statuses come from iOS.
    private func resolvedForLivePresentation(
        neutral: BighelpTheme,
        resolvedActionHex: String,
        actionForegroundHex foregroundOverride: String? = nil
    ) -> BighelpTheme {
        // Ember declares its action ink: white on violet by day, ink on lavender after dark.
        let resolvedActionForegroundHex = foregroundOverride ?? (themeID == .bighelp
            ? actionForegroundHex
            : Self.readableForegroundHex(against: resolvedActionHex))
        var resolved = BighelpTheme(
            themeID: themeID,
            typeface: .system,
            typography: .bighelp,
            iconStyle: .crisp,
            cornerScale: 1,
            backgroundAccentHexes: neutral.backgroundAccentHexes,
            canvasHex: neutral.canvasHex,
            surfaceHex: neutral.surfaceHex,
            raisedSurfaceHex: neutral.raisedSurfaceHex,
            primaryTextHex: neutral.primaryTextHex,
            secondaryTextHex: neutral.secondaryTextHex,
            tertiaryTextHex: neutral.tertiaryTextHex,
            borderHex: neutral.borderHex,
            separatorHex: neutral.separatorHex,
            actionHex: resolvedActionHex,
            actionForegroundHex: resolvedActionForegroundHex,
            actionGlowHex: resolvedActionHex,
            elevationShadowHex: neutral.elevationShadowHex,
            actionGlowOpacity: neutral.actionGlowOpacity,
            cardShadowOpacity: neutral.cardShadowOpacity,
            navigationShadowOpacity: neutral.navigationShadowOpacity,
            successHex: neutral.successHex,
            warningHex: neutral.warningHex,
            dangerHex: neutral.dangerHex,
            informationHex: neutral.informationHex,
            focusHex: resolvedActionHex
        )
        resolved.resolvesLiveSemantics = true
        return resolved
    }

    /// Preserve the authored hue while keeping custom action/link ink visible
    /// on the native canvas, cards and incoming bubbles in either appearance,
    /// and on the chosen page color (Cream/Paper, Graphite/Black).
    private static func readableAccentHex(_ hex: String, isDark: Bool, increasedContrast: Bool,
                                          on neutral: BighelpTheme) -> String {
        let value = UInt64(hex, radix: 16) ?? 0
        let channels = [CGFloat((value >> 16) & 0xFF) / 255,
                        CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255]
        func luminance(_ components: [CGFloat]) -> CGFloat {
            0.2126 * linearChannel(components[0]) + 0.7152 * linearChannel(components[1])
                + 0.0722 * linearChannel(components[2])
        }
        let backgrounds = [UIUserInterfaceLevel.base, .elevated].flatMap { level in
            let traits = UITraitCollection {
                $0.userInterfaceStyle = isDark ? .dark : .light
                $0.accessibilityContrast = increasedContrast ? .high : .normal
                $0.userInterfaceLevel = level
            }
            return [UIColor.systemBackground, .secondarySystemBackground, .systemGray5].map { color in
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
                color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: nil)
                return luminance([red, green, blue])
            }
        } + [neutral.canvasHex, neutral.surfaceHex, neutral.raisedSurfaceHex].map { surface in
            let value = UInt64(surface, radix: 16) ?? 0
            return luminance([CGFloat((value >> 16) & 0xFF) / 255,
                              CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255])
        }
        func leastContrast(_ components: [CGFloat]) -> CGFloat {
            let ink = luminance(components)
            return backgrounds.map { (max(ink, $0) + 0.05) / (min(ink, $0) + 0.05) }.min() ?? 1
        }
        guard leastContrast(channels) < 4.5 else { return hex }
        let target: CGFloat = isDark ? 1 : 0
        func mixed(_ amount: CGFloat) -> [CGFloat] {
            channels.map { (($0 + (target - $0) * amount) * 255).rounded() / 255 }
        }
        var lower: CGFloat = 0, upper: CGFloat = 1
        for _ in 0..<12 {
            let midpoint = (lower + upper) / 2
            if leastContrast(mixed(midpoint)) >= 4.6 { upper = midpoint } else { lower = midpoint }
        }
        let result = mixed(upper)
        return String(format: "%02X%02X%02X", Int((result[0] * 255).rounded()),
                      Int((result[1] * 255).rounded()), Int((result[2] * 255).rounded()))
    }

    private static func readableForegroundHex(against backgroundHex: String) -> String {
        let value = UInt64(backgroundHex, radix: 16) ?? 0
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        let luminance = 0.2126 * linearChannel(red)
            + 0.7152 * linearChannel(green)
            + 0.0722 * linearChannel(blue)
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return whiteContrast >= blackContrast ? "FFFFFF" : "000000"
    }
}

struct BighelpThemeDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: BighelpThemeID
    let name: String
    let summary: String
    let light: BighelpTheme
    let lightHighContrast: BighelpTheme
    let dark: BighelpTheme
    let darkHighContrast: BighelpTheme
}

enum BighelpThemeRegistry {
    static let builtIns: [BighelpThemeDefinition] = [
        BighelpThemeDefinition(
            id: .bighelp,
            name: "Ember",
            summary: "Warm cream by day, after dark at night, with lavender actions.",
            light: .light,
            lightHighContrast: .lightHighContrast,
            dark: .dark,
            darkHighContrast: .darkHighContrast
        ),
        BighelpThemeDefinition(
            id: .nous,
            name: "Nous",
            summary: "Native neutrals with the Nous blue action accent.",
            light: .nousLight,
            lightHighContrast: .nousLight,
            dark: .nousDark,
            darkHighContrast: .nousDark
        ),
        BighelpThemeDefinition(
            id: .superpilot,
            name: "Superpilot",
            summary: "Native neutrals with the Superpilot violet action accent.",
            light: .superpilotLight,
            lightHighContrast: .superpilotLight,
            dark: .superpilotDark,
            darkHighContrast: .superpilotDark
        ),
    ]

    static func definition(for id: BighelpThemeID) -> BighelpThemeDefinition? {
        builtIns.first { $0.id == id }
    }

    static func contains(_ id: BighelpThemeID) -> Bool {
        definition(for: id) != nil
    }
}

struct BighelpAppearanceContext: Equatable, Sendable {
    let appearance: AppAppearance
    let themeID: BighelpThemeID
    let customTheme: CustomTheme?
    let customLightLogoURL: URL?
    let customDarkLogoURL: URL?
    var lightBackground: BighelpLightBackground = .cream
    var darkBackground: BighelpDarkBackground = .graphite
    /// Overrides the theme's accent for bubbles and buttons.
    var bubbleColor: BighelpBubbleColor?

    var customLogoURL: URL? { customLightLogoURL ?? customDarkLogoURL }

    init(
        appearance: AppAppearance,
        themeID: BighelpThemeID,
        customTheme: CustomTheme? = nil,
        customLogoURL: URL? = nil,
        customLightLogoURL: URL? = nil,
        customDarkLogoURL: URL? = nil,
        lightBackground: BighelpLightBackground = .cream,
        darkBackground: BighelpDarkBackground = .graphite,
        bubbleColor: BighelpBubbleColor? = nil
    ) {
        self.appearance = appearance
        self.themeID = themeID
        self.customTheme = customTheme
        self.customLightLogoURL = customLightLogoURL ?? customLogoURL
        self.customDarkLogoURL = customDarkLogoURL ?? customLogoURL
        self.lightBackground = lightBackground
        self.darkBackground = darkBackground
        self.bubbleColor = bubbleColor
    }
}

extension BighelpTheme {
    static func resolve(
        appearance context: BighelpAppearanceContext,
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> BighelpTheme {
        let definition: BighelpThemeDefinition
        if let customTheme = context.customTheme, customTheme.themeID == context.themeID {
            definition = customTheme.definition
        } else {
            definition = BighelpThemeRegistry.definition(for: context.themeID)
                ?? BighelpThemeRegistry.definition(for: .bighelp)!
        }
        let dark = context.appearance == .dark || (context.appearance == .system && colorScheme == .dark)
        let selected = switch (dark, contrast) {
        case (false, .standard): definition.light
        case (false, .increased): definition.lightHighContrast
        case (true, .standard): definition.dark
        case (true, .increased): definition.darkHighContrast
        @unknown default: dark ? definition.dark : definition.light
        }
        return selected.resolvedForLivePresentation(
            colorScheme: dark ? .dark : .light, contrast: contrast,
            lightBackground: context.lightBackground, darkBackground: context.darkBackground,
            bubbleColor: context.bubbleColor)
    }

    static func resolve(
        definition: BighelpThemeDefinition,
        appearance: AppAppearance,
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> BighelpTheme {
        let dark = appearance == .dark || (appearance == .system && colorScheme == .dark)
        let selected = switch (dark, contrast) {
        case (false, .standard): definition.light
        case (false, .increased): definition.lightHighContrast
        case (true, .standard): definition.dark
        case (true, .increased): definition.darkHighContrast
        @unknown default: dark ? definition.dark : definition.light
        }
        return selected.resolvedForLivePresentation(colorScheme: dark ? .dark : .light, contrast: contrast)
    }

    /// Used by live settings samples after selecting an explicit document palette.
    /// The stored document itself is never rewritten.
    func resolvedForLivePresentation(
        colorScheme: ColorScheme, contrast: ColorSchemeContrast,
        lightBackground: BighelpLightBackground = .cream, darkBackground: BighelpDarkBackground = .graphite,
        bubbleColor: BighelpBubbleColor? = nil
    ) -> BighelpTheme {
        let dark = colorScheme == .dark
        let neutralDefinition = BighelpThemeRegistry.definition(for: .bighelp)!
        let neutral = switch (dark, contrast) {
        case (false, .standard): lightBackground.neutral
        case (false, .increased): neutralDefinition.lightHighContrast
        case (true, .standard): darkBackground.neutral
        case (true, .increased): neutralDefinition.darkHighContrast
        @unknown default: dark ? darkBackground.neutral : lightBackground.neutral
        }
        let increased = contrast == .increased
        if let bubbleHex = bubbleColor?.hex {
            let action = Self.readableAccentHex(bubbleHex, isDark: dark, increasedContrast: increased, on: neutral)
            return resolvedForLivePresentation(neutral: neutral, resolvedActionHex: action,
                                               actionForegroundHex: Self.readableForegroundHex(against: action))
        }
        if bubbleColor == .lavender {
            // bighelp's own lavender: violet by day, lighter after dark.
            let ember = increased ? (dark ? BighelpTheme.darkHighContrast : BighelpTheme.lightHighContrast) : neutral
            return resolvedForLivePresentation(neutral: neutral, resolvedActionHex: ember.actionHex,
                                               actionForegroundHex: ember.actionForegroundHex)
        }
        return resolvedForLivePresentation(
            neutral: neutral,
            resolvedActionHex: themeID == .bighelp
                ? actionHex
                : Self.readableAccentHex(actionHex, isDark: dark, increasedContrast: increased, on: neutral)
        )
    }
}

extension EnvironmentValues {
    /// Shared opt-in contract for signed-in and signed-out presentation.
    @Entry var bighelpUIV2Enabled: Bool = false
    @Entry var bighelpUIV3Enabled: Bool = false

    @Entry var appAppearance = BighelpAppearanceContext(
        appearance: .system,
        themeID: .bighelp
    )
}

enum BighelpFontRole: Sendable {
    case display
    case screenTitle
    case sectionTitle
    case body
    case label
    case metadata
    case code
    case brand

    fileprivate var textStyle: Font.TextStyle {
        switch self {
        case .display: .largeTitle
        case .screenTitle: .title2
        case .sectionTitle, .brand: .title3
        case .body: .body
        case .label: .subheadline
        case .metadata: .caption
        case .code: .callout
        }
    }

    fileprivate var size: CGFloat {
        switch self {
        case .display: 34
        case .screenTitle: 22
        case .sectionTitle, .brand: 20
        case .body: 17
        case .label: 15
        case .metadata: 12
        case .code: 16
        }
    }

    fileprivate var weight: Font.Weight {
        switch self {
        case .display, .screenTitle: .bold
        case .sectionTitle, .label, .brand: .semibold
        case .body, .metadata, .code: .regular
        }
    }

    fileprivate var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .display: .largeTitle
        case .screenTitle: .title2
        case .sectionTitle, .brand: .title3
        case .body: .body
        case .label: .subheadline
        case .metadata: .caption1
        case .code: .callout
        }
    }

    fileprivate var uiWeight: UIFont.Weight {
        switch self {
        case .display, .screenTitle: .bold
        case .sectionTitle, .label, .brand: .semibold
        case .body, .metadata, .code: .regular
        }
    }

    fileprivate var isReflectiveHeading: Bool {
        switch self {
        case .display, .screenTitle, .sectionTitle:
            true
        case .body, .label, .metadata, .code, .brand:
            false
        }
    }
}

extension BighelpTheme {
    func font(
        _ role: BighelpFontRole,
        weight overrideWeight: Font.Weight? = nil,
        italic: Bool = false
    ) -> Font {
        let weight = overrideWeight ?? role.weight
        let candidates: [String]
        switch role {
        case .display, .screenTitle, .sectionTitle:
            candidates = typography.displayFontNames
        case .label:
            candidates = typography.emphasizedBodyFontNames
        case .body, .metadata:
            candidates = usesEmphasizedFace(weight)
                ? typography.emphasizedBodyFontNames
                : typography.bodyFontNames
        case .code:
            candidates = typography.codeFontNames
        case .brand:
            candidates = typography.brandFontNames
        }

        let resolved: Font
        if let name = BighelpFontCatalog.resolveFontName(candidates: candidates, in: .main) {
            resolved = Font.custom(name, size: role.size, relativeTo: role.textStyle)
                .weight(weight)
        } else {
            let design: Font.Design
            if role == .code {
                design = .monospaced
            } else {
                design = switch typeface {
                case .system: .default
                case .monospaced: .monospaced
                case .rounded: .rounded
                case .serif: .serif
                }
            }
            resolved = .system(role.textStyle, design: design, weight: weight)
        }
        return italic ? resolved.italic() : resolved
    }

    func uiFont(
        _ role: BighelpFontRole,
        compatibleWith traitCollection: UITraitCollection? = nil
    ) -> UIFont {
        let candidates = fontCandidates(
            for: role,
            usesEmphasizedFace: role.uiWeight >= .semibold
        )
        let metrics = UIFontMetrics(forTextStyle: role.uiTextStyle)

        if let name = BighelpFontCatalog.resolveFontName(candidates: candidates, in: .main),
           let font = UIFont(name: name, size: role.size) {
            return metrics.scaledFont(for: font, compatibleWith: traitCollection)
        }

        let baseFont = UIFont.systemFont(ofSize: role.size, weight: role.uiWeight)
        let design: UIFontDescriptor.SystemDesign? = if role == .code {
            .monospaced
        } else {
            switch typeface {
            case .system: nil
            case .monospaced: .monospaced
            case .rounded: .rounded
            case .serif: .serif
            }
        }
        let designedFont: UIFont
        if let design,
           let descriptor = baseFont.fontDescriptor.withDesign(design) {
            designedFont = UIFont(descriptor: descriptor, size: role.size)
        } else {
            designedFont = baseFont
        }
        return metrics.scaledFont(for: designedFont, compatibleWith: traitCollection)
    }

    private func fontCandidates(
        for role: BighelpFontRole,
        usesEmphasizedFace: Bool
    ) -> [String] {
        switch role {
        case .display, .screenTitle, .sectionTitle:
            typography.displayFontNames
        case .label:
            typography.emphasizedBodyFontNames
        case .body, .metadata:
            usesEmphasizedFace
                ? typography.emphasizedBodyFontNames
                : typography.bodyFontNames
        case .code:
            typography.codeFontNames
        case .brand:
            typography.brandFontNames
        }
    }

    private func usesEmphasizedFace(_ weight: Font.Weight) -> Bool {
        weight == .medium
            || weight == .semibold
            || weight == .bold
            || weight == .heavy
            || weight == .black
    }
}

private struct BighelpFontModifier: ViewModifier {
    let role: BighelpFontRole
    let weight: Font.Weight?
    let italic: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appAppearance) private var appAppearance

    func body(content: Content) -> some View {
        let theme = BighelpTheme.resolve(
            appearance: appAppearance,
            colorScheme: colorScheme,
            contrast: colorSchemeContrast
        )
        content
            .font(theme.font(role, weight: weight, italic: italic))
            .reflectiveVisionMaterial(isEligible: role.isReflectiveHeading)
    }
}

extension View {
    nonisolated func bighelpFont(
        _ role: BighelpFontRole,
        weight: Font.Weight? = nil,
        italic: Bool = false
    ) -> some View {
        modifier(BighelpFontModifier(role: role, weight: weight, italic: italic))
    }
}

private struct BighelpThemePresentationModifier: ViewModifier {
    let theme: BighelpTheme

    // Keep the content at one structural identity while a theme changes.
    // Branching around content destroys in-progress onboarding and form state.
    func body(content: Content) -> some View {
        content
            .fontDesign(fontDesign)
            .symbolRenderingMode(theme.iconStyle == .soft ? .hierarchical : .monochrome)
            .symbolVariant(theme.iconStyle == .soft ? .fill : .none)
    }

    private var fontDesign: Font.Design {
        switch theme.typeface {
        case .system: .default
        case .monospaced: .monospaced
        case .rounded: .rounded
        case .serif: .serif
        }
    }
}

extension View {
    func bighelpThemePresentation(_ theme: BighelpTheme) -> some View {
        font(theme.font(.body))
            .modifier(BighelpThemePresentationModifier(theme: theme))
            .modifier(BighelpV2DefaultsModifier(theme: theme))
    }
}

struct BighelpThemeCanvas: View {
    let theme: BighelpTheme

    var body: some View {
        theme.canvas
            .accessibilityHidden(true)
    }
}

// Some system designs (including SF Rounded) have no italic face. Preserve
// Markdown emphasis with the matching system italic face when UIKit cannot
// provide those traits in the chosen family.
extension UIFont {
    func bighelpApplyingTraits(_ requested: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let traits = fontDescriptor.symbolicTraits.union(requested)
        let candidate = fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: pointSize) } ?? self
        guard requested.contains(.traitItalic), !candidate.fontDescriptor.symbolicTraits.contains(.traitItalic) else {
            return candidate
        }
        let base = traits.contains(.traitMonoSpace)
            ? UIFont.monospacedSystemFont(ofSize: pointSize, weight: traits.contains(.traitBold) ? .bold : .regular)
            : UIFont.systemFont(ofSize: pointSize, weight: traits.contains(.traitBold) ? .bold : .regular)
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return candidate }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
