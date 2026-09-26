import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

enum BighelpLocalPersistenceError: Error, Equatable {
    case protectedDataUnavailable
}

protocol BighelpProtectedDataAvailabilityProviding: Sendable {
    var isProtectedDataAvailable: Bool { get }
}

struct BighelpSystemProtectedDataAvailability: BighelpProtectedDataAvailabilityProviding {
    var isProtectedDataAvailable: Bool {
        #if canImport(UIKit)
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                UIApplication.shared.isProtectedDataAvailable
            }
        }
        return DispatchQueue.main.sync {
            UIApplication.shared.isProtectedDataAvailable
        }
        #else
        true
        #endif
    }
}

enum BighelpProtectedDataAvailabilityNotification {
    static let didBecomeAvailable: Notification.Name = {
        #if canImport(UIKit)
        UIApplication.protectedDataDidBecomeAvailableNotification
        #else
        Notification.Name("BighelpProtectedDataDidBecomeAvailable")
        #endif
    }()
}

@inline(__always)
func requireBighelpProtectedData(
    _ availability: any BighelpProtectedDataAvailabilityProviding
) throws {
    guard availability.isProtectedDataAvailable else {
        throw BighelpLocalPersistenceError.protectedDataUnavailable
    }
}

enum BighelpLocalProtectionClass: Equatable, Sendable {
    case backgroundCompatible
    case privateVisual
}

protocol BighelpLocalFileProtecting: Sendable {
    func prepareDirectory(
        _ directory: URL,
        protection: BighelpLocalProtectionClass,
        fileManager: FileManager
    ) throws
    func write(
        _ data: Data,
        to file: URL,
        protection: BighelpLocalProtectionClass
    ) throws
    func apply(
        _ protection: BighelpLocalProtectionClass,
        to file: URL,
        fileManager: FileManager
    ) throws
}

struct BighelpLocalFileProtector: BighelpLocalFileProtecting {
    static func fileProtection(for protection: BighelpLocalProtectionClass) -> FileProtectionType {
        switch protection {
        case .backgroundCompatible: .completeUntilFirstUserAuthentication
        case .privateVisual: .complete
        }
    }

    static func writingOptions(for protection: BighelpLocalProtectionClass) -> Data.WritingOptions {
        switch protection {
        case .backgroundCompatible: .completeFileProtectionUntilFirstUserAuthentication
        case .privateVisual: .completeFileProtection
        }
    }

    func prepareDirectory(
        _ directory: URL,
        protection: BighelpLocalProtectionClass,
        fileManager: FileManager
    ) throws {
        let fileProtection = Self.fileProtection(for: protection)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: fileProtection]
        )
        try fileManager.setAttributes(
            [.protectionKey: fileProtection],
            ofItemAtPath: directory.bighelpFileSystemPath
        )
        try Self.excludeFromBackup(directory)
    }

    func write(
        _ data: Data,
        to file: URL,
        protection: BighelpLocalProtectionClass
    ) throws {
        try data.write(
            to: file,
            options: [.withoutOverwriting, Self.writingOptions(for: protection)]
        )
        try Self.excludeFromBackup(file)
    }

    func apply(
        _ protection: BighelpLocalProtectionClass,
        to file: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.setAttributes(
            [.protectionKey: Self.fileProtection(for: protection)],
            ofItemAtPath: file.bighelpFileSystemPath
        )
        try Self.excludeFromBackup(file)
    }

    private static func excludeFromBackup(_ file: URL) throws {
        try (file as NSURL).setResourceValue(
            true,
            forKey: URLResourceKey.isExcludedFromBackupKey
        )
    }
}

/// Persists the one pending encrypted Link frame outside of UserDefaults.
/// UserDefaults lives in the backup-eligible preferences domain and cannot
/// mark one value as excluded from device backups.
final class BighelpProtectedSocketStateStore: BighelpLinkSocketStateStoring {
    private let directory: URL
    private let fileURL: URL
    private let legacyFileURLs: [URL]
    private let defaults: UserDefaults
    private let legacyDefaultsKey: String
    private let fileManager: FileManager
    private let fileProtection: any BighelpLocalFileProtecting
    private let protectedDataAvailability: any BighelpProtectedDataAvailabilityProviding
    private var pendingSnapshot: BighelpLinkSocketStateSnapshot?
    private(set) var lastPersistenceError: BighelpLocalPersistenceError?

