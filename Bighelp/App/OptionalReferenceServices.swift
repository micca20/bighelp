import Foundation
import Observation
import SwiftUI

/// One optional-provider owner for the app. Construction never opens a vault,
/// reads document storage or contacts either provider.
@MainActor
@Observable
final class OptionalReferenceServices {
    let wiki: WikiStore
    let drafts = WikiDraftStore(owner: nil)
    private(set) var lifecycleFailure: String?
    let github: GitHubConnectionStore
    private(set) var wikiClient: WikiLinkClient?
    @ObservationIgnored private let workspace: BighelpLinkWorkspaceClient?
    @ObservationIgnored private var currentOwner: @MainActor () -> WikiOwner? = { nil }
    @ObservationIgnored private var erasureAccountID: String?
    @ObservationIgnored private var erasureWikiAccountID: String?
    @ObservationIgnored private var legacyWikiAccountID: String?
    @ObservationIgnored private let wikiPersistence: any WikiPersistence
    @ObservationIgnored private var wikiMigrationFailed = false
    @ObservationIgnored private var wikiMigration: WikiAuthenticatedMigration?
    private static let migrationFailure = "Saved Wiki folders could not be upgraded on this device. Retry before signing out."
    var activeOwner: WikiOwner? { currentOwner() }

    init(workspace: BighelpLinkWorkspaceClient? = nil, configuration: GitHubConfiguration?,
         wikiPersistence: (any WikiPersistence)? = nil) {
        self.workspace = workspace
        let persistence = wikiPersistence ?? WikiLocalPersistence()
        self.wikiPersistence = persistence
        wiki = WikiStore(owner: nil, client: nil, persistence: persistence)
        github = GitHubConnectionStore(ownerID: nil, configuration: configuration)
    }

    func bind(owner: WikiOwner?, credentials: BighelpLinkRuntimeCredentials? = nil, accountID: String?,
              currentOwner: @escaping @MainActor () -> WikiOwner?) {
        self.currentOwner = currentOwner
        let previousMigration = wikiMigration
        let previousMigrationFailed = wikiMigrationFailed
        if let credentials {
            erasureWikiAccountID = credentials.wikiAccountID
            legacyWikiAccountID = credentials.deviceID
            wikiMigration = nil
            do {
                let migration = try WikiAuthenticatedMigration(credentials: credentials)
                let needsMigration = wikiMigrationFailed
                    || previousMigration?.accountID != migration.accountID
                    || previousMigration?.deviceID != migration.deviceID
                wikiMigration = migration
                if needsMigration { try wikiPersistence.migrateAuthenticatedLegacyFolders(migration) }
                wikiMigrationFailed = false
                if lifecycleFailure == Self.migrationFailure { lifecycleFailure = nil }
            } catch {
                wikiMigrationFailed = true
                lifecycleFailure = Self.migrationFailure
            }
        } else if let owner {
            if erasureWikiAccountID != owner.accountID {
                wikiMigration = nil
                wikiMigrationFailed = false
                if lifecycleFailure == Self.migrationFailure { lifecycleFailure = nil }
                legacyWikiAccountID = nil
            }
            erasureWikiAccountID = owner.accountID
        }
        if let accountID { erasureAccountID = accountID }
        if github.ownerID != accountID { github.setOwner(accountID) }
        let migrationChanged = previousMigration?.accountID != wikiMigration?.accountID
            || previousMigration?.deviceID != wikiMigration?.deviceID
            || previousMigrationFailed || wikiMigrationFailed
        guard wiki.owner != owner || migrationChanged else { return }
        let client = owner.flatMap { owner -> WikiLinkClient? in
            guard let workspace else { return nil }
            return WikiLinkClient(owner: owner, workspace: workspace, currentOwner: { [weak self] in
                self?.currentOwner()
            })
        }
        wikiClient = client
        do { try drafts.setContext(owner: owner) }
        catch { lifecycleFailure = "A Wiki draft could not be saved on this device. Return to its original account and host to recover it before closing the app." }
        wiki.setContext(owner: owner, client: client, preparePreferences: { [weak self] in
            guard let self, let owner, self.wiki.owner == owner,
                  self.currentOwner() == owner else { throw WikiError.ownerChanged }
            if self.legacyWikiAccountID != nil || self.wikiMigrationFailed {
                guard let migration = self.wikiMigration,
                      migration.accountID == owner.accountID, migration.deviceID == owner.deviceID,
                      migration.accountID == self.erasureWikiAccountID,
                      migration.deviceID == self.legacyWikiAccountID else { throw WikiError.ownerChanged }
            }
            try self.retryWikiMigration()
        })
    }

