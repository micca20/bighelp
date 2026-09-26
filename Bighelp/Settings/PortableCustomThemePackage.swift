import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PortableCustomThemePackageError: Error, Equatable, LocalizedError {
    case malformedPackage
    case invalidTheme
    case invalidLogo
    case packageTooLarge

    var errorDescription: String? {
        switch self {
        case .malformedPackage: "The theme package is malformed."
        case .invalidTheme: "The theme package contains an invalid theme."
        case .invalidLogo: "The theme package contains an invalid logo."
        case .packageTooLarge: "The theme package is larger than 2 MiB."
        }
    }
}

struct PortableCustomThemePayload: Equatable, Sendable {
    let sourceThemeID: UUID
    let theme: CustomTheme
    let lightLogoData: Data?
    let darkLogoData: Data?
}

enum PortableCustomThemePackage {
    static let maximumArtifactByteCount = 2 * 1_024 * 1_024

    private enum Kind: String, Codable {
        case theme
    }

    private struct Package: Codable {
        let schemaVersion: Int
        let kind: Kind
        let content: Content
    }

    private struct Content: Codable {
        let theme: PortableTheme
        let lightLogoBase64: String?
        let darkLogoBase64: String?
    }

    private struct PortableTheme: Codable {
        let id: UUID
        let name: String
        let description: String?
        let font: CustomThemeFontChoice
        let accentHex: String
        let light: CustomThemePalette
        let dark: CustomThemePalette

        init(_ theme: CustomTheme) {
            id = theme.id
            name = theme.name
            description = theme.description
            font = theme.font
            accentHex = theme.accentHex
            light = theme.light
            dark = theme.dark
        }

        func validatedTheme() throws -> CustomTheme {
            do {
                return try CustomTheme(
                    id: id,
                    name: name,
                    description: description,
                    font: font,
                    accentHex: accentHex,
                    light: light,
                    dark: dark
                )
            } catch {
                throw PortableCustomThemePackageError.invalidTheme
            }
        }
    }


    static func artifactData(
        theme: CustomTheme,
        lightLogoData: Data?,
        darkLogoData: Data?
    ) throws -> Data {
        let portableTheme = PortableTheme(theme)
        _ = try portableTheme.validatedTheme()
        let lightLogo = try lightLogoData.map(sanitizedLogo)
        let darkLogo = try darkLogoData.map(sanitizedLogo)
        let package = Package(
            schemaVersion: 1,
            kind: .theme,
            content: Content(
                theme: portableTheme,
                lightLogoBase64: lightLogo?.base64EncodedString(),
                darkLogoBase64: darkLogo?.base64EncodedString()
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(package)
        guard data.count <= maximumArtifactByteCount else {
            throw PortableCustomThemePackageError.packageTooLarge
        }
        return data
    }

    static func decodeArtifact(_ data: Data) throws -> PortableCustomThemePayload {
        guard !data.isEmpty, data.count <= maximumArtifactByteCount else {
            throw data.isEmpty
                ? PortableCustomThemePackageError.malformedPackage
                : PortableCustomThemePackageError.packageTooLarge
        }
        try validateJSONShape(data)

        let package: Package
        do {
            package = try JSONDecoder().decode(Package.self, from: data)
        } catch {
            throw PortableCustomThemePackageError.malformedPackage
        }
        guard package.schemaVersion == 1, package.kind == .theme else {
            throw PortableCustomThemePackageError.malformedPackage
        }

        let theme = try package.content.theme.validatedTheme()
        let lightLogo = try decodeLogo(package.content.lightLogoBase64)
        let darkLogo = try decodeLogo(package.content.darkLogoBase64)
        return PortableCustomThemePayload(
            sourceThemeID: theme.id,
            theme: theme,
            lightLogoData: lightLogo,
            darkLogoData: darkLogo
        )
    }


    private static func decodeLogo(_ encoded: String?) throws -> Data? {
        guard let encoded else { return nil }
        guard !encoded.isEmpty, let data = Data(base64Encoded: encoded) else {
            throw PortableCustomThemePackageError.invalidLogo
        }
        return try sanitizedLogo(data)
    }

    /// Portable logos are always converted to a single-frame PNG. Rendering
    /// the decoded pixels into a new destination strips EXIF, file names, paths,
    /// and any other source metadata before local file sharing or import.
    private static func sanitizedLogo(_ data: Data) throws -> Data {
        _ = try validatedLogoSource(data)
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else {
            throw PortableCustomThemePackageError.invalidLogo
        }

        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            result,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PortableCustomThemePackageError.invalidLogo
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PortableCustomThemePackageError.invalidLogo
        }
        let sanitized = result as Data
        _ = try validatedLogoSource(sanitized)
        return sanitized
    }


    @discardableResult
    private static func validatedLogoSource(_ data: Data) throws -> (width: Int, height: Int) {
        guard !data.isEmpty, data.count <= CustomThemeLogoStore.maximumByteCount,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) == 1,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              type.conforms(to: .png) || type.conforms(to: .jpeg) || type.conforms(to: .heic),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= CustomThemeLogoStore.maximumDimension,
              height <= CustomThemeLogoStore.maximumDimension
        else {
            throw PortableCustomThemePackageError.invalidLogo
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= CustomThemeLogoStore.maximumPixelCount else {
            throw PortableCustomThemePackageError.invalidLogo
        }
        return (width, height)
    }

    private static func validateJSONShape(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PortableCustomThemePackageError.malformedPackage
        }
        guard let root = object as? [String: Any],
              Set(root.keys) == ["schemaVersion", "kind", "content"],
              let content = root["content"] as? [String: Any],
              Set(content.keys).isSubset(of: [
                  "theme", "lightLogoBase64", "darkLogoBase64",
              ]),
              content["theme"] != nil,
              let theme = content["theme"] as? [String: Any]
        else {
            throw PortableCustomThemePackageError.malformedPackage
        }

        let requiredThemeKeys: Set<String> = [
            "id", "name", "font", "accentHex", "light", "dark",
        ]
        let allowedThemeKeys = requiredThemeKeys.union(["description"])
        guard Set(theme.keys).isSubset(of: allowedThemeKeys),
              requiredThemeKeys.isSubset(of: Set(theme.keys)),
              let light = theme["light"] as? [String: Any],
              let dark = theme["dark"] as? [String: Any]
        else {
            throw PortableCustomThemePackageError.malformedPackage
        }
        let paletteKeys: Set<String> = [
            "backgroundHex", "primaryTextHex", "secondaryTextHex", "tertiaryTextHex",
        ]
        guard Set(light.keys) == paletteKeys, Set(dark.keys) == paletteKeys else {
            throw PortableCustomThemePackageError.malformedPackage
        }
    }
}
