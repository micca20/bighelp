import Foundation
import ImageIO
import Testing
import UIKit
@testable import Loopdy

@MainActor
struct PortableCustomThemeTests {
    @Test func exportedPortableThemeCanBeImportedThroughSettings() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let source = try makeTheme(name: "Exported custom theme")
        _ = try context.settings.saveCustomTheme(source)
        context.settings.themeID = source.themeID
        let bytes = try PortableCustomThemePackage.artifactData(
            theme: source, lightLogoData: nil, darkLogoData: nil
        )
        let file = context.root.appending(path: "exported.loopdy-theme.json")
        try bytes.write(to: file)

        try context.settings.importCustomThemeFile(Data(contentsOf: file))

        #expect(context.settings.customThemes.count == 2)
        #expect(context.settings.customThemes.first == source)
        let imported = try #require(context.settings.customThemes.last)
        #expect(imported.id != source.id)
        #expect(imported.name == source.name)
        #expect(imported.description == source.description)
        #expect(imported.font == source.font)
        #expect(imported.accentHex == source.accentHex)
        #expect(imported.light == source.light)
        #expect(imported.dark == source.dark)
        #expect(context.settings.themeID == source.themeID)
    }

    @Test func portableFilePreservesExistingEditsAndBothLogosAfterReload() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let original = try makeTheme(name: "Exported version")
        let edited = try makeTheme(id: original.id, name: "Keep my edits")
        _ = try context.settings.saveCustomTheme(edited)
        context.settings.themeID = edited.themeID
        let bytes = try PortableCustomThemePackage.artifactData(
            theme: original,
            lightLogoData: try makeMetadataBearingLogo(comment: "light", color: .white),
            darkLogoData: try makeMetadataBearingLogo(comment: "dark", color: .black)
        )
        let expected = try PortableCustomThemePackage.decodeArtifact(bytes)

        try context.settings.importCustomThemeFile(bytes)

        let reloaded = SettingsStore(defaults: context.defaults, customThemeLogoDirectory: context.logoDirectory)
        #expect(reloaded.customThemes.count == 2)
        #expect(reloaded.customThemes.first == edited)
        #expect(reloaded.themeID == edited.themeID)
        let imported = try #require(reloaded.customThemes.last)
        #expect(imported.id != original.id)
        #expect(imported.name == original.name)
        #expect(try reloaded.customLogoData(for: imported.id, variant: .light) == expected.lightLogoData)
        #expect(try reloaded.customLogoData(for: imported.id, variant: .dark) == expected.darkLogoData)
        #expect(expected.lightLogoData != expected.darkLogoData)
        #expect(!FileManager.default.fileExists(atPath: context.root.appending(path: "receipts.json").path))
    }

    @Test func collectionFileStillUpsertsWithoutRemovingUnrelatedThemes() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let kept = try makeTheme(name: "Unrelated")
        let old = try makeTheme(name: "Old")
        let updated = try makeTheme(id: old.id, name: "Updated")
        let added = try makeTheme(name: "Added")
        _ = try context.settings.saveCustomTheme(kept)
        _ = try context.settings.saveCustomTheme(old)
        context.settings.themeID = kept.themeID
        let bytes = try JSONEncoder().encode(CustomThemeCatalog(themes: [updated, added]))

        try context.settings.importCustomThemeFile(bytes)

        let reloaded = SettingsStore(defaults: context.defaults, customThemeLogoDirectory: context.logoDirectory)
        #expect(reloaded.customThemes == [kept, updated, added])
        #expect(reloaded.themeID == kept.themeID)
    }

    @Test(arguments: ["version", "kind", "palette", "logo", "mixed", "malformed", "oversized", "catalogVersion", "duplicateIDs"])
    func invalidThemeFilesDoNotMutateSettings(variant: String) throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let existing = try makeTheme(name: "Keep")
        _ = try context.settings.saveCustomTheme(existing)
        context.settings.themeID = existing.themeID
        let before = context.defaults.data(forKey: "loopdy.appearance.customThemes")
        let valid = try PortableCustomThemePackage.artifactData(theme: existing, lightLogoData: nil, darkLogoData: nil)
        var root = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        switch variant {
        case "version": root["schemaVersion"] = 2
        case "kind": root["kind"] = "skill"
        case "palette":
            var content = try #require(root["content"] as? [String: Any])
            var theme = try #require(content["theme"] as? [String: Any])
            theme["accentHex"] = "not-a-color"
            content["theme"] = theme
            root["content"] = content
        case "logo":
            var content = try #require(root["content"] as? [String: Any])
            content["darkLogoBase64"] = Data("not an image".utf8).base64EncodedString()
            root["content"] = content
        case "mixed": root["themes"] = []
        case "catalogVersion": root = ["schemaVersion": 2, "themes": []]
        case "duplicateIDs":
            root = try #require(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(CustomThemeCatalog(themes: [existing, existing]))
            ) as? [String: Any])
        default: break
        }
        let bytes: Data
        switch variant {
        case "malformed": bytes = Data("not JSON".utf8)
        case "oversized": bytes = Data(repeating: 32, count: PortableCustomThemePackage.maximumArtifactByteCount + 1)
        default: bytes = try JSONSerialization.data(withJSONObject: root)
        }

        #expect(throws: (any Error).self) { try context.settings.importCustomThemeFile(bytes) }

        #expect(context.settings.customThemes == [existing])
        #expect(context.settings.themeID == existing.themeID)
        #expect(context.defaults.data(forKey: "loopdy.appearance.customThemes") == before)
    }

    @Test func portableImportAtCapacityLeavesSavedThemesUntouched() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        for index in 0..<SettingsStore.maximumCustomThemes {
            _ = try context.settings.saveCustomTheme(try makeTheme(name: "Theme \(index)"))
        }
        let before = context.settings.customThemes
        let stored = context.defaults.data(forKey: "loopdy.appearance.customThemes")
        let bytes = try PortableCustomThemePackage.artifactData(theme: try #require(before.first), lightLogoData: nil, darkLogoData: nil)

        #expect(throws: CustomThemeStoreError.limitReached(maximum: SettingsStore.maximumCustomThemes)) {
            try context.settings.importCustomThemeFile(bytes)
        }
        #expect(context.settings.customThemes == before)
        #expect(context.defaults.data(forKey: "loopdy.appearance.customThemes") == stored)
    }

    @Test func portableImportLogoWriteFailureRollsBackSettings() throws {
        let context = try makeContext(logoDirectoryIsFile: true)
        defer { context.cleanup() }
        let existing = try makeTheme(name: "Keep")
        _ = try context.settings.saveCustomTheme(existing)
        context.settings.themeID = existing.themeID
        let before = context.defaults.data(forKey: "loopdy.appearance.customThemes")
        let bytes = try PortableCustomThemePackage.artifactData(
            theme: existing, lightLogoData: try makeMetadataBearingLogo(comment: "logo"), darkLogoData: nil
        )

        #expect(throws: (any Error).self) { try context.settings.importCustomThemeFile(bytes) }

        #expect(context.settings.customThemes == [existing])
        #expect(context.settings.themeID == existing.themeID)
        #expect(context.defaults.data(forKey: "loopdy.appearance.customThemes") == before)
    }

    @Test func portablePackageRoundTripsBothSanitizedLogosWithoutLocalMetadata() throws {
        let theme = try makeTheme(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
        )
        let logo = try makeMetadataBearingLogo(comment: "/Users/alice/private/logo.jpg")

        let artifact = try PortableCustomThemePackage.artifactData(
            theme: theme,
            lightLogoData: logo,
            darkLogoData: logo
        )
        let decoded = try PortableCustomThemePackage.decodeArtifact(artifact)

        #expect(decoded.sourceThemeID == theme.id)
        #expect(decoded.theme.lightLogo == nil)
        #expect(decoded.theme.darkLogo == nil)
        #expect(decoded.lightLogoData != nil)
        #expect(decoded.darkLogoData != nil)
        #expect(decoded.lightLogoData != logo)
        #expect(!String(decoding: try #require(decoded.lightLogoData), as: UTF8.self)
            .contains("/Users/alice"))
        let object = try #require(
            JSONSerialization.jsonObject(with: artifact) as? [String: Any]
        )
        let content = try #require(object["content"] as? [String: Any])
        let encodedTheme = try #require(content["theme"] as? [String: Any])
        #expect(encodedTheme["lightLogo"] == nil)
        #expect(encodedTheme["darkLogo"] == nil)
        #expect(Set(content.keys) == Set(["theme", "lightLogoBase64", "darkLogoBase64"]))
    }

    @Test func invalidPaletteCannotEnterThroughPortableThemeJSON() throws {
        let theme = try makeTheme()
        let artifact = try PortableCustomThemePackage.artifactData(
            theme: theme,
            lightLogoData: nil,
            darkLogoData: nil
        )
        var root = try #require(
            JSONSerialization.jsonObject(with: artifact) as? [String: Any]
        )
        var content = try #require(root["content"] as? [String: Any])
        var encodedTheme = try #require(content["theme"] as? [String: Any])
        encodedTheme["accentHex"] = "url(file:///private/theme)"
        content["theme"] = encodedTheme
        root["content"] = content
        let hostile = try JSONSerialization.data(withJSONObject: root)

        #expect(throws: PortableCustomThemePackageError.invalidTheme) {
            try PortableCustomThemePackage.decodeArtifact(hostile)
        }
    }

    private func makeTheme(
        id: UUID = UUID(),
        name: String = "Calm"
    ) throws -> CustomTheme {
        try CustomTheme(
            id: id,
            name: name,
            description: "Quiet colors for focused work.",
            font: .system,
            accentHex: "3366CC",
            light: CustomThemePalette(
                backgroundHex: "FFFFFF",
                primaryTextHex: "111111",
                secondaryTextHex: "333333",
                tertiaryTextHex: "555555"
            ),
            dark: CustomThemePalette(
                backgroundHex: "101010",
                primaryTextHex: "FFFFFF",
                secondaryTextHex: "E0E0E0",
                tertiaryTextHex: "B0B0B0"
            )
        )
    }

    private func makeMetadataBearingLogo(comment: String, color: UIColor = .systemIndigo) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        let cgImage = try #require(image.cgImage)
        let result = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            result,
            "public.jpeg" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: comment,
            ],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return result as Data
    }

    private func makeContext(
        logoDirectoryIsFile: Bool = false
    ) throws -> PortableThemeContext {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-portable-theme-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logoDirectory = root.appending(path: "logos", directoryHint: .isDirectory)
        if logoDirectoryIsFile {
            try Data("occupied".utf8).write(to: logoDirectory)
        }
        let suiteName = "PortableCustomThemeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return PortableThemeContext(
            root: root,
            suiteName: suiteName,
            defaults: defaults,
            logoDirectory: logoDirectory,
            settings: SettingsStore(
                defaults: defaults,
                customThemeLogoDirectory: logoDirectory
            )
        )
    }
}

@MainActor
private struct PortableThemeContext {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let logoDirectory: URL
    let settings: SettingsStore

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