    private func retryWikiMigration() throws {
        guard wikiMigrationFailed else { return }
        guard let wikiMigration, wikiMigration.accountID == erasureWikiAccountID,
              wikiMigration.deviceID == legacyWikiAccountID else { throw WikiError.ownerChanged }
        // The descriptor contains no keys and also survives credential erasure.
        try wikiPersistence.migrateAuthenticatedLegacyFolders(wikiMigration)
        wikiMigrationFailed = false
        if lifecycleFailure == Self.migrationFailure { lifecycleFailure = nil }
    }

    func invalidate() {
        currentOwner = { nil }
        wikiClient = nil
        wiki.setContext(owner: nil, client: nil)
        do { try drafts.setContext(owner: nil) }
        catch { lifecycleFailure = "A Wiki draft remains only in memory because device storage was unavailable." }
        github.setOwner(nil)
    }

    /// Called before the existing account eraser. Invalidates every in-flight
    /// request before deleting provider storage; failures remain retryable.
    func eraseAccountData(preservingWikiFolders: Bool = false) throws {
        if preservingWikiFolders { try retryWikiMigration() }
        let accountID = github.ownerID ?? erasureAccountID
        let wikiAccountID = erasureWikiAccountID ?? wiki.owner?.accountID
        wikiClient = nil
        currentOwner = { nil }
        wiki.setContext(owner: nil, client: nil)
        if let wikiAccountID {
            try drafts.deleteAccountData(accountID: wikiAccountID)
            if preservingWikiFolders { try wiki.signOutAccountData(accountID: wikiAccountID) }
            else { try wiki.deleteAccountData(accountID: wikiAccountID) }
        }
        if let accountID {
            github.setOwner(accountID)
            try github.eraseOwnerCredentials()
        }
        if let legacyWikiAccountID, legacyWikiAccountID != wikiAccountID {
            try drafts.deleteAccountData(accountID: legacyWikiAccountID)
            try wikiPersistence.deleteAccount(accountID: legacyWikiAccountID)
        }
        invalidate()
        wikiMigration = nil
        wikiMigrationFailed = false
        if lifecycleFailure == Self.migrationFailure { lifecycleFailure = nil }
        legacyWikiAccountID = nil
        erasureAccountID = nil
        erasureWikiAccountID = nil
    }
}

/// The account store invokes local erasure synchronously on its main actor.
/// Keep that existing protocol and require its actual isolation at this boundary.
final class ReferenceAccountDataEraser: BighelpLocalAccountLifecycleErasing {
    private let base: any BighelpLocalAccountDataErasing
    private let references: OptionalReferenceServices

    init(base: any BighelpLocalAccountDataErasing, references: OptionalReferenceServices) {
        self.base = base
        self.references = references
    }

    func eraseForSignOut() throws {
        let references = self.references
        try MainActor.assumeIsolated { try references.eraseAccountData(preservingWikiFolders: true) }
        try base.erase()
    }

    func erase() throws {
        let references = self.references
        try MainActor.assumeIsolated { try references.eraseAccountData() }
        try base.erase()
    }
}

private struct OptionalReferenceServicesKey: EnvironmentKey {
    static let defaultValue: OptionalReferenceServices? = nil
}

private struct OpenWikiKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}
private struct OpenGitHubKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}
extension EnvironmentValues {
    var optionalReferenceServices: OptionalReferenceServices? {
        get { self[OptionalReferenceServicesKey.self] }
        set { self[OptionalReferenceServicesKey.self] = newValue }
    }
    var openWiki: (@MainActor () -> Void)? {
        get { self[OpenWikiKey.self] }
        set { self[OpenWikiKey.self] = newValue }
    }
    var openGitHub: (@MainActor () -> Void)? {
        get { self[OpenGitHubKey.self] }
        set { self[OpenGitHubKey.self] = newValue }
    }
}
