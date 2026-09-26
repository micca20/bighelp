import CryptoKit
import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

struct SessionAppearanceScope: Codable, Hashable, Sendable {
    let accountID: String
    let hostID: String
    let profileID: String
    let sessionID: String

    init(accountID: String, hostID: String, profileID: String, sessionID: String) throws {
        let values = [accountID, hostID, profileID, sessionID]
        guard values.allSatisfy({ value in
            !value.isEmpty
                && value.utf8.count <= 4_096
                && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { throw SessionAppearanceStoreError.invalidScope }
        self.accountID = accountID
        self.hostID = hostID
        self.profileID = profileID
        self.sessionID = sessionID
    }

    private var canonicalIdentity: Data {
        let canonical = [accountID, hostID, profileID, sessionID]
            .map { "\($0.utf8.count):\($0)" }.joined()
        return Data(("loopdy-session-appearance-v1:" + canonical).utf8)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.canonicalIdentity == rhs.canonicalIdentity }
    func hash(into hasher: inout Hasher) { hasher.combine(canonicalIdentity) }

    fileprivate var storageID: String {
        SHA256.hash(data: canonicalIdentity).map { String(format: "%02x", $0) }.joined()
    }
}

enum SessionAppearanceChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case inherit
    case sky
    case ocean
    case violet
    case graphite
    case photo

    var id: Self { self }

    var title: String {
        switch self {
        case .inherit: "App"
        case .sky: "Sky"
        case .ocean: "Ocean"
        case .violet: "Violet"
        case .graphite: "Graphite"
        case .photo: "Photo"
        }
    }

    var systemImage: String {
        switch self {
        case .inherit: "circle.lefthalf.filled"
        case .sky: "sun.horizon.fill"
        case .ocean: "water.waves"
        case .violet: "sparkles"
        case .graphite: "circle.fill"
        case .photo: "photo.fill"
        }
    }
}

struct SessionAppearancePhotoReference: Codable, Equatable, Sendable {
    let id: UUID
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int

    fileprivate var fileName: String { id.uuidString.lowercased() + ".jpg" }
}

struct SessionAppearancePreference: Codable, Equatable, Sendable {
    let scope: SessionAppearanceScope
    let choice: SessionAppearanceChoice
    let dimming: Double
    let photo: SessionAppearancePhotoReference?

    static let maximumDimming = 0.65
}

private struct SessionAppearancePersistenceTransaction: Codable, Equatable, Sendable {
    let previousPreferenceData: Data?
    let targetPreferenceData: Data?
    let obsoletePhoto: SessionAppearancePhotoReference?
    let removesScopedPhotoDirectory: Bool
}

/// The UIImage wraps an immutable, fully decoded CGImage produced by a bounded worker.
struct SessionAppearanceDecodedPhoto: @unchecked Sendable, Equatable {
    let id: UUID
    let image: UIImage

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

struct SessionAppearanceSnapshot: Equatable, Sendable {
    let choice: SessionAppearanceChoice
    let dimming: Double
    let photoURL: URL?
    let decodedPhoto: SessionAppearanceDecodedPhoto?

    init(
        choice: SessionAppearanceChoice,
        dimming: Double,
        photoURL: URL?,
        decodedPhoto: SessionAppearanceDecodedPhoto? = nil
    ) {
        self.choice = choice
        self.dimming = dimming
        self.photoURL = photoURL
        self.decodedPhoto = decodedPhoto
    }

    static let inherited = SessionAppearanceSnapshot(
        choice: .inherit,
        dimming: 0,
        photoURL: nil
    )
}

struct SessionAppearancePreparedPhoto: Equatable, Sendable {
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let decodedPhoto: SessionAppearanceDecodedPhoto

    fileprivate init(
        data: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        decodedPhoto: SessionAppearanceDecodedPhoto
    ) {
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.decodedPhoto = decodedPhoto
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data == rhs.data
            && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
    }
}

enum SessionAppearanceStoreError: Error, Equatable, Sendable {
    case invalidScope
    case invalidDimming
    case photoRequired
    case photoTooLarge(maximumBytes: Int)
    case unsupportedPhoto
    case photoDimensionsTooLarge
    case persistenceFailed
}

@MainActor
@Observable
final class SessionAppearanceStore {
    nonisolated static let defaultsKeyPrefix = "loopdy.session-appearance.v1."
    nonisolated static let maximumInputByteCount = 12_000_000
    nonisolated static let maximumInputPixelCount = 40_000_000
    nonisolated static let maximumStoredDimension = 2_400
    nonisolated private static let maximumCleanupEntryCount = 128

