import CoreText
import Foundation
import os

struct LoopdyBundledFont: Equatable, Sendable {
    let resourceName: String
    let `extension`: String
    let postScriptName: String
    let candidateNames: [String]

    var filename: String {
        "\(resourceName).\(`extension`)"
    }
}

enum LoopdyFontCatalog {
    private struct MainBundleRegistrationCache {
        var postScriptNames: Set<String>?
        var validationCount = 0
    }

    private static let mainBundleRegistrationCache = OSAllocatedUnfairLock(
        initialState: MainBundleRegistrationCache()
    )

    static let guaranteedFallbacks: [LoopdyBundledFont] = [
        LoopdyBundledFont(
            resourceName: "NotoSans-Regular",
            extension: "ttf",
            postScriptName: "NotoSans-Regular",
            candidateNames: ["Noto Sans", "Noto Sans Regular", "NotoSans-Regular"]
        ),
        LoopdyBundledFont(
            resourceName: "NotoSans-SemiBold",
            extension: "ttf",
            postScriptName: "NotoSans-SemiBold",
            candidateNames: ["Noto Sans SemiBold", "NotoSans-SemiBold"]
        ),
    ]

    static let bundledFonts = guaranteedFallbacks

    static func registeredPostScriptNames(in bundle: Bundle) -> Set<String> {
        guard bundle === Bundle.main else {
            return validatedRegisteredPostScriptNames(in: bundle)
        }

        return mainBundleRegistrationCache.withLock { cache in
            if let postScriptNames = cache.postScriptNames {
                return postScriptNames
            }

            let postScriptNames = validatedRegisteredPostScriptNames(in: bundle)
            cache.postScriptNames = postScriptNames
            cache.validationCount += 1
            return postScriptNames
        }
    }

    static func resetMainBundleRegistrationCacheForTesting() {
        mainBundleRegistrationCache.withLock { cache in
            cache = MainBundleRegistrationCache()
        }
    }

    static var mainBundleValidationCountForTesting: Int {
        mainBundleRegistrationCache.withLock { $0.validationCount }
    }

    private static func validatedRegisteredPostScriptNames(
        in bundle: Bundle
    ) -> Set<String> {
        let declaredFilenames = Set(
            bundle.object(forInfoDictionaryKey: "UIAppFonts") as? [String] ?? []
        )
        let availablePostScriptNames = Set(
            CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []
        )

        return Set(bundledFonts.compactMap { font in
            guard declaredFilenames.contains(font.filename),
                  bundle.url(
                    forResource: font.resourceName,
                    withExtension: font.extension
                  ) != nil,
                  availablePostScriptNames.contains(font.postScriptName)
            else {
                return nil
            }
            return font.postScriptName
        })
    }

    static func resolveFontName(
        candidates: [String],
        in bundle: Bundle
    ) -> String? {
        resolveFontName(
            candidates: candidates,
            availablePostScriptNames: registeredPostScriptNames(in: bundle)
        )
    }

    static func resolveFontName(
        candidates: [String],
        availablePostScriptNames: Set<String>
    ) -> String? {
        for candidate in candidates {
            if availablePostScriptNames.contains(candidate) {
                return candidate
            }

            if let font = bundledFonts.first(where: {
                $0.candidateNames.contains(candidate)
                    && availablePostScriptNames.contains($0.postScriptName)
            }) {
                return font.postScriptName
            }
        }
        return nil
    }
}
