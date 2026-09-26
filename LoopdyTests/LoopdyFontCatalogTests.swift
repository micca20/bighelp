import Foundation
import Testing
import UIKit
@testable import Loopdy

@MainActor
struct LoopdyFontCatalogTests {
    @Test func guaranteedFallbackFontsExistInTheAppBundleAndResolve() throws {
        for font in LoopdyFontCatalog.guaranteedFallbacks {
            #expect(Bundle.main.url(forResource: font.resourceName,
                                    withExtension: font.extension) != nil)
            #expect(UIFont(name: font.postScriptName, size: 17) != nil)
        }
    }

    @Test func requestedThemeFontsNeverMasqueradeAsLoadedFallbacks() {
        #expect(LoopdyFontCatalog.resolveFontName(
            candidates: ["Missing Requested Face", "Noto Sans"],
            availablePostScriptNames: ["NotoSans-Regular"]
        ) == "NotoSans-Regular")
    }

    @Test func mainBundleRegistrationValidationIsCached() {
        LoopdyFontCatalog.resetMainBundleRegistrationCacheForTesting()

        let first = LoopdyFontCatalog.registeredPostScriptNames(in: .main)
        let second = LoopdyFontCatalog.registeredPostScriptNames(in: .main)

        #expect(second == first)
        #expect(LoopdyFontCatalog.mainBundleValidationCountForTesting == 1)
    }

    @Test func bundleBackedResolutionUsesRegisteredNotoPostScriptNames() {
        let registered = LoopdyFontCatalog.registeredPostScriptNames(in: .main)

        #expect(registered == ["NotoSans-Regular", "NotoSans-SemiBold"])
        #expect(LoopdyFontCatalog.resolveFontName(
            candidates: ["Missing Requested Face", "Noto Sans"],
            in: .main
        ) == "NotoSans-Regular")
        #expect(LoopdyFontCatalog.resolveFontName(
            candidates: ["Noto Sans SemiBold"],
            in: .main
        ) == "NotoSans-SemiBold")
    }

    @Test func defaultThemeUsesNativeSystemTypeAtEveryReadingSize() {
        for theme in [LoopdyTheme.light, .dark, .lightHighContrast, .darkHighContrast] {
            #expect(theme.typeface == .system)
            for (role, weight) in [(LoopdyFontRole.body, UIFont.Weight.regular), (.label, .semibold), (.screenTitle, .bold), (.metadata, .regular)] {
                let actual = theme.uiFont(role)
                let expected = UIFont.systemFont(ofSize: actual.pointSize, weight: weight)
                #expect(actual.fontName == expected.fontName)
            }
            #expect(theme.uiFont(.code).fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        }
    }

    @Test func nativeDefaultRetainsThemeOverridesAndDynamicType() {
        #expect(LoopdyTheme.nousLight.typeface == .monospaced)
        #expect(LoopdyTheme.superpilotLight.typography == .superpilot)
        let normal = UITraitCollection(preferredContentSizeCategory: .large)
        let large = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        #expect(LoopdyTheme.light.uiFont(.body, compatibleWith: large).pointSize
                > LoopdyTheme.light.uiFont(.body, compatibleWith: normal).pointSize)
    }
}