    let scope: SessionAppearanceScope
    private(set) var preference: SessionAppearancePreference?
    private(set) var isRetired = false
    private var committedPhoto: SessionAppearanceDecodedPhoto?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let photoRoot: URL
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var validationID: UUID?

    init(
        scope: SessionAppearanceScope,
        defaults: UserDefaults = .standard,
        photoDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.scope = scope
        self.defaults = defaults
        self.fileManager = fileManager
        let arguments = ProcessInfo.processInfo.arguments
        let usesFixtures = arguments.contains("-disable-demo-delays")
            || arguments.contains("-use-demo-fixtures")
        photoRoot = (photoDirectory ?? LoopdyApplicationDataDirectories.active(fixtures: usesFixtures)
            .appending(path: "session-appearance", directoryHint: .isDirectory))
            .standardizedFileURL
        preference = nil
        committedPhoto = nil
        reload()
    }

    var snapshot: SessionAppearanceSnapshot {
        guard let preference else { return .inherited }
        guard preference.choice == .photo else {
            return SessionAppearanceSnapshot(
                choice: preference.choice,
                dimming: preference.dimming,
                photoURL: nil
            )
        }
        guard let photo = preference.photo,
              let committedPhoto,
              committedPhoto.id == photo.id,
              let url = safePhotoURL(for: photo)
        else { return .inherited }
        return SessionAppearanceSnapshot(
            choice: .photo,
            dimming: preference.dimming,
            photoURL: url,
            decodedPhoto: committedPhoto
        )
    }

    func retire() {
        guard !isRetired else { return }
        isRetired = true
        cancelValidation()
    }

    func reload() {
        guard !isRetired else { return }
        cancelValidation()
        committedPhoto = nil

        let transactionWasResolved: Bool
        do {
            try resolvePendingTransaction()
            transactionWasResolved = true
        } catch {
            transactionWasResolved = false
        }

        switch Self.loadCandidate(scope: scope, defaults: defaults) {
        case .absent:
            preference = nil
            cleanupUnreferencedPhotos(keeping: nil)
        case .invalid:
            preference = nil
            if transactionWasResolved {
                removeInvalidPreference()
            }
            cleanupUnreferencedPhotos(keeping: nil)
        case .value(let value):
            preference = value
            guard let photo = value.photo else {
                cleanupUnreferencedPhotos(keeping: nil)
                return
            }
            guard let url = safePhotoURL(for: photo) else {
                invalidateLoadedPreference()
                return
            }
            beginValidation(of: photo, at: url)
        }
    }

