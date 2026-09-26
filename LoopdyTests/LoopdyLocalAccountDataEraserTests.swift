import Foundation
import Security
import Testing
@testable import Loopdy

struct LoopdyLocalAccountDataEraserTests {
    @Test func migratesLegacySocketStateBeforeRemovingBackupEligibleDefaults() throws {
        let suiteName = "LoopdyLocalAccountDataEraserTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LoopdyLocalAccountDataEraserTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyKey = "loopdy.link.socket.v1.device-1"
        let pending = LoopdyLinkSocketStateSnapshot(
            outboundSequence: 4,
            pendingFrame: "encrypted-frame",
            receivedSequences: ["host": 9],
            lastReceivedSequence: 9
        )
        defaults.set(try JSONEncoder().encode(pending), forKey: legacyKey)

        let store = LoopdyProtectedSocketStateStore(
            deviceID: "device-1",
            dataDirectory: directory,
            defaults: defaults
        )

        #expect(store.snapshot == pending)
        #expect(defaults.object(forKey: legacyKey) == nil)
    }

    @Test func migrationRetainsLegacyStateWhenProtectedPersistenceFails() throws {
        let suiteName = "LoopdyLocalAccountDataEraserTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LoopdyLocalAccountDataEraserTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyKey = "loopdy.link.socket.v1.device-1"
        let pending = LoopdyLinkSocketStateSnapshot(
            outboundSequence: 4,
            pendingFrame: "encrypted-frame",
            receivedSequences: ["host": 9],
            lastReceivedSequence: 9
        )
        defaults.set(try JSONEncoder().encode(pending), forKey: legacyKey)
        let protection = FailingSocketFileProtector(failOnApply: true)

        let firstStore = LoopdyProtectedSocketStateStore(
            deviceID: "device-1",
            dataDirectory: directory,
            defaults: defaults,
            fileProtection: protection
        )
        #expect(firstStore.snapshot == pending)
        #expect(defaults.object(forKey: legacyKey) != nil)
        let secondStore = LoopdyProtectedSocketStateStore(
            deviceID: "device-1",
            dataDirectory: directory,
            defaults: defaults,
            fileProtection: protection
        )

        #expect(secondStore.snapshot == pending)
        #expect(defaults.object(forKey: legacyKey) != nil)
    }

    @Test func pendingSocketStateRoundTripsThroughBackupExcludedProtectedStorage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LoopdyLocalAccountDataEraserTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pending = LoopdyLinkSocketStateSnapshot(
            outboundSequence: 4,
            pendingFrame: "encrypted-frame",
            receivedSequences: ["host": 9],
            lastReceivedSequence: 9
        )
        let store = LoopdyProtectedSocketStateStore(
            deviceID: "device-1",
            dataDirectory: directory
        )
        store.snapshot = pending

