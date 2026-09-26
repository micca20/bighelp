import SwiftUI
import UIKit
import XCTest
@testable import Loopdy

/// Live app presentation is independent of the retained theme-document palette.
/// These checks resolve real UIKit colors; stored hex equality alone is not proof.
@MainActor
final class IMessageThemeContractTests: XCTestCase {
    private let roles: [(String, KeyPath<LoopdyTheme, Color>)] = [
        ("canvas", \.canvas), ("surface", \.surface), ("raisedSurface", \.raisedSurface),
        ("primaryText", \.primaryText), ("secondaryText", \.secondaryText),
        ("tertiaryText", \.tertiaryText), ("border", \.border), ("separator", \.separator),
        ("success", \.success), ("warning", \.warning), ("danger", \.danger),
        ("cardBackground", \.cardBackground), ("navigationBackground", \.navigationBackground)
    ]

    func testOutgoingMessageUsesWhiteWithoutChangingActionInk() throws {
        let customs = try ["FFFFFF", "FFCC00", "0088FF", "8040C0"].map { try makeCustom(accent: $0) }
        let contexts = LoopdyThemeRegistry.builtIns.map {
            LoopdyAppearanceContext(appearance: .system, themeID: $0.id)
        } + customs.map { LoopdyAppearanceContext(appearance: .system, themeID: $0.themeID, customTheme: $0) }
        for dark in [false, true] {
            let nativeTraits = traits(dark: dark)
            for context in contexts {
                let theme = resolve(context, dark, false)
                assertColor(theme.outgoingMessageForeground, equals: .white, traits: nativeTraits, "Outgoing message ink")
                let background = luminance(components(theme.outgoingMessageBackground, traits: nativeTraits))
                let white = luminance(components(.white, traits: nativeTraits))
                XCTAssertGreaterThanOrEqual((white + 0.05) / (background + 0.05), 4.5)
            }
        }
    }
    func testEveryLiveThemeUsesTheSameAdaptiveNeutralRoles() throws {
        let custom = try makeCustom()
        let contexts = LoopdyThemeRegistry.builtIns.map {
            LoopdyAppearanceContext(appearance: .system, themeID: $0.id)
        } + [LoopdyAppearanceContext(appearance: .system, themeID: custom.themeID, customTheme: custom)]
        for dark in [false, true] {
            for increased in [false, true] {
                let traits = traits(dark: dark, increased: increased)
                let reference = resolve(LoopdyAppearanceContext(appearance: .system, themeID: .loopdy), dark, increased)
                for context in contexts {
                    let theme = resolve(context, dark, increased)
                    for (name, path) in roles {
                        assertColor(theme[keyPath: path], equals: reference[keyPath: path], traits: traits,
                                    "\(context.themeID.rawValue) \(name), dark=\(dark), increased=\(increased)")
                    }
                }
            }
        }
    }

    func testLiveTypeAndControlGeometryDoNotChangeWithTheme() throws {
        let custom = try makeCustom()
        for dark in [false, true] {
            let reference = resolve(.init(appearance: .system, themeID: .loopdy), dark, false)
            let contexts = LoopdyThemeRegistry.builtIns.map {
                LoopdyAppearanceContext(appearance: .system, themeID: $0.id)
            } + [.init(appearance: .system, themeID: custom.themeID, customTheme: custom)]
            for context in contexts {
                let theme = resolve(context, dark, false)
                XCTAssertEqual(theme.cornerScale, reference.cornerScale)
                XCTAssertEqual(theme.iconStyle, reference.iconStyle)
                for role: LoopdyFontRole in [.display, .screenTitle, .sectionTitle, .body, .label, .metadata, .code] {
                    let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
                    let font = theme.uiFont(role, compatibleWith: traits)
                    let expected = reference.uiFont(role, compatibleWith: traits)
                    XCTAssertEqual(font.fontName, expected.fontName)
                    XCTAssertEqual(font.pointSize, expected.pointSize, accuracy: 0.01)
                }
            }
        }
    }

