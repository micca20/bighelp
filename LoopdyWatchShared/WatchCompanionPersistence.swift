import Foundation

/// Private, bounded, backup-excluded storage. Never uses account credentials or shared defaults.
/// A failed/corrupt write must fail closed before any consequential phone action begins.
enum WatchCompanionPersistence {
    static func load<Value: Decodable>(_ type: Value.Type, name: String) throws -> Value? {
        let url = try location(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 512_000 else { throw WatchCompanionValidationError.fieldTooLong }
        return try PropertyListDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func save<Value: Encodable>(_ value: Value, name: String) throws {
        var url = try location(name)
        let data = try PropertyListEncoder().encode(value)
        guard data.count <= 512_000 else { throw WatchCompanionValidationError.fieldTooLong }
        #if os(iOS) || os(watchOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private static func location(_ name: String) throws -> URL {
        var directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("WatchCompanion", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory.appendingPathComponent(name).appendingPathExtension("plist")
    }
}
