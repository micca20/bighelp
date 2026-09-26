import Foundation

@MainActor
protocol WikiDraftPersistence {
    func load(owner: WikiOwner) throws -> WikiDraftState?
    func save(_ state: WikiDraftState) throws
    func deleteAccount(accountID: String) throws
}

/// Lazy, local-only storage separate from both free Scratchpad and save journals.
/// Filenames hash the complete owner. File-bound identities live only inside the
/// protected payload. No credentials, UserDefaults, Keychain or iCloud documents.
@MainActor
final class WikiDraftLocalPersistence: WikiDraftPersistence {
    private let directory: URL?
    private let protector: any LoopdyLocalFileProtecting
    private let availability: any LoopdyProtectedDataAvailabilityProviding

    init(directory: URL? = nil,
         protector: any LoopdyLocalFileProtecting = LoopdyLocalFileProtector(),
         availability: any LoopdyProtectedDataAvailabilityProviding = LoopdySystemProtectedDataAvailability()) {
        self.directory = directory
        self.protector = protector
        self.availability = availability
    }

    private func baseDirectory() throws -> URL {
        if let directory { return directory }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: false)
            .appendingPathComponent("WikiDrafts", isDirectory: true)
    }

    private func accountDirectory(_ accountID: String) throws -> URL {
        try baseDirectory().appendingPathComponent(WikiLimits.digest(Data(accountID.utf8)), isDirectory: true)
    }

    private func file(_ owner: WikiOwner) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try accountDirectory(owner.accountID)
            .appendingPathComponent(WikiLimits.digest(encoder.encode(owner)) + ".json")
    }

    func load(owner: WikiOwner) throws -> WikiDraftState? {
        guard owner.isValid else { throw WikiError.ownerChanged }
        try requireLoopdyProtectedData(availability)
        let url = try file(owner)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try requireRegularFile(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size >= 0, size <= WikiDraftLimits.accountBytes else { throw WikiError.quota }
        let data = try Data(contentsOf: url)
        guard data.count <= WikiDraftLimits.accountBytes else { throw WikiError.quota }
        let state = try JSONDecoder().decode(WikiDraftState.self, from: data)
        guard state.owner == owner else { throw WikiError.ownerChanged }
        try WikiDraftLimits.validate(state)
        return state
    }

    func save(_ state: WikiDraftState) throws {
        try requireLoopdyProtectedData(availability)
        try WikiDraftLimits.validate(state)
        let data = try JSONEncoder().encode(state)
        guard data.count <= WikiDraftLimits.accountBytes else { throw WikiError.quota }
        let url = try file(state.owner)
        // Explicitly discarding the last draft should work even when there is
        // no room for a replacement file. Do not retain empty epoch records.
        if state.drafts.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try requireRegularFile(url)
                try FileManager.default.removeItem(at: url)
            }
            guard !FileManager.default.fileExists(atPath: url.path) else { throw WikiDraftError.persistence }
            return
        }
        let account = url.deletingLastPathComponent()
        try protector.prepareDirectory(try baseDirectory(), protection: .privateVisual, fileManager: .default)
        try protector.prepareDirectory(account, protection: .privateVisual, fileManager: .default)
        let siblings = try FileManager.default.contentsOfDirectory(at: account,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        // Enumeration can resolve /var to /private/var (or remove a base URL),
        // so URL equality does not establish whether the destination exists.
        // These entries share the account directory; match its hashed filename.
        let replacing = siblings.contains { $0.lastPathComponent == url.lastPathComponent }
        // Include old epochs and any interrupted temporary writes. Never evict
        // another draft to make space. Reserve the transient replacement as well.
        guard siblings.count < WikiDraftLimits.ownerFilesPerAccount,
              replacing || siblings.count + 1 < WikiDraftLimits.ownerFilesPerAccount else { throw WikiError.quota }
        var aggregate = data.count
        for sibling in siblings {
            try requireRegularFile(sibling)
            let size = try sibling.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size >= 0, size <= WikiDraftLimits.accountBytes - aggregate else { throw WikiError.quota }
            aggregate += size
        }
        let temporary = account.appendingPathComponent("pending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try protector.write(data, to: temporary, protection: .privateVisual)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try requireLoopdyProtectedData(availability)
        if replacing {
            // Keep the new file's complete protection/backup-exclusion metadata.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary,
                                                       options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WikiError.invalidResponse }
    }

    /// Explicit account erasure, including previous hosts/profiles/device epochs.
    func deleteAccount(accountID: String) throws {
        try requireLoopdyProtectedData(availability)
        let url = try accountDirectory(accountID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw WikiDraftError.persistence }
    }
}
