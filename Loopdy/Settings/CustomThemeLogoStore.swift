import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CustomThemeLogoStoreError: Error, Equatable, Sendable {
    case themeNotFound
    case fileTooLarge(maximumBytes: Int)
    case unsupportedFormat
    case invalidDimensions
    case pixelLimitExceeded(maximumPixels: Int)
}

struct CustomThemeLogoStore {
    static let maximumByteCount = 1_000_000
    static let maximumDimension = 4_096
    static let maximumPixelCount = 4_000_000

    let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory.standardizedFileURL
        self.fileManager = fileManager
    }

    func store(_ data: Data, id: UUID = UUID()) throws -> CustomThemeLogo {
        guard data.count <= Self.maximumByteCount else {
            throw CustomThemeLogoStoreError.fileTooLarge(
                maximumBytes: Self.maximumByteCount
            )
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let typeIdentifier = CGImageSourceGetType(source),
              let contentType = UTType(typeIdentifier as String)
        else { throw CustomThemeLogoStoreError.unsupportedFormat }

        let format: CustomThemeLogoFormat
        if contentType.conforms(to: .png) {
            format = .png
        } else if contentType.conforms(to: .jpeg) {
            format = .jpeg
        } else if contentType.conforms(to: .heic) {
            format = .heic
        } else {
            throw CustomThemeLogoStoreError.unsupportedFormat
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= Self.maximumDimension,
              height <= Self.maximumDimension
        else { throw CustomThemeLogoStoreError.invalidDimensions }

        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= Self.maximumPixelCount else {
            throw CustomThemeLogoStoreError.pixelLimitExceeded(
                maximumPixels: Self.maximumPixelCount
            )
        }

        let logo = CustomThemeLogo(
            id: id,
            format: format,
            pixelWidth: width,
            pixelHeight: height,
            byteCount: data.count
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let destination = url(for: logo)
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return logo
    }

    func existingURL(for logo: CustomThemeLogo) -> URL? {
        let candidate = url(for: logo)
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func remove(_ logo: CustomThemeLogo) throws {
        let candidate = url(for: logo)
        guard fileManager.fileExists(atPath: candidate.path) else { return }
        try fileManager.removeItem(at: candidate)
    }

    private func url(for logo: CustomThemeLogo) -> URL {
        directory.appending(path: logo.fileName, directoryHint: .notDirectory)
    }
}