    init(
        deviceID: String,
        dataDirectory: URL,
        legacyDataDirectories: [URL] = [],
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        fileProtection: any BighelpLocalFileProtecting = BighelpLocalFileProtector(),
        protectedDataAvailability: any BighelpProtectedDataAvailabilityProviding = BighelpSystemProtectedDataAvailability()
    ) {
        let currentDirectory = dataDirectory.standardizedFileURL
        directory = currentDirectory
        let safeDeviceID = BighelpLinkBase64URL.encode(Data(deviceID.utf8))
        fileURL = directory.appending(
            path: "link-socket-\(safeDeviceID)-v1.json",
            directoryHint: .notDirectory
        )
        legacyFileURLs = legacyDataDirectories
            .map(\.standardizedFileURL)
            .filter { $0 != currentDirectory }
            .map {
                $0.appending(
                    path: "link-socket-\(safeDeviceID)-v1.json",
                    directoryHint: .notDirectory
                )
            }
        self.defaults = defaults
        legacyDefaultsKey = "loopdy.link.socket.v1.\(deviceID)"
        self.fileManager = fileManager
        self.fileProtection = fileProtection
        self.protectedDataAvailability = protectedDataAvailability
        pendingSnapshot = nil
        lastPersistenceError = nil
    }

    var snapshot: BighelpLinkSocketStateSnapshot {
        get {
            let current = loadSnapshot(from: fileURL)
            let legacy = legacyFileURLs.compactMap { url in
                loadSnapshot(from: url).map { (url, $0) }
            }
            if let value = Self.merge(
                current: current,
                legacy: legacy.map(\.1)
            ) {
                migrateDirectorySnapshotsIfNeeded(
                    value,
                    legacyFiles: legacy.map(\.0)
                )
                return value
            }
            return migrateLegacySnapshot()
        }
        set {
            pendingSnapshot = newValue
            do {
                try save(newValue)
                defaults.removeObject(forKey: legacyDefaultsKey)
                pendingSnapshot = nil
                lastPersistenceError = nil
            } catch let error as BighelpLocalPersistenceError {
                lastPersistenceError = error
            } catch {
                lastPersistenceError = nil
            }
        }
    }

    /// Retries the newest pending socket snapshot after protected data becomes
    /// available. The equality check prevents a delayed notification from
    /// overwriting a newer socket revision.
    @MainActor
    func retryPendingSnapshotAfterProtectedDataBecomesAvailable(
        in notificationCenter: NotificationCenter = .default
    ) async {
        guard let pendingSnapshot else { return }
        for await _ in notificationCenter.notifications(
            named: BighelpProtectedDataAvailabilityNotification.didBecomeAvailable
        ) {
            guard protectedDataAvailability.isProtectedDataAvailable else { continue }
            guard self.pendingSnapshot == pendingSnapshot else { return }
            do {
                try save(pendingSnapshot)
                guard self.pendingSnapshot == pendingSnapshot else { return }
                self.pendingSnapshot = nil
                lastPersistenceError = nil
                defaults.removeObject(forKey: legacyDefaultsKey)
            } catch let error as BighelpLocalPersistenceError {
                lastPersistenceError = error
            } catch {
                lastPersistenceError = nil
            }
            return
        }
    }

    private func loadSnapshot(from url: URL) -> BighelpLinkSocketStateSnapshot? {
        guard
            fileManager.fileExists(atPath: url.bighelpFileSystemPath),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(BighelpLinkSocketStateSnapshot.self, from: data)
    }

    private static func merge(
        current: BighelpLinkSocketStateSnapshot?,
        legacy: [BighelpLinkSocketStateSnapshot]
    ) -> BighelpLinkSocketStateSnapshot? {
        guard var merged = current ?? legacy.first else { return nil }
        let supplements = current == nil ? legacy.dropFirst() : legacy[...]
        for snapshot in supplements {
            merged.outboundSequence = max(
                merged.outboundSequence,
                snapshot.outboundSequence
            )
            merged.lastReceivedSequence = max(
                merged.lastReceivedSequence,
                snapshot.lastReceivedSequence
            )
            for (senderDeviceID, sequence) in snapshot.receivedSequences {
                merged.receivedSequences[senderDeviceID] = max(
                    merged.receivedSequences[senderDeviceID] ?? 0,
                    sequence
                )
            }
        }
        return merged
    }

