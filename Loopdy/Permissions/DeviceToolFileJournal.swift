import Foundation
import CryptoKit

/// Stores only mutation identities and outcomes, never read results or arguments.
@MainActor
final class DeviceToolFileJournal: DeviceToolJournal {
    private let url: URL
    private let clock: () -> Int
    private enum JournalError: Error { case invalid, full }
    private let maximumEntries = 512
    init(url: URL, clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }) {
        self.url = url; self.clock = clock
    }
    func entry(requestID: String, scope: DeviceToolScope) throws -> DeviceToolJournalEntry? {
        try read()[key(requestID: requestID, scope: scope)]
    }
    func save(_ entry: DeviceToolJournalEntry, requestID: String, scope: DeviceToolScope) throws {
        // Retain tombstones for a day past their request deadline. Never evict an
        // in-flight write to make space for a new one.
        var values = try read().filter { $0.value.expiresAt >= clock() - 86_400 }
        values[key(requestID: requestID, scope: scope)] = entry
        guard values.count <= maximumEntries else { throw JournalError.full }
        let data = try JSONEncoder().encode(values)
        guard data.count <= 2_000_000 else { throw JournalError.full }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        var resourceURL = url
        var resourceValues = URLResourceValues(); resourceValues.isExcludedFromBackup = true
        try resourceURL.setResourceValues(resourceValues)
    }

    private func read() throws -> [String: DeviceToolJournalEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 2_000_000 else {
            throw JournalError.invalid
        }
        let result = try JSONDecoder().decode([String: DeviceToolJournalEntry].self, from: Data(contentsOf: url))
        guard result.count <= maximumEntries else { throw JournalError.invalid }
        return result
    }

    private func key(requestID: String, scope: DeviceToolScope) -> String {
        SHA256.hash(data: Data((scope.storageKey + ":" + requestID).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