        let restored = LoopdyProtectedSocketStateStore(
            deviceID: "device-1",
            dataDirectory: directory
        )
        #expect(restored.snapshot == pending)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isExcludedFromBackupKey],
            options: []
        )
        let stateFile = try #require(files.first)
        let values = try stateFile.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func lockedSocketSaveDoesNotReplaceExistingProtectedState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LoopdyLocalAccountDataEraserTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let availability = TestProtectedDataAvailability(isAvailable: true)
        let store = LoopdyProtectedSocketStateStore(
            deviceID: "device-1",
            dataDirectory: directory,
            protectedDataAvailability: availability
        )
        let original = LoopdyLinkSocketStateSnapshot(
            outboundSequence: 4,
            pendingFrame: "original-frame",
            receivedSequences: ["host": 9],
            lastReceivedSequence: 9
        )
        store.snapshot = original
        let stateFile = try #require(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ).first
        )
        let originalData = try Data(contentsOf: stateFile)
        availability.isProtectedDataAvailable = false

        store.snapshot = LoopdyLinkSocketStateSnapshot(
            outboundSequence: 5,
            pendingFrame: "replacement-frame",
            receivedSequences: ["host": 10],
            lastReceivedSequence: 10
        )

        #expect(store.lastPersistenceError == .protectedDataUnavailable)
        #expect(try Data(contentsOf: stateFile) == originalData)
    }

    @Test func migratesFormerProductionDirectoryWithoutLosingNewerSequenceWatermarks() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LoopdyLocalAccountDataEraserTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let currentDirectory = root.appending(path: "Loopdy", directoryHint: .isDirectory)
        let formerDirectory = root.appending(path: "LoopdyDemo", directoryHint: .isDirectory)
        let currentPendingFrame = "current-encrypted-frame"
        let current = LoopdyLinkSocketStateSnapshot(
            outboundSequence: 618,
            pendingFrame: currentPendingFrame,
            pendingRelayReadyCiphertext: "current-ready-ciphertext",
            pendingRelayReadyFingerprint: "current-ready-fingerprint",
            pendingRelayReadyAcknowledgementRevision: 3,
            relayReadyInFlightFingerprint: "current-in-flight",
            lastRelayReadyFingerprint: "current-last-ready",
            receivedSequences: ["current-host": 734, "current-only": 8],
            lastReceivedSequence: 736
        )
        let former = LoopdyLinkSocketStateSnapshot(
            outboundSequence: 619,
            receivedSequences: ["current-host": 745, "former-only": 27],
            lastReceivedSequence: 745
        )
        LoopdyProtectedSocketStateStore(
            deviceID: "device-1",
            dataDirectory: currentDirectory
        ).snapshot = current
        LoopdyProtectedSocketStateStore(
            deviceID: "device-1",
            dataDirectory: formerDirectory
        ).snapshot = former

        let migratedStore = LoopdyProtectedSocketStateStore(
            deviceID: "device-1",
            dataDirectory: currentDirectory,
            legacyDataDirectories: [formerDirectory]
        )

        let migrated = migratedStore.snapshot
        #expect(migrated.outboundSequence == 619)
        #expect(migrated.pendingFrame == currentPendingFrame)
        #expect(migrated.pendingRelayReadyCiphertext == "current-ready-ciphertext")
        #expect(migrated.pendingRelayReadyFingerprint == "current-ready-fingerprint")
        #expect(migrated.pendingRelayReadyAcknowledgementRevision == 3)
        #expect(migrated.relayReadyInFlightFingerprint == "current-in-flight")
        #expect(migrated.lastRelayReadyFingerprint == "current-last-ready")
        #expect(migrated.receivedSequences == [
            "current-host": 745,
            "current-only": 8,
            "former-only": 27,
        ])
        #expect(migrated.lastReceivedSequence == 745)
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: formerDirectory,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
        #expect(
            LoopdyProtectedSocketStateStore(
                deviceID: "device-1",
                dataDirectory: currentDirectory
            ).snapshot == migrated
        )
    }

    @Test func protectedLocalFilesAndDirectoriesAreExcludedFromDeviceBackups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LoopdyLocalAccountDataEraserTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "pending-frame.json")
        let protector = LoopdyLocalFileProtector()

        try protector.prepareDirectory(
            directory,
            protection: .backgroundCompatible,
            fileManager: .default
        )
        try protector.write(
            Data("encrypted pending frame".utf8),
            to: file,
            protection: .backgroundCompatible
        )
        try protector.apply(.backgroundCompatible, to: file, fileManager: .default)

        let directoryValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        let fileValues = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(directoryValues.isExcludedFromBackup == true)
        #expect(fileValues.isExcludedFromBackup == true)
    }

    @Test func corruptRepositoryRecoveryBackupsRemainExcludedFromDeviceBackups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LoopdyLocalAccountDataEraserTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: directory.appending(path: "sessions-v1.json"))

        let repository = DemoRepository<[String]>(
            directory: directory,
            name: "sessions",
            seed: []
        )

        _ = try repository.load()

        let backupURL = try #require(repository.lastRecoveryBackupURL)
        let values = try backupURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func erasesAccountFilesAndIdentifiersButRetainsAppearancePreferences() throws {
        let suiteName = "LoopdyLocalAccountDataEraserTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LoopdyLocalAccountDataEraserTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let formerDirectory = directory
            .deletingLastPathComponent()
            .appending(path: "\(directory.lastPathComponent)-former", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { try? FileManager.default.removeItem(at: formerDirectory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: formerDirectory,
            withIntermediateDirectories: true
        )
        try Data("private chat".utf8).write(to: directory.appending(path: "sessions-v1.json"))
        try Data("former socket state".utf8).write(
            to: formerDirectory.appending(path: "link-socket-v1.json")
        )
        defaults.set(Data("identity".utf8), forKey: "loopdy.demo.userIdentity")
        defaults.set("agent-1", forKey: "loopdy.demo.selectedAgentID")
        defaults.set(Data("socket".utf8), forKey: "loopdy.link.socket.v1.device-1")
        defaults.set(Data("models".utf8), forKey: "loopdy.models.recent")
        let pinKeys = ["loopdy.models.pinned", "loopdy.agents.primary-agent-id.by-host",
                       "loopdy.agents.pinned-agent-ids.by-host", "loopdy.agents.unpinned-agent-ids.by-host"]
        for key in pinKeys { defaults.set(Data("private-preference".utf8), forKey: key) }
        defaults.set(4, forKey: "loopdy.link.push-registration-revision")
        defaults.set("host-a", forKey: "loopdy.link.selected-host-id")
        defaults.set("host-b", forKey: "loopdy.link.primary-host-id")
        defaults.set(Data("admission".utf8), forKey: "loopdy.link.workspace-admission.v1")
        defaults.set("dark", forKey: "loopdy.settings.appearance")
        defaults.set(true, forKey: PermissionsOnboardingCompletion.storageKey)
        let secretEraser = AccountSecretEraserStub()

        try LoopdyLocalAccountDataEraser(
            dataDirectory: directory,
            additionalDataDirectories: [formerDirectory],
            defaults: defaults,
            secretEraser: secretEraser
        ).erase()

        #expect(!FileManager.default.fileExists(atPath: directory.path()))
        #expect(!FileManager.default.fileExists(atPath: formerDirectory.path()))
        #expect(defaults.object(forKey: "loopdy.demo.userIdentity") == nil)
        #expect(defaults.object(forKey: "loopdy.demo.selectedAgentID") == nil)
        #expect(defaults.object(forKey: "loopdy.link.socket.v1.device-1") == nil)
        #expect(defaults.object(forKey: "loopdy.models.recent") == nil)
        for key in pinKeys { #expect(defaults.object(forKey: key) == nil) }
        #expect(defaults.object(forKey: "loopdy.link.push-registration-revision") == nil)
        #expect(defaults.object(forKey: "loopdy.link.selected-host-id") == nil)
        #expect(defaults.object(forKey: "loopdy.link.primary-host-id") == nil)
        #expect(defaults.object(forKey: "loopdy.link.workspace-admission.v1") == nil)
        #expect(defaults.string(forKey: "loopdy.settings.appearance") == "dark")
        #expect(defaults.bool(forKey: PermissionsOnboardingCompletion.storageKey))
        #expect(secretEraser.eraseCount == 1)
    }

    @Test @MainActor func erasesLegacyDirectHermesGatewayCredentialFromMigratedInstall() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.loopdy.mobile.hermes",
            kSecAttrAccount as String: "active-v1",
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(query as CFDictionary)
        defer { SecItemDelete(query as CFDictionary) }
        var insertion = query
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insertion[kSecValueData as String] = try JSONSerialization.data(withJSONObject: [
            "version": 1, "baseURL": "https://hermes.test", "token": "fixture-token",
        ])
        #expect(SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess)
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess)
        try LoopdyLocalAccountKeychainSecretEraser().erase()
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
    }
}

