import Foundation
import Observation

struct UserProfileAvatar: Codable, Equatable, Sendable {
    let mimeType: String
    let byteCount: Int
    let sha256: String
    let encryptedData: String
}

struct BighelpLinkAccountProfile: Codable, Equatable, Sendable {
    let revision: Int
    let displayName: String
    let avatar: UserProfileAvatar?
    let updatedAt: Int
}

struct UserIdentity: Codable, Equatable, Sendable {
    static let stableID = "local-user"
    /// Names reach agents too, so they stay short: 40 visible characters fits
    /// nearly any full name, including two given names or two surnames.
    static let maximumNameLength = 40
    /// Shown on your own messages and avatar before you save a name. Never
    /// sent to a host, so an agent can't mistake it for your name.
    static let placeholderName = "You"

    /// The name you saved, or empty.
    var name: String
    var avatarFileName: String?
    var accountAvatar: UserProfileAvatar? = nil
    var accountProfileRevision: Int = 0
}

extension UserIdentity {
    /// What the app shows for you: your name, or "You" before you've saved one.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.placeholderName : trimmed
    }

    /// A name as it's saved: trimmed and at most `maximumNameLength` characters.
    static func savedName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case avatarFileName
        case accountAvatar
        case accountProfileRevision
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try container.decode(String.self, forKey: .name)
        // Before names reached agents, a new install was saved as "You". That was
        // never a name anyone typed, so it reads as no name.
        name = saved == Self.placeholderName ? "" : saved
        avatarFileName = try container.decodeIfPresent(String.self, forKey: .avatarFileName)
        accountAvatar = try container.decodeIfPresent(
            UserProfileAvatar.self,
            forKey: .accountAvatar
        )
        accountProfileRevision = try container.decodeIfPresent(
            Int.self,
            forKey: .accountProfileRevision
        ) ?? 0
    }
}

@MainActor
@Observable
final class UserIdentityStore {
    var identity: UserIdentity {
        didSet {
            mutationGeneration = UUID()
            save(identity)
        }
    }

    // Not observed: changing ownership must not recursively mutate identity.
    @ObservationIgnored private(set) var mutationGeneration = UUID()
    @ObservationIgnored private var profileWriteID: UUID?

    enum ProfileSaveError: Error, LocalizedError {
        case blankName
        case writeInProgress
        case staleRevision
        case avatarStorageUnavailable

        var errorDescription: String? {
            switch self {
            case .blankName: "Enter a display name before saving."
            case .writeInProgress: "Wait for your profile to finish saving, then try again."
            case .staleRevision: "Your profile changed. Refresh and try again."
            case .avatarStorageUnavailable: "We couldn’t save that photo. Try again."
            }
        }
    }

    private let defaults: UserDefaults
    let avatarDirectory: URL?

    init(defaults: UserDefaults = .standard, avatarDirectory: URL? = nil) {
        self.defaults = defaults
        self.avatarDirectory = avatarDirectory
        identity = Self.load(from: defaults)
    }

    func avatarURL(for identity: UserIdentity? = nil) -> URL? {
        AvatarFileURL.resolve(fileName: (identity ?? self.identity).avatarFileName, in: avatarDirectory)
    }

    func resetForAccountBoundary() {
        profileWriteID = nil
        identity = UserIdentity(name: "", avatarFileName: nil)
    }

    /// Saves your name. An empty name removes it, except on a retired Link
    /// account, which requires one.
    func saveDisplayName(_ name: String, to linkAccount: BighelpLinkAccountStore?) async throws {
        let name = UserIdentity.savedName(name)
        guard !name.isEmpty || linkAccount?.credentials == nil else { throw ProfileSaveError.blankName }
        var updatedIdentity = identity
        updatedIdentity.name = name
        try await saveProfile(updatedIdentity, to: linkAccount)
    }

    func saveAvatar(_ avatar: PreparedAvatar, to linkAccount: BighelpLinkAccountStore?) async throws {
        guard profileWriteID == nil else { throw ProfileSaveError.writeInProgress }
        try Task.checkCancellation()
        guard let avatarDirectory else { throw ProfileSaveError.avatarStorageUnavailable }
        var updatedIdentity = identity
        if let linkAccount, linkAccount.credentials != nil {
            updatedIdentity.accountAvatar = try linkAccount.accountAvatar(from: avatar)
        }
        let fileName = try AvatarImageProcessor().store(avatar, in: avatarDirectory)
        updatedIdentity.avatarFileName = fileName
        do {
            try await saveProfile(updatedIdentity, to: linkAccount)
        } catch {
            try? FileManager.default.removeItem(at: avatarDirectory.appending(path: fileName))
            throw error
        }
    }