    private func migrateDirectorySnapshotsIfNeeded(
        _ snapshot: BighelpLinkSocketStateSnapshot,
        legacyFiles: [URL]
    ) {
        guard !legacyFiles.isEmpty else {
            if ensureBackupExcluded() {
                defaults.removeObject(forKey: legacyDefaultsKey)
            }
            return
        }
        do {
            try save(snapshot)
            defaults.removeObject(forKey: legacyDefaultsKey)
            for legacyFile in legacyFiles {
                try fileManager.removeItem(at: legacyFile)
            }
        } catch {
            // Keep every successfully decoded legacy file until the merged
            // protected snapshot is durably written.
        }
    }

    private func migrateLegacySnapshot() -> BighelpLinkSocketStateSnapshot {
        guard
            let data = defaults.data(forKey: legacyDefaultsKey),
            let value = try? JSONDecoder().decode(
                BighelpLinkSocketStateSnapshot.self,
                from: data
            )
        else { return BighelpLinkSocketStateSnapshot() }
        do {
            try save(value)
            defaults.removeObject(forKey: legacyDefaultsKey)
        } catch { }
        return value
    }

    private func ensureBackupExcluded() -> Bool {
        if (try? fileURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup) == true {
            return true
        }
        do {
            try fileProtection.apply(
                .backgroundCompatible,
                to: fileURL,
                fileManager: fileManager
            )
            return (try? fileURL.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup) == true
        } catch {
            return false
        }
    }

    private func save(_ snapshot: BighelpLinkSocketStateSnapshot) throws {
        try requireBighelpProtectedData(protectedDataAvailability)
        try fileProtection.prepareDirectory(
            directory,
            protection: .backgroundCompatible,
            fileManager: fileManager
        )
        let data = try JSONEncoder().encode(snapshot)
        let temporaryURL = directory.appending(
            path: ".\(UUID().uuidString).socket-state.tmp",
            directoryHint: .notDirectory
        )
        try fileProtection.write(
            data,
            to: temporaryURL,
            protection: .backgroundCompatible
        )
        do {
            if fileManager.fileExists(atPath: fileURL.bighelpFileSystemPath) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
            try fileProtection.apply(
                .backgroundCompatible,
                to: fileURL,
                fileManager: fileManager
            )
            guard (try? fileURL.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup) == true else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}

protocol BighelpLocalAccountDataErasing: AnyObject {
    func erase() throws
}

protocol BighelpLocalAccountSecretErasing: AnyObject {
    func erase() throws
}

final class BighelpNoopLocalAccountSecretEraser: BighelpLocalAccountSecretErasing {
    func erase() throws { }
}

final class BighelpLocalAccountKeychainSecretEraser: BighelpLocalAccountSecretErasing {
    private struct SecretCoordinate {
        let service: String
        let account: String?
        let usesSharedAccessGroup: Bool
    }

    private let accessGroup: String?
    private let coordinates = [
        SecretCoordinate(service: "app.loopdy.mobile.notification-host-trust", account: nil, usesSharedAccessGroup: true),
        SecretCoordinate(service: "app.loopdy.mobile.managed-notification-activities", account: nil, usesSharedAccessGroup: false),
        SecretCoordinate(
            service: "app.loopdy.mobile.notification-trust",
            account: "relay-sender-key-set-v1",
            usesSharedAccessGroup: true
        ),
        SecretCoordinate(
            service: "app.loopdy.mobile.link-push",
            account: "p256-agreement-v1",
            usesSharedAccessGroup: true
        ),
        SecretCoordinate(
            service: "app.loopdy.mobile.hermes",
            account: "active-v1",
            usesSharedAccessGroup: false
        ),
    ]

    init(accessGroup: String? = BighelpNotificationKeychainAccess.group) {
        self.accessGroup = accessGroup
    }

    func erase() throws {
        var firstFailure: OSStatus?
        for coordinate in coordinates {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: coordinate.service,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            ]
            if let account = coordinate.account { query[kSecAttrAccount as String] = account }
            if coordinate.usesSharedAccessGroup, let accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound, firstFailure == nil {
                firstFailure = status
            } else if status == errSecSuccess || status == errSecItemNotFound {
                var readback = query
                readback[kSecReturnAttributes as String] = true
                readback[kSecMatchLimit as String] = kSecMatchLimitOne
                var remainingItem: CFTypeRef?
                let remaining = SecItemCopyMatching(readback as CFDictionary, &remainingItem)
                if remaining != errSecItemNotFound, firstFailure == nil {
                    firstFailure = remaining == errSecSuccess ? errSecNotAvailable : remaining
                }
            }
        }
        if let firstFailure {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(firstFailure))
        }
    }
}

