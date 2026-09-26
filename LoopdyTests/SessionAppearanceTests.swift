import Foundation
import Testing
import UIKit
@testable import Loopdy

@MainActor
struct SessionAppearanceTests {
    @Test func presetsPersistResetAndStayWithinExactScope() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.makeStore()
        try first.apply(choice: .sky, dimming: 0.2)
        #expect(fixture.makeStore().snapshot.choice == .sky)
        for dimension in ["account", "host", "profile", "session"] {
            let scope = try SessionAppearanceScope(accountID: dimension == "account" ? "other" : "account",
                hostID: dimension == "host" ? "other" : "host", profileID: dimension == "profile" ? "other" : "profile",
                sessionID: dimension == "session" ? "other" : "session")
            #expect(fixture.makeStore(scope: scope).snapshot == .inherited)
        }
        try first.apply(choice: .inherit, dimming: 0)
        #expect(first.snapshot == .inherited)
        #expect(fixture.makeStore().snapshot == .inherited)
    }

    @Test func canonicallyEquivalentUnicodeScopesRemainDifferentOwners() throws {
        let a = try SessionAppearanceScope(accountID: "account", hostID: "host", profileID: "profile", sessionID: "\u{00e9}")
        let b = try SessionAppearanceScope(accountID: "account", hostID: "host", profileID: "profile", sessionID: "e\u{0301}")
        #expect(a != b)
        #expect(Set([a, b]).count == 2)
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.makeStore(scope: a).apply(choice: .violet, dimming: 0)
        #expect(fixture.makeStore(scope: b).snapshot == .inherited)
    }

    @Test func photoPersistsDecodesOnceAndHasProtection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let manager = RecordingProtectionFileManager()
        let store = fixture.makeStore(fileManager: manager)
        let prepared = try photo()
        try store.apply(choice: .photo, dimming: 0.3, preparedPhoto: prepared)
        let url = try #require(store.snapshot.photoURL)
        #expect(try Data(contentsOf: url) == prepared.data)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
        let protectionName = (protection as? FileProtectionType)?.rawValue ?? (protection as? String)
        #expect(manager.requestedCompleteProtection(at: url.path))
        #if targetEnvironment(simulator)
        // Simulator omits this attribute and cannot prove device encryption.
        if let protectionName { #expect(protectionName == FileProtectionType.complete.rawValue) }
        #else
        #expect(protectionName == FileProtectionType.complete.rawValue)
        #endif
        let restored = fixture.makeStore()
        await waitForPhoto(restored)
        let decoded = try #require(restored.snapshot.decodedPhoto)
        #expect(restored.snapshot.choice == .photo)
        for _ in 0..<5 { #expect(restored.snapshot.decodedPhoto?.image === decoded.image) }
        try restored.apply(choice: .graphite, dimming: 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(fixture.makeStore().snapshot.choice == .graphite)
    }

    @Test func corruptPhotoCannotBeRestoredAsSelectedBackground() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        try store.apply(choice: .photo, dimming: 0, preparedPhoto: photo())
        let url = try #require(store.snapshot.photoURL)
        try Data([0, 1, 2]).write(to: url)
        let restored = fixture.makeStore()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while restored.preference != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(restored.snapshot == .inherited)
        #expect(restored.preference == nil)
    }

    @Test func retiredStoreCannotWriteOrCompleteOldValidation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        try store.apply(choice: .photo, dimming: 0, preparedPhoto: photo())
        let reloading = fixture.makeStore()
        reloading.retire()
        #expect(throws: SessionAppearanceStoreError.self) { try reloading.apply(choice: .sky, dimming: 0) }
        #expect(throws: SessionAppearanceStoreError.self) { try reloading.erase() }
        let restored = fixture.makeStore()
        await waitForPhoto(restored)
        #expect(restored.snapshot.choice == .photo)
    }

    @Test func erasureFailureDoesNotSplitMemoryAndPersistentPreference() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let manager = RejectRemovalFileManager()
        let store = fixture.makeStore(fileManager: manager)
        try store.apply(choice: .photo, dimming: 0, preparedPhoto: photo())
        #expect(throws: (any Error).self) { try store.erase() }
        let restored = fixture.makeStore(fileManager: manager)
        #expect(restored.preference == store.preference)
    }

    @Test func symlinkedPhotoRootCannotWriteOutsideItsContainer() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.appending(path: "outside")
        let link = fixture.root.appending(path: "photo-link")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = SessionAppearanceStore(scope: fixture.scope, defaults: fixture.defaults, photoDirectory: link)
        #expect(throws: SessionAppearanceStoreError.self) { try store.apply(choice: .photo, dimming: 0, preparedPhoto: photo()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func ineligibleEntriesCannotPermanentlyStarveOrphanCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        try store.apply(choice: .photo, dimming: 0, preparedPhoto: photo())
        let directory = try #require(store.snapshot.photoURL).deletingLastPathComponent()
        for n in 0..<130 { try Data().write(to: directory.appending(path: String(format: "000-%03d.txt", n))) }
        var orphans: [URL] = []
        for n in 0..<150 {
            let url = directory.appending(path: String(format: "aaaaaaaa-aaaa-aaaa-aaaa-%012d.jpg", n))
            try Data([1]).write(to: url)
            orphans.append(url)
        }
        for _ in 0..<3 { store.reload(); await waitForPhoto(store) }
        #expect(orphans.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(store.snapshot.choice == .photo)
    }

    private func photo() throws -> SessionAppearancePreparedPhoto {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        return try SessionAppearanceStore.preparePhoto(#require(image.pngData()))
    }

    private func waitForPhoto(_ store: SessionAppearanceStore) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while store.snapshot.decodedPhoto == nil && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @MainActor private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let scope: SessionAppearanceScope
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            suite = "session-appearance-tests." + UUID().uuidString
            defaults = try #require(UserDefaults(suiteName: suite))
            scope = try SessionAppearanceScope(accountID: "account", hostID: "host", profileID: "profile", sessionID: "session")
        }
        func makeStore(scope other: SessionAppearanceScope? = nil, fileManager: FileManager = .default) -> SessionAppearanceStore {
            SessionAppearanceStore(scope: other ?? scope, defaults: defaults,
                photoDirectory: root.appending(path: "photos"), fileManager: fileManager)
        }
        func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    }
}

private final class RecordingProtectionFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try super.setAttributes(attributes, ofItemAtPath: path)
        if attributes[.protectionKey] as? FileProtectionType == .complete {
            lock.lock(); paths.insert(path); lock.unlock()
        }
    }
    func requestedCompleteProtection(at path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return paths.contains(path)
    }
}

private final class RejectRemovalFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}
