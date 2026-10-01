import Foundation
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct BighelpFontCatalogTests {
    @Test func guaranteedFallbackFontsExistInTheAppBundleAndResolve() throws {
        for font in BighelpFontCatalog.guaranteedFallbacks {
            #expect(Bundle.main.url(forResource: font.resourceName,
                                    withExtension: font.extension) != nil)
            #expect(UIFont(name: font.postScriptName, size: 17) != nil)
        }
    }

    @Test func requestedThemeFontsNeverMasqueradeAsLoadedFallbacks() {
        #expect(BighelpFontCatalog.resolveFontName(
            candidates: ["Missing Requested Face", "Noto Sans"],
            availablePostScriptNames: ["NotoSans-Regular"]
        ) == "NotoSans-Regular")
    }

    @Test func mainBundleRegistrationValidationIsCached() {
        BighelpFontCatalog.resetMainBundleRegistrationCacheForTesting()

        let first = BighelpFontCatalog.registeredPostScriptNames(in: .main)
        let second = BighelpFontCatalog.registeredPostScriptNames(in: .main)

        #expect(second == first)
        #expect(BighelpFontCatalog.mainBundleValidationCountForTesting == 1)
    }

    @Test func bundleBackedResolutionUsesRegisteredNotoPostScriptNames() {
        let registered = BighelpFontCatalog.registeredPostScriptNames(in: .main)

        #expect(registered == ["NotoSans-Regular", "NotoSans-SemiBold"])
        #expect(BighelpFontCatalog.resolveFontName(
            candidates: ["Missing Requested Face", "Noto Sans"],
            in: .main
        ) == "NotoSans-Regular")
        #expect(BighelpFontCatalog.resolveFontName(
            candidates: ["Noto Sans SemiBold"],
            in: .main
        ) == "NotoSans-SemiBold")
    }

    @Test func defaultThemeUsesNativeSystemTypeAtEveryReadingSize() {
        for theme in [BighelpTheme.light, .dark, .lightHighContrast, .darkHighContrast] {
            #expect(theme.typeface == .system)
            for (role, weight) in [(BighelpFontRole.body, UIFont.Weight.regular), (.label, .semibold), (.screenTitle, .bold), (.metadata, .regular)] {
                let actual = theme.uiFont(role)
                let expected = UIFont.systemFont(ofSize: actual.pointSize, weight: weight)
                #expect(actual.fontName == expected.fontName)
            }
            #expect(theme.uiFont(.code).fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        }
    }

    @Test func nativeDefaultFollowsDynamicType() {
        let normal = UITraitCollection(preferredContentSizeCategory: .large)
        let large = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        #expect(BighelpTheme.light.uiFont(.body, compatibleWith: large).pointSize
                > BighelpTheme.light.uiFont(.body, compatibleWith: normal).pointSize)
    }
}