enum BighelpMarketplaceRetirementMigration {
    static let defaultsKey = "loopdy.migrations.marketplace-retirement-v1"

    static func run(
        dataDirectory: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        guard !defaults.bool(forKey: defaultsKey) else { return }
        let root = dataDirectory.standardizedFileURL
        guard root.isFileURL,
              root.pathComponents.count >= 3,
              root.bighelpFileSystemPath != "/",
              root.bighelpFileSystemPath != NSHomeDirectory()
        else { throw CocoaError(.fileWriteNoPermission) }
        let marketplace = root.appending(path: "marketplace", directoryHint: .isDirectory)
        guard marketplace.deletingLastPathComponent().standardizedFileURL == root else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if fileManager.fileExists(atPath: marketplace.bighelpFileSystemPath) {
            try fileManager.removeItem(at: marketplace)
        }
        defaults.set(true, forKey: defaultsKey)
    }
}

final class BighelpNoopLocalAccountDataEraser: BighelpLocalAccountDataErasing {
    func erase() throws { }
}

final class BighelpLocalAccountDataEraser: BighelpLocalAccountDataErasing {
    private static let exactDefaultsKeys: Set<String> = [
        "loopdy.demo.userIdentity",
        "loopdy.demo.selectedAgentID",
        "loopdy.models.recent",
        "loopdy.models.pinned",
        "loopdy.agents.primary-agent-id.by-host",
        "loopdy.agents.pinned-agent-ids.by-host",
        "loopdy.agents.unpinned-agent-ids.by-host",
        "loopdy.link.push-registration-revision",
        "loopdy.link.selected-host-id",
        "loopdy.link.primary-host-id",
        BighelpHostCacheMigration.defaultsKey,
        BighelpWorkspaceAdmissionStore.defaultsKey,
    ]
    private static let defaultsKeyPrefixes = [
        BighelpCardInteractionStore.defaultsKeyPrefix,
        SessionAppearanceStore.defaultsKeyPrefix,
        "loopdy.link.socket.v1.",
        "loopdy.device-tools.v1.",
    ]

    private let dataDirectories: [URL]
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let secretEraser: any BighelpLocalAccountSecretErasing

    init(
        dataDirectory: URL,
        additionalDataDirectories: [URL] = [],
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        secretEraser: any BighelpLocalAccountSecretErasing = BighelpNoopLocalAccountSecretEraser()
    ) {
        var seenPaths = Set<String>()
        dataDirectories = ([dataDirectory] + additionalDataDirectories)
            .map(\.standardizedFileURL)
            .filter { seenPaths.insert($0.bighelpFileSystemPath).inserted }
        self.defaults = defaults
        self.fileManager = fileManager
        self.secretEraser = secretEraser
    }

    func erase() throws {
        var removalError: (any Error)?
        for dataDirectory in dataDirectories {
            do {
                try removeDataDirectoryIfPresent(dataDirectory)
            } catch where removalError == nil {
                removalError = error
            } catch { }
        }

        for key in defaults.dictionaryRepresentation().keys where isAccountScoped(key) {
            defaults.removeObject(forKey: key)
        }

        do {
            try secretEraser.erase()
        } catch where removalError == nil {
            removalError = error
        } catch { }

        if let removalError { throw removalError }
    }

    private func removeDataDirectoryIfPresent(_ dataDirectory: URL) throws {
        guard isNarrowFileTarget(dataDirectory) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard fileManager.fileExists(atPath: dataDirectory.bighelpFileSystemPath) else { return }
        try fileManager.removeItem(at: dataDirectory)
    }

    private func isAccountScoped(_ key: String) -> Bool {
        Self.exactDefaultsKeys.contains(key)
            || Self.defaultsKeyPrefixes.contains(where: key.hasPrefix)
    }

    private func isNarrowFileTarget(_ target: URL) -> Bool {
        guard target.isFileURL else { return false }
        let path = target.bighelpFileSystemPath
        guard path != "/", path != NSHomeDirectory() else { return false }
        return target.pathComponents.count >= 4 && !target.lastPathComponent.isEmpty
    }
}