    func apply(
        choice: SessionAppearanceChoice,
        dimming: Double,
        preparedPhoto: SessionAppearancePreparedPhoto? = nil
    ) throws {
        guard !isRetired else { throw SessionAppearanceStoreError.invalidScope }
        guard dimming.isFinite, (0...SessionAppearancePreference.maximumDimming).contains(dimming) else {
            throw SessionAppearanceStoreError.invalidDimming
        }

        cancelValidation()
        try resolvePendingTransaction()
        let previousPreference = preference
        let previousData = defaults.data(forKey: preferenceKey)
        guard previousData != nil || defaults.object(forKey: preferenceKey) == nil else {
            reload()
            throw SessionAppearanceStoreError.persistenceFailed
        }
        let previousPhoto = previousPreference?.photo

        let nextPhoto: SessionAppearancePhotoReference?
        let nextDecodedPhoto: SessionAppearanceDecodedPhoto?
        var newlyWrittenURL: URL?
        if choice == .photo {
            if let preparedPhoto {
                guard preparedPhoto.pixelWidth > 0,
                      preparedPhoto.pixelHeight > 0,
                      preparedPhoto.pixelWidth <= Self.maximumStoredDimension,
                      preparedPhoto.pixelHeight <= Self.maximumStoredDimension,
                      preparedPhoto.data.count <= Self.maximumInputByteCount,
                      preparedPhoto.decodedPhoto.image.cgImage?.width == preparedPhoto.pixelWidth,
                      preparedPhoto.decodedPhoto.image.cgImage?.height == preparedPhoto.pixelHeight
                else { throw SessionAppearanceStoreError.unsupportedPhoto }
                let photo = SessionAppearancePhotoReference(
                    id: UUID(),
                    pixelWidth: preparedPhoto.pixelWidth,
                    pixelHeight: preparedPhoto.pixelHeight,
                    byteCount: preparedPhoto.data.count
                )
                newlyWrittenURL = try writeStaged(preparedPhoto.data, photo: photo)
                nextPhoto = photo
                nextDecodedPhoto = SessionAppearanceDecodedPhoto(
                    id: photo.id,
                    image: preparedPhoto.decodedPhoto.image
                )
            } else if let previousPhoto,
                      let committedPhoto,
                      committedPhoto.id == previousPhoto.id,
                      safePhotoURL(for: previousPhoto) != nil {
                nextPhoto = previousPhoto
                nextDecodedPhoto = committedPhoto
            } else {
                throw SessionAppearanceStoreError.photoRequired
            }
        } else {
            nextPhoto = nil
            nextDecodedPhoto = nil
        }

        let next = choice == .inherit ? nil : SessionAppearancePreference(
            scope: scope,
            choice: choice,
            dimming: dimming,
            photo: nextPhoto
        )
        let encoded: Data?
        do {
            encoded = try next.map { try JSONEncoder().encode($0) }
        } catch {
            if let newlyWrittenURL { try? fileManager.removeItem(at: newlyWrittenURL) }
            throw SessionAppearanceStoreError.persistenceFailed
        }

        let transaction = SessionAppearancePersistenceTransaction(
            previousPreferenceData: previousData,
            targetPreferenceData: encoded,
            obsoletePhoto: previousPhoto == nextPhoto ? nil : previousPhoto,
            removesScopedPhotoDirectory: false
        )
        do {
            try persistTransaction(transaction)
            try writePreferenceData(encoded)
        } catch {
            try? resolvePendingTransaction()
            if !preferenceMatches(encoded), let newlyWrittenURL {
                try? fileManager.removeItem(at: newlyWrittenURL)
            }
            reload()
            throw SessionAppearanceStoreError.persistenceFailed
        }

        committedPhoto = nextDecodedPhoto
        preference = next
        do {
            try resolvePendingTransaction()
        } catch {
            throw SessionAppearanceStoreError.persistenceFailed
        }
        cleanupUnreferencedPhotos(keeping: nextPhoto)
    }

    func erase() throws {
        guard !isRetired else { throw SessionAppearanceStoreError.invalidScope }
        cancelValidation()
        try resolvePendingTransaction()
        let previousData = defaults.data(forKey: preferenceKey)
        guard previousData != nil || defaults.object(forKey: preferenceKey) == nil else {
            reload()
            throw SessionAppearanceStoreError.persistenceFailed
        }

        let transaction = SessionAppearancePersistenceTransaction(
            previousPreferenceData: previousData,
            targetPreferenceData: nil,
            obsoletePhoto: nil,
            removesScopedPhotoDirectory: true
        )
        do {
            try persistTransaction(transaction)
            try writePreferenceData(nil)
        } catch {
            try? resolvePendingTransaction()
            reload()
            throw SessionAppearanceStoreError.persistenceFailed
        }

        committedPhoto = nil
        preference = nil
        do {
            try resolvePendingTransaction()
        } catch {
            throw SessionAppearanceStoreError.persistenceFailed
        }
    }

    nonisolated static func preparePhoto(_ data: Data) throws -> SessionAppearancePreparedPhoto {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw SessionAppearanceStoreError.unsupportedPhoto }
        guard data.count <= maximumInputByteCount else {
            throw SessionAppearanceStoreError.photoTooLarge(maximumBytes: maximumInputByteCount)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
              ) as? [CFString: Any],
              let sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              sourceWidth > 0,
              sourceHeight > 0
        else { throw SessionAppearanceStoreError.unsupportedPhoto }

        let (sourcePixels, overflow) = sourceWidth.multipliedReportingOverflow(by: sourceHeight)
        guard !overflow, sourcePixels <= maximumInputPixelCount else {
            throw SessionAppearanceStoreError.photoDimensionsTooLarge
        }
        try Task.checkCancellation()

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumStoredDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let encoded = UIImage(cgImage: image).jpegData(compressionQuality: 0.88),
              !encoded.isEmpty,
              encoded.count <= maximumInputByteCount
        else { throw SessionAppearanceStoreError.unsupportedPhoto }
        try Task.checkCancellation()