struct LoopdyMarketplaceRetirementMigrationTests {
    @Test func purgesRetiredMarketplaceDataOnceWithoutRemovingCustomThemes() throws {
        let suiteName = "LoopdyMarketplaceRetirementMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LoopdyMarketplaceRetirementMigrationTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marketplace = directory.appending(path: "marketplace", directoryHint: .isDirectory)
        let customThemeLogos = directory.appending(path: "custom-theme-logos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: marketplace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customThemeLogos, withIntermediateDirectories: true)
        try Data("private account receipt".utf8).write(
            to: marketplace.appending(path: "install-receipts-v1.json")
        )
        try Data("retired catalog".utf8).write(
            to: marketplace.appending(path: "catalog-cache-v1.json")
        )
        let logo = Data([0x89, 0x50, 0x4E, 0x47])
        try logo.write(to: customThemeLogos.appending(path: "saved-theme.png"))
        let themes = Data("{\"schemaVersion\":1,\"themes\":[]}".utf8)
        defaults.set(themes, forKey: "loopdy.appearance.customThemes")
        defaults.set("custom.saved-theme", forKey: "loopdy.appearance.theme")

        try LoopdyMarketplaceRetirementMigration.run(
            dataDirectory: directory,
            defaults: defaults
        )

        #expect(!FileManager.default.fileExists(atPath: marketplace.path))
        #expect(try Data(contentsOf: customThemeLogos.appending(path: "saved-theme.png")) == logo)
        #expect(defaults.data(forKey: "loopdy.appearance.customThemes") == themes)
        #expect(defaults.string(forKey: "loopdy.appearance.theme") == "custom.saved-theme")
        #expect(defaults.bool(forKey: LoopdyMarketplaceRetirementMigration.defaultsKey))

        try FileManager.default.createDirectory(at: marketplace, withIntermediateDirectories: true)
        try Data("new sentinel".utf8).write(to: marketplace.appending(path: "sentinel"))
        try LoopdyMarketplaceRetirementMigration.run(
            dataDirectory: directory,
            defaults: defaults
        )
        #expect(FileManager.default.fileExists(atPath: marketplace.appending(path: "sentinel").path))
    }
}

private final class AccountSecretEraserStub: LoopdyLocalAccountSecretErasing {
    private(set) var eraseCount = 0

    func erase() throws {
        eraseCount += 1
    }
}

private final class TestProtectedDataAvailability: LoopdyProtectedDataAvailabilityProviding, @unchecked Sendable {
    var isProtectedDataAvailable: Bool

    init(isAvailable: Bool) {
        isProtectedDataAvailable = isAvailable
    }
}

private final class FailingSocketFileProtector: LoopdyLocalFileProtecting, @unchecked Sendable {
    let failOnApply: Bool

    init(failOnApply: Bool) {
        self.failOnApply = failOnApply
    }

    func prepareDirectory(
        _ directory: URL,
        protection: LoopdyLocalProtectionClass,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(
        _ data: Data,
        to file: URL,
        protection: LoopdyLocalProtectionClass
    ) throws {
        try data.write(to: file, options: .withoutOverwriting)
    }

    func apply(
        _ protection: LoopdyLocalProtectionClass,
        to file: URL,
        fileManager: FileManager
    ) throws {
        if failOnApply { throw CocoaError(.fileWriteNoPermission) }
    }
}
