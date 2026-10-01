import CryptoKit
import Foundation

/// Local text and admission uncertainty, never host credentials. Production
/// gives each bighelp account/host its own directory; profile/session coordinates
/// further scope each record. Retired account owners cannot recreate files.
@MainActor
final class DirectHermesDraftStore {
    struct Record: Codable {
        var draft = ""
        var unresolved: [Submission] = []
        var owner: Owner?
    }

    struct Owner: Codable {
        let hostIdentity: String
        let profile: String
        let storedID: String
        let title: String
    }

    struct RecoveryRecord: Identifiable {
        let id: String
        let record: Record
    }

    struct Submission: Codable, Identifiable {
        let id: UUID
        let text: String
        let method: String
        let createdAt: Date
        // Original composer intent survives wire expansion and a newer draft.
        // Optional fields keep existing protected journal files decodable.
        var composerText: String? = nil
        var attachments: [ChatAttachment]? = nil
        var rejectionCode: Int? = nil

        private enum CodingKeys: String, CodingKey {
            case id, text, method, createdAt, composerText, attachments, rejectionCode
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(text, forKey: .text)
            try values.encode(method, forKey: .method)
            try values.encode(createdAt, forKey: .createdAt)
            try values.encodeIfPresent(composerText, forKey: .composerText)
            try values.encodeIfPresent(rejectionCode, forKey: .rejectionCode)
            // Keep upload/uncertain journals at their existing text-reference
            // cost. Only a refused intent needs a separate durable local copy.
            if rejectionCode != nil { try values.encodeIfPresent(attachments, forKey: .attachments) }
        }
    }

    private let root: URL
    private var isValid = true
    func invalidate() { isValid = false }

    init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appending(path: "DirectHermesDrafts", directoryHint: .isDirectory)
    }

    func load(scope: String) throws -> Record {
        let url = file(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return Record() }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    }

    func save(_ record: Record, scope: String) throws {
        guard isValid else { throw DirectHermesError.secureStorageChanged }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try JSONEncoder().encode(record).write(to: file(scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = file(scope)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func recoveryRecords(hostIdentity: String, profile: String? = nil) throws -> [RecoveryRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        return try files.compactMap { url -> RecoveryRecord? in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, url.pathExtension == "json" else { return nil }
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
            guard let owner = record.owner, owner.hostIdentity == hostIdentity, profile == nil || owner.profile == profile,
                  !record.draft.isEmpty || !record.unresolved.isEmpty else { return nil }
            return RecoveryRecord(id: url.lastPathComponent, record: record)
        }.sorted { $0.id < $1.id }
    }

    /// Deleting an agent deletes its chats; their drafts and unconfirmed sends
    /// on this device go too, so they can't block a later agent with the same name.
    func removeRecords(hostIdentity: String, profile: String) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        for url in files {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, url.pathExtension == "json",
                  let record = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: url)),
                  let owner = record.owner, owner.hostIdentity == hostIdentity, owner.profile == profile else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func file(_ scope: String) -> URL {
        let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: digest + ".json")
    }
}
