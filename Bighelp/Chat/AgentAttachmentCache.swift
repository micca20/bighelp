import CryptoKit
import Foundation

/// Files and pictures agents sent, kept on this device so a chat opened again
/// shows them at once instead of downloading each one from the host again.
/// Bounded: the least recently opened files go first.
actor AgentAttachmentCache {
    struct Entry: Codable, Equatable, Sendable {
        let text: String
        let attachments: [ChatAttachment]
    }

    static let shared = AgentAttachmentCache(directory: FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "BighelpAgentAttachments", directoryHint: .isDirectory))
    static let maximumBytes = 512 * 1_024 * 1_024

    private let directory: URL
    private let maximumBytes: Int

    init(directory: URL, maximumBytes: Int = AgentAttachmentCache.maximumBytes) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    /// One file name per host, agent, chat and message, so a key never reveals them.
    nonisolated static func key(_ parts: String...) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func entry(for key: String) -> Entry? {
        let file = url(for: key)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let entry = try? PropertyListDecoder().decode(Entry.self, from: data),
              !entry.attachments.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return entry
    }

    func store(_ entry: Entry, for key: String) {
        guard !entry.attachments.isEmpty else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        // A single file may take at most a quarter of the room, so one huge
        // video can't push out everything else.
        guard let data = try? encoder.encode(entry), data.count <= maximumBytes / 4 else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(for: key), options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            return
        }
        prune()
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(for key: String) -> URL {
        directory.appending(path: key + ".plist", directoryHint: .notDirectory)
    }

    private func prune() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var entries = files.compactMap { file -> (url: URL, size: Int, date: Date)? in
            guard let values = try? file.resourceValues(forKeys: keys) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maximumBytes else { return }
        entries.sort { $0.date < $1.date }
        // Trim well below the limit so the next few files don't each prune again.
        let target = maximumBytes * 4 / 5
        for entry in entries where total > target {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