    func testOutgoingForegroundHasReadableContrastAgainstActualAccent() throws {
        let customs = try ["FFFFFF", "000000", "FFCC00", "0088FF", "8040C0", "FF5A4F"].map { try makeCustom(accent: $0) }
        let contexts = LoopdyThemeRegistry.builtIns.map {
            LoopdyAppearanceContext(appearance: .system, themeID: $0.id)
        } + customs.map { LoopdyAppearanceContext(appearance: .system, themeID: $0.themeID, customTheme: $0) }
        for dark in [false, true] {
            for increased in [false, true] {
                let traits = traits(dark: dark, increased: increased)
                for context in contexts {
                    let theme = resolve(context, dark, increased)
                    let background = luminance(components(theme.action, traits: traits))
                    let foreground = luminance(components(theme.actionForeground, traits: traits))
                    let ratio = (max(background, foreground) + 0.05) / (min(background, foreground) + 0.05)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(context.themeID.rawValue), dark=\(dark), increased=\(increased)")
                }
            }
        }
    }

    func testCompanionHexMatchesTheActualNativeActionForEveryAppearance() {
        for dark in [false, true] {
            for increased in [false, true] {
                let theme = resolve(.init(appearance: .system, themeID: .loopdy), dark, increased)
                let traits = traits(dark: dark, increased: increased)
                let actual = components(theme.action, traits: traits)
                let encoded = components(Color(hex: theme.actionHex), traits: traits)
                for (component, hexComponent) in zip(actual, encoded) {
                    XCTAssertEqual(component, hexComponent, accuracy: 1.0 / 255.0,
                                   "Native action and companion hex disagree, dark=\(dark), increased=\(increased)")
                }
            }
        }
    }

    func testSelectingCustomAccentActuallyChangesLiveActions() throws {
        let first = try makeCustom(accent: "8040C0")
        let second = try makeCustom(accent: "207040")
        for dark in [false, true] {
            let a = resolve(.init(appearance: .system, themeID: first.themeID, customTheme: first), dark, false)
            let b = resolve(.init(appearance: .system, themeID: second.themeID, customTheme: second), dark, false)
            XCTAssertNotEqual(components(a.action, traits: traits(dark: dark)), components(b.action, traits: traits(dark: dark)))
        }
    }

    func testResolvingLivePresentationDoesNotRewriteSavedThemeDocuments() throws {
        let custom = try makeCustom()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(custom)
        let definitionsBefore = try encoder.encode(LoopdyThemeRegistry.builtIns)
        for dark in [false, true] {
            _ = resolve(.init(appearance: .system, themeID: custom.themeID, customTheme: custom), dark, true)
        }
        XCTAssertEqual(try encoder.encode(custom), before)
        XCTAssertEqual(try encoder.encode(LoopdyThemeRegistry.builtIns), definitionsBefore)
        XCTAssertEqual(try JSONDecoder().decode(CustomTheme.self, from: before), custom)
        XCTAssertEqual(custom.light.backgroundHex, "FFF0DD")
        XCTAssertEqual(custom.dark.backgroundHex, "201020")
        XCTAssertEqual(custom.font, .rounded)
    }

    func testExplicitThemeDocumentPreviewRetainsItsStoredPalette() throws {
        let custom = try makeCustom()
        for dark in [false, true] {
            let palette = dark ? custom.dark : custom.light
            let preview = try CustomTheme.previewPalette(palette: palette, accentHex: custom.accentHex, font: custom.font, isDark: dark)
            assertColor(preview.canvas, equals: Color(hex: palette.backgroundHex), traits: traits(dark: dark), "Document canvas")
            assertColor(preview.primaryText, equals: Color(hex: palette.primaryTextHex), traits: traits(dark: dark), "Document text")
        }
    }