        return SessionAppearancePreparedPhoto(
            data: encoded,
            pixelWidth: image.width,
            pixelHeight: image.height,
            decodedPhoto: SessionAppearanceDecodedPhoto(id: UUID(), image: UIImage(cgImage: image))
        )
    }

    private enum LoadCandidate {
        case absent
        case invalid
        case value(SessionAppearancePreference)
    }

    private var preferenceKey: String { Self.defaultsKeyPrefix + scope.storageID }
    private var transactionKey: String { preferenceKey + ".transaction" }

    private var safeScopedPhotoDirectory: URL? {
        guard hasSafePhotoRootPath else { return nil }
        return Self.safeScopedPhotoDirectory(photoRoot: photoRoot, storageID: scope.storageID)
    }

    private var hasSafePhotoRootPath: Bool {
        let root = photoRoot.standardizedFileURL
        guard root.isFileURL else { return false }
        var candidate = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.pathComponents.dropFirst() {
            candidate.append(path: component, directoryHint: .isDirectory)

            // Darwin exposes these immutable filesystem aliases to app and test-container
            // paths. Resolve no other symlink in a caller-configured photo root.
            if candidate.path == "/var" || candidate.path == "/tmp" {
                continue
            }
            if (try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                return false
            }
            if fileManager.fileExists(atPath: candidate.path) {
                guard let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]),
                      values.isSymbolicLink != true
                else { return false }
            }
        }
        return true
    }

    private func safePhotoURL(for photo: SessionAppearancePhotoReference) -> URL? {
        guard let directory = safeScopedPhotoDirectory else { return nil }
        if fileManager.fileExists(atPath: directory.path) {
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else { return nil }
        }
        return Self.safePhotoURL(directory: directory, fileName: photo.fileName)
    }

    private func beginValidation(of photo: SessionAppearancePhotoReference, at url: URL) {
        let identifier = UUID()
        validationID = identifier
        validationTask = Task { [weak self] in
            let worker = Self.storedPhotoValidationTask(photo, at: url)
            do {
                let decoded = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard let self,
                      !self.isRetired,
                      self.validationID == identifier,
                      self.preference?.photo == photo
                else { return }
                self.committedPhoto = decoded
                self.validationTask = nil
                self.validationID = nil
                self.cleanupUnreferencedPhotos(keeping: photo)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      !self.isRetired,
                      self.validationID == identifier,
                      self.preference?.photo == photo
                else { return }
                self.invalidateLoadedPreference()
            }
        }
    }

    private nonisolated static func storedPhotoValidationTask(
        _ photo: SessionAppearancePhotoReference,
        at url: URL
    ) -> Task<SessionAppearanceDecodedPhoto, any Error> {
        Task.detached(priority: .userInitiated) { @Sendable [photo, url] in
            try Self.validateStoredPhoto(photo, at: url, fileManager: .default)
        }
    }

    private func cancelValidation() {
        validationTask?.cancel()
        validationTask = nil
        validationID = nil
    }

    private func invalidateLoadedPreference() {
        cancelValidation()
        committedPhoto = nil
        preference = nil
        removeInvalidPreference()
        cleanupUnreferencedPhotos(keeping: nil)
    }

    private func removeInvalidPreference() {
        defaults.removeObject(forKey: preferenceKey)
    }

    private func persistTransaction(_ transaction: SessionAppearancePersistenceTransaction) throws {
        let encoded = try JSONEncoder().encode(transaction)
        defaults.set(encoded, forKey: transactionKey)
        guard defaults.data(forKey: transactionKey) == encoded else {
            throw SessionAppearanceStoreError.persistenceFailed
        }
    }

    private func resolvePendingTransaction() throws {
        guard let encoded = defaults.data(forKey: transactionKey) else {
            guard defaults.object(forKey: transactionKey) == nil else {
                defaults.removeObject(forKey: transactionKey)
                guard defaults.object(forKey: transactionKey) == nil else {
                    throw SessionAppearanceStoreError.persistenceFailed
                }
                return
            }
            return
        }
        guard let transaction = try? JSONDecoder().decode(
            SessionAppearancePersistenceTransaction.self,
            from: encoded
        ) else {
            defaults.removeObject(forKey: transactionKey)
            guard defaults.object(forKey: transactionKey) == nil else {
                throw SessionAppearanceStoreError.persistenceFailed
            }
            return
        }

        if preferenceMatches(transaction.targetPreferenceData) {
            if transaction.removesScopedPhotoDirectory {
                try removeScopedPhotos()
            } else {
                try remove(transaction.obsoletePhoto)
            }
        } else if !preferenceMatches(transaction.previousPreferenceData) {
            try writePreferenceData(transaction.previousPreferenceData)
        }

        defaults.removeObject(forKey: transactionKey)
        guard defaults.object(forKey: transactionKey) == nil else {
            throw SessionAppearanceStoreError.persistenceFailed
        }
    }

    private func preferenceMatches(_ data: Data?) -> Bool {
        if let data {
            return defaults.data(forKey: preferenceKey) == data
        }
        return defaults.object(forKey: preferenceKey) == nil
    }

    private func writePreferenceData(_ data: Data?) throws {
        if let data {
            defaults.set(data, forKey: preferenceKey)
        } else {
            defaults.removeObject(forKey: preferenceKey)
        }
        guard preferenceMatches(data) else {
            throw SessionAppearanceStoreError.persistenceFailed
        }
    }

    private func writeStaged(_ data: Data, photo: SessionAppearancePhotoReference) throws -> URL {
        guard let directory = safeScopedPhotoDirectory,
              let destination = safePhotoURL(for: photo)
        else { throw SessionAppearanceStoreError.invalidScope }
        try ensureWritableDirectory(directory)

        let stageName = ".stage-\(UUID().uuidString.lowercased()).jpg"
        guard let staged = Self.safePhotoURL(directory: directory, fileName: stageName),
              !fileManager.fileExists(atPath: destination.path)
        else { throw SessionAppearanceStoreError.persistenceFailed }

        do {
            try data.write(to: staged, options: .completeFileProtection)
            try protectAndExcludeFromBackup(staged)
            guard try Self.readBoundedData(
                at: staged,
                expectedByteCount: data.count,
                fileManager: fileManager
            ) == data else { throw SessionAppearanceStoreError.persistenceFailed }
            try fileManager.moveItem(at: staged, to: destination)
            try protectAndExcludeFromBackup(destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: staged)
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func ensureWritableDirectory(_ directory: URL) throws {
        if fileManager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SessionAppearanceStoreError.invalidScope
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        try protectAndExcludeFromBackup(directory)
    }

    private func protectAndExcludeFromBackup(_ url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private func remove(_ photo: SessionAppearancePhotoReference?) throws {
        guard let photo else { return }
        guard let url = safePhotoURL(for: photo) else {
            throw SessionAppearanceStoreError.invalidScope
        }
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SessionAppearanceStoreError.invalidScope
        }
        try fileManager.removeItem(at: url)
    }

    private func cleanupUnreferencedPhotos(keeping photo: SessionAppearancePhotoReference?) {
        guard let directory = safeScopedPhotoDirectory,
              fileManager.fileExists(atPath: directory.path),
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true,
              let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              )
        else { return }

        let keptName = photo?.fileName
        let eligibleEntries = entries
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .filter { entry in
                let name = entry.lastPathComponent
                guard name != keptName, name.hasSuffix(".jpg") else { return false }
                guard Self.safePhotoURL(directory: directory, fileName: name) == entry.standardizedFileURL,
                      let entryValues = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                else { return false }
                return entryValues.isRegularFile == true && entryValues.isSymbolicLink != true
            }
        for entry in eligibleEntries.prefix(Self.maximumCleanupEntryCount) {
            try? fileManager.removeItem(at: entry)
        }

        // Hidden staging files are enumerated separately because skipsHiddenFiles keeps the
        // normal sweep focused on committed JPEGs.
        guard let hiddenEntries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return }
        let eligibleHiddenEntries = hiddenEntries
            .filter { entry in
                let name = entry.lastPathComponent
                guard name.hasPrefix(".stage-"),
                      Self.safePhotoURL(directory: directory, fileName: name) == entry.standardizedFileURL,
                      let entryValues = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                else { return false }
                return entryValues.isRegularFile == true && entryValues.isSymbolicLink != true
            }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        for entry in eligibleHiddenEntries.prefix(Self.maximumCleanupEntryCount) {
            try? fileManager.removeItem(at: entry)
        }
    }

    private func removeScopedPhotos() throws {
        guard let directory = safeScopedPhotoDirectory else {
            throw SessionAppearanceStoreError.invalidScope
        }
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SessionAppearanceStoreError.invalidScope
        }
        try fileManager.removeItem(at: directory)
    }

    private nonisolated static func loadCandidate(
        scope: SessionAppearanceScope,
        defaults: UserDefaults
    ) -> LoadCandidate {
        let key = defaultsKeyPrefix + scope.storageID
        guard let data = defaults.data(forKey: key) else { return .absent }
        guard let value = try? JSONDecoder().decode(SessionAppearancePreference.self, from: data),
              value.scope == scope,
              value.choice != .inherit,
              value.dimming.isFinite,
              (0...SessionAppearancePreference.maximumDimming).contains(value.dimming),
              (value.choice == .photo) == (value.photo != nil)
        else { return .invalid }
        if let photo = value.photo {
            let (pixels, overflow) = photo.pixelWidth.multipliedReportingOverflow(by: photo.pixelHeight)
            guard photo.byteCount > 0,
                  photo.byteCount <= maximumInputByteCount,
                  photo.pixelWidth > 0,
                  photo.pixelHeight > 0,
                  photo.pixelWidth <= maximumStoredDimension,
                  photo.pixelHeight <= maximumStoredDimension,
                  !overflow,
                  pixels <= maximumInputPixelCount
            else { return .invalid }
        }
        return .value(value)
    }

    private nonisolated static func safeScopedPhotoDirectory(
        photoRoot: URL,
        storageID: String
    ) -> URL? {
        guard photoRoot.isFileURL,
              storageID.count == 64,
              storageID.allSatisfy({ $0.isHexDigit })
        else { return nil }
        let root = photoRoot.standardizedFileURL
        let directory = root
            .appending(path: storageID, directoryHint: .isDirectory)
            .standardizedFileURL
        guard directory.deletingLastPathComponent().path.utf8.elementsEqual(root.path.utf8),
              directory.lastPathComponent == storageID
        else { return nil }
        return directory
    }

    private nonisolated static func safePhotoURL(directory: URL, fileName: String) -> URL? {
        guard !fileName.isEmpty,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent
        else { return nil }
        let standardizedDirectory = directory.standardizedFileURL
        let url = standardizedDirectory
            .appending(path: fileName, directoryHint: .notDirectory)
            .standardizedFileURL
        guard url.deletingLastPathComponent().path.utf8.elementsEqual(standardizedDirectory.path.utf8),
              url.lastPathComponent == fileName
        else { return nil }
        return url
    }

    private nonisolated static func validateStoredPhoto(
        _ photo: SessionAppearancePhotoReference,
        at url: URL,
        fileManager: FileManager
    ) throws -> SessionAppearanceDecodedPhoto {
        try Task.checkCancellation()
        let data = try readBoundedData(
            at: url,
            expectedByteCount: photo.byteCount,
            fileManager: fileManager
        )
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
              ) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == photo.pixelWidth,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == photo.pixelHeight
        else { throw SessionAppearanceStoreError.unsupportedPhoto }
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
        ] as CFDictionary),
              image.width == photo.pixelWidth,
              image.height == photo.pixelHeight
        else { throw SessionAppearanceStoreError.unsupportedPhoto }
        try Task.checkCancellation()
        return SessionAppearanceDecodedPhoto(id: photo.id, image: UIImage(cgImage: image))
    }

    private nonisolated static func readBoundedData(
        at url: URL,
        expectedByteCount: Int,
        fileManager: FileManager
    ) throws -> Data {
        guard expectedByteCount > 0, expectedByteCount <= maximumInputByteCount else {
            throw SessionAppearanceStoreError.unsupportedPhoto
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw SessionAppearanceStoreError.unsupportedPhoto
        }
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == expectedByteCount
        else { throw SessionAppearanceStoreError.unsupportedPhoto }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(expectedByteCount)
        while let chunk = try handle.read(upToCount: min(64 * 1_024, expectedByteCount - data.count + 1)),
              !chunk.isEmpty {
            try Task.checkCancellation()
            guard chunk.count <= expectedByteCount - data.count else {
                throw SessionAppearanceStoreError.unsupportedPhoto
            }
            data.append(chunk)
        }
        guard data.count == expectedByteCount else {
            throw SessionAppearanceStoreError.unsupportedPhoto
        }
        return data
    }
}