    private func saveProfile(
        _ proposedIdentity: UserIdentity,
        to linkAccount: BighelpLinkAccountStore?
    ) async throws {
        guard profileWriteID == nil else { throw ProfileSaveError.writeInProgress }
        try Task.checkCancellation()
        let writeID = UUID()
        profileWriteID = writeID
        // Invalidate reads started before this write, even when the write fails.
        mutationGeneration = UUID()
        let mutation = mutationGeneration
        defer {
            // A reset may already have handed ownership to a replacement write.
            if profileWriteID == writeID { profileWriteID = nil }
        }

        var updatedIdentity = proposedIdentity
        if let linkAccount, let credentials = linkAccount.credentials {
            let accountGeneration = linkAccount.accountGeneration
            let profile: BighelpLinkAccountProfile
            do {
                profile = try await linkAccount.saveProfile(
                    displayName: proposedIdentity.name,
                    avatar: proposedIdentity.accountAvatar,
                    expectedRevision: proposedIdentity.accountProfileRevision
                )
            } catch {
                if case BighelpLinkAPIError.requestFailed(_, "stale_profile_revision") = error,
                   profileWriteID == writeID,
                   mutationGeneration == mutation,
                   linkAccount.accountGeneration == accountGeneration,
                   linkAccount.credentials == credentials {
                    // The server rejected this write. Refresh untouched fields
                    // before a manual retry; never replay the stale whole profile.
                    profileWriteID = nil
                    await hydrateAccountProfile(from: linkAccount)
                }
                throw error
            }
            try Task.checkCancellation()
            guard profileWriteID == writeID,
                  mutationGeneration == mutation,
                  linkAccount.accountGeneration == accountGeneration,
                  linkAccount.credentials == credentials else { throw CancellationError() }
            guard profile.revision > proposedIdentity.accountProfileRevision else {
                throw ProfileSaveError.staleRevision
            }
            updatedIdentity.name = profile.displayName
            updatedIdentity.accountAvatar = profile.avatar
            updatedIdentity.accountProfileRevision = profile.revision
        }
        identity = updatedIdentity
    }

    func hydrateAccountProfile(from linkAccount: BighelpLinkAccountStore) async {
        guard let credentials = linkAccount.credentials, profileWriteID == nil else { return }
        let mutation = mutationGeneration
        let accountGeneration = linkAccount.accountGeneration
        do {
            guard let profile = try await linkAccount.loadProfile(),
                  !Task.isCancelled,
                  profileWriteID == nil,
                  mutationGeneration == mutation,
                  linkAccount.accountGeneration == accountGeneration,
                  linkAccount.credentials == credentials,
                  profile.revision >= identity.accountProfileRevision else { return }
            var updatedIdentity = identity
            let cachedAvatarDigest = updatedIdentity.accountAvatar?.sha256
            let cachedAvatarURL = avatarURL(for: updatedIdentity)
            updatedIdentity.name = profile.displayName
            updatedIdentity.accountAvatar = profile.avatar
            updatedIdentity.accountProfileRevision = profile.revision
            if
                let avatar = profile.avatar,
                cachedAvatarURL == nil || cachedAvatarDigest != avatar.sha256,
                let avatarDirectory
            {
                let preparedAvatar = try linkAccount.preparedAvatar(from: avatar)
                updatedIdentity.avatarFileName = try AvatarImageProcessor().store(
                    preparedAvatar,
                    in: avatarDirectory
                )
            }
            identity = updatedIdentity
        } catch {
            // A cached identity remains usable while the signed account source
            // retries on the next foreground or Settings appearance.
        }
    }

    private static func load(from defaults: UserDefaults) -> UserIdentity {
        guard
            let data = defaults.data(forKey: Keys.identity),
            let identity = try? JSONDecoder().decode(UserIdentity.self, from: data)
        else {
            return UserIdentity(name: "", avatarFileName: nil)
        }
        return identity
    }

    private func save(_ identity: UserIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: Keys.identity)
    }
}

private extension UserIdentityStore {
    enum Keys {
        static let identity = "loopdy.demo.userIdentity"
    }
}