    func testPartnerAndCustomActionInkStaysReadableOnTheNeutralCanvas() throws {
        let customs = try ["FFFFFF", "000000", "FFCC00", "0088FF"].map { try makeCustom(accent: $0) }
        let definitions = LoopdyThemeRegistry.builtIns.filter { $0.id != .loopdy } + customs.map(\.definition)
        for definition in definitions {
            for dark in [false, true] {
                for increased in [false, true] {
                    let theme = LoopdyTheme.resolve(definition: definition, appearance: .system,
                                                   colorScheme: dark ? .dark : .light,
                                                   contrast: increased ? .increased : .standard)
                    let baseTraits = traits(dark: dark, increased: increased)
                    for traits in [baseTraits, UITraitCollection(traitsFrom: [baseTraits,
                                      UITraitCollection(userInterfaceLevel: .elevated)])] {
                        let ink = luminance(components(theme.action, traits: traits))
                        for surface in [theme.canvas, theme.surface, theme.raisedSurface, Color(uiColor: .systemGray5)] {
                            let background = luminance(components(surface, traits: traits))
                            let ratio = (max(ink, background) + 0.05) / (min(ink, background) + 0.05)
                            XCTAssertGreaterThanOrEqual(ratio, 4.5,
                                "Links/actions cannot disappear against native surfaces: \(definition.id.rawValue), dark=\(dark)")
                        }
                    }
                }
            }
        }
    }

    func testLivePreviewProjectionMatchesTheAppAndLeavesRawPalettesIntact() throws {
        let custom = try makeCustom()
        let definitions = LoopdyThemeRegistry.builtIns + [custom.definition]
        for definition in definitions {
            for dark in [false, true] {
                for increased in [false, true] {
                    let palette = dark
                        ? (increased ? definition.darkHighContrast : definition.dark)
                        : (increased ? definition.lightHighContrast : definition.light)
                    let sample = palette.resolvedForLivePresentation(
                        colorScheme: dark ? .dark : .light, contrast: increased ? .increased : .standard)
                    let app = LoopdyTheme.resolve(definition: definition, appearance: .system,
                                                  colorScheme: dark ? .dark : .light,
                                                  contrast: increased ? .increased : .standard)
                    let traits = traits(dark: dark, increased: increased)
                    for (_, role) in roles { assertColor(sample[keyPath: role], equals: app[keyPath: role], traits: traits, "Preview role") }
                    assertColor(sample.action, equals: app.action, traits: traits, "Preview accent")
                    assertColor(sample.actionForeground, equals: app.actionForeground, traits: traits, "Preview foreground")
                    XCTAssertEqual(sample.typeface, .system)
                }
            }
        }
        XCTAssertEqual(custom.light.backgroundHex, "FFF0DD")
        XCTAssertEqual(custom.font, .rounded)
    }

    private func makeCustom(accent: String = "8040C0") throws -> CustomTheme {
        try CustomTheme(name: "Preserved amber and plum", font: .rounded, accentHex: accent,
                        light: .init(backgroundHex: "FFF0DD", primaryTextHex: "101010", secondaryTextHex: "303030", tertiaryTextHex: "404040"),
                        dark: .init(backgroundHex: "201020", primaryTextHex: "FFFFFF", secondaryTextHex: "EEEEEE", tertiaryTextHex: "DDDDDD"))
    }

    private func resolve(_ context: LoopdyAppearanceContext, _ dark: Bool, _ increased: Bool) -> LoopdyTheme {
        LoopdyTheme.resolve(appearance: context, colorScheme: dark ? .dark : .light, contrast: increased ? .increased : .standard)
    }

    private func traits(dark: Bool, increased: Bool = false) -> UITraitCollection {
        UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
                                      UITraitCollection(accessibilityContrast: increased ? .high : .normal)])
    }

    private func components(_ color: Color, traits: UITraitCollection) -> [CGFloat] {
        var result: [CGFloat] = []
        traits.performAsCurrent {
            let resolved = UIColor(color).resolvedColor(with: traits)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            result = [red, green, blue, alpha]
        }
        return result
    }

    private func assertColor(_ color: Color, equals expected: Color, traits: UITraitCollection, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let actual = components(color, traits: traits)
        let reference = components(expected, traits: traits)
        for (a, b) in zip(actual, reference) {
            XCTAssertEqual(a, b, accuracy: 0.0001, message, file: file, line: line)
        }
    }

    private func luminance(_ color: [CGFloat]) -> Double {
        let values = color.prefix(3).map { value -> Double in
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }
}
