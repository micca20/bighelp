import SwiftUI
import UIKit
import XCTest
@testable import Bighelp

/// One live look: only the bubble color changes the action ink.
/// These checks resolve real UIKit colors; stored hex equality alone is not proof.
@MainActor
final class IMessageThemeContractTests: XCTestCase {
    private let roles: [(String, KeyPath<BighelpTheme, Color>)] = [
        ("canvas", \.canvas), ("surface", \.surface), ("raisedSurface", \.raisedSurface),
        ("primaryText", \.primaryText), ("secondaryText", \.secondaryText),
        ("tertiaryText", \.tertiaryText), ("border", \.border), ("separator", \.separator),
        ("success", \.success), ("warning", \.warning), ("danger", \.danger),
        ("cardBackground", \.cardBackground), ("navigationBackground", \.navigationBackground)
    ]

    /// Every bubble color, plus no choice (bighelp's own lavender).
    private var contexts: [BighelpAppearanceContext] {
        [BighelpAppearanceContext(appearance: .system)]
            + BighelpBubbleColor.allCases.map { BighelpAppearanceContext(appearance: .system, bubbleColor: $0) }
    }

    func testOutgoingMessageUsesWhiteWithoutChangingActionInk() throws {
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

    func testEveryBubbleColorKeepsTheSameAdaptiveNeutralRoles() throws {
        for dark in [false, true] {
            for increased in [false, true] {
                let traits = traits(dark: dark, increased: increased)
                let reference = resolve(BighelpAppearanceContext(appearance: .system), dark, increased)
                for context in contexts {
                    let theme = resolve(context, dark, increased)
                    for (name, path) in roles {
                        assertColor(theme[keyPath: path], equals: reference[keyPath: path], traits: traits,
                                    "\(context.bubbleColor?.rawValue ?? "default") \(name), dark=\(dark), increased=\(increased)")
                    }
                }
            }
        }
    }

    func testLiveTypeAndControlGeometryDoNotChangeWithBubbleColor() throws {
        for dark in [false, true] {
            let reference = resolve(.init(appearance: .system), dark, false)
            for context in contexts {
                let theme = resolve(context, dark, false)
                XCTAssertEqual(theme.cornerScale, reference.cornerScale)
                XCTAssertEqual(theme.iconStyle, reference.iconStyle)
                for role: BighelpFontRole in [.display, .screenTitle, .sectionTitle, .body, .label, .metadata, .code] {
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
        for dark in [false, true] {
            for increased in [false, true] {
                let traits = traits(dark: dark, increased: increased)
                for context in contexts {
                    let theme = resolve(context, dark, increased)
                    let background = luminance(components(theme.action, traits: traits))
                    let foreground = luminance(components(theme.actionForeground, traits: traits))
                    let ratio = (max(background, foreground) + 0.05) / (min(background, foreground) + 0.05)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5,
                                                "\(context.bubbleColor?.rawValue ?? "default"), dark=\(dark), increased=\(increased)")
                }
            }
        }
    }

    func testCompanionHexMatchesTheActualNativeActionForEveryAppearance() {
        for dark in [false, true] {
            for increased in [false, true] {
                let theme = resolve(.init(appearance: .system), dark, increased)
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

    func testPickingABubbleColorActuallyChangesLiveActions() throws {
        for dark in [false, true] {
            let a = resolve(.init(appearance: .system, bubbleColor: .ocean), dark, false)
            let b = resolve(.init(appearance: .system, bubbleColor: .mint), dark, false)
            XCTAssertNotEqual(components(a.action, traits: traits(dark: dark)), components(b.action, traits: traits(dark: dark)))
        }
    }

    /// bighelp's own lavender declares its ink; every other bubble color is darkened until readable.
    func testEveryBubbleColorStaysReadableOnTheNeutralCanvas() throws {
        for context in contexts where context.bubbleColor != nil && context.bubbleColor != .lavender {
            for dark in [false, true] {
                for increased in [false, true] {
                    let theme = resolve(context, dark, increased)
                    let baseTraits = traits(dark: dark, increased: increased)
                    for traits in [baseTraits, UITraitCollection(traitsFrom: [baseTraits,
                                      UITraitCollection(userInterfaceLevel: .elevated)])] {
                        let ink = luminance(components(theme.action, traits: traits))
                        for surface in [theme.canvas, theme.surface, theme.raisedSurface, Color(uiColor: .systemGray5)] {
                            let background = luminance(components(surface, traits: traits))
                            let ratio = (max(ink, background) + 0.05) / (min(ink, background) + 0.05)
                            XCTAssertGreaterThanOrEqual(ratio, 4.5,
                                "Links/actions cannot disappear against native surfaces: "
                                + "\(context.bubbleColor?.rawValue ?? "default"), dark=\(dark)")
                        }
                    }
                }
            }
        }
    }

    func testLivePreviewProjectionMatchesTheApp() throws {
        let definition = BighelpThemeRegistry.ember
        for dark in [false, true] {
            for increased in [false, true] {
                let palette = dark
                    ? (increased ? definition.darkHighContrast : definition.dark)
                    : (increased ? definition.lightHighContrast : definition.light)
                let sample = palette.resolvedForLivePresentation(
                    colorScheme: dark ? .dark : .light, contrast: increased ? .increased : .standard)
                let app = BighelpTheme.resolve(definition: definition, appearance: .system,
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

    private func resolve(_ context: BighelpAppearanceContext, _ dark: Bool, _ increased: Bool) -> BighelpTheme {
        BighelpTheme.resolve(appearance: context, colorScheme: dark ? .dark : .light, contrast: increased ? .increased : .standard)
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
