import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The remote catalog may replace artwork, but cannot add provider identities.
enum ProviderLogoPolicy {
    static let manifestURL = URL(string: "https://logos.loopdy.app/provider-logos/v1/manifest.json")!
    static let maximumManifestBytes = 64 * 1_024
    static let maximumImageBytes = 1_024 * 1_024
    static let maximumSnapshotBytes = 32 * 1_024 * 1_024
    static let maximumImages = 18
    static let maximumDimension = 1_024
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    static let failureBackoff: TimeInterval = 15 * 60

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func isAllowedURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "logos.loopdy.app",
              components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return false }
        // Canonical equality also excludes percent-encoded paths, dot segments, and
        // alternative spellings that different HTTP stacks might normalize differently.
        if url.absoluteString == manifestURL.absoluteString { return true }
        let prefix = "https://logos.loopdy.app/provider-logos/v1/images/"
        let value = url.absoluteString
        guard value.hasPrefix(prefix), value.hasSuffix(".png") else { return false }
        return isDigest(String(value.dropFirst(prefix.count).dropLast(4)))
    }
}

enum ProviderLogoError: Error {
    case invalidManifest
    case invalidImage
    case invalidCache
    case invalidURL
    case invalidResponse
    case tooLarge
    case redirected
}

struct ProviderLogoManifest: Sendable {
    struct ImageReference: Sendable {
        let path: String
        let sha256: String
    }

    struct Variants: Sendable {
        let light: ImageReference
        let dark: ImageReference
    }

    let revision: String
    let logos: [String: Variants]

    var references: [String: ImageReference] {
        var result: [String: ImageReference] = [:]
        for variants in logos.values {
            result[variants.light.sha256] = variants.light
            result[variants.dark.sha256] = variants.dark
        }
        return result
    }

    static func parse(_ data: Data, allowedAssetNames: Set<String>) throws -> Self {
        guard !data.isEmpty, data.count <= ProviderLogoPolicy.maximumManifestBytes else {
            throw ProviderLogoError.tooLarge
        }
        try rejectAmbiguousObjects(data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "revision", "logos"],
              let version = root["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let revision = root["revision"] as? String,
              !revision.isEmpty, revision.utf8.count <= 128,
              let objects = root["logos"] as? [String: Any],
              objects.count <= ProviderLogoPolicy.maximumImages / 2,
              Set(objects.keys).isSubset(of: allowedAssetNames) else {
            throw ProviderLogoError.invalidManifest
        }
        var logos: [String: Variants] = [:]
        for (name, value) in objects {
            guard let variants = value as? [String: Any], Set(variants.keys) == ["light", "dark"] else {
                throw ProviderLogoError.invalidManifest
            }
            logos[name] = try Variants(
                light: reference(variants["light"]),
                dark: reference(variants["dark"])
            )
        }
        return Self(revision: revision, logos: logos)
    }

    private static func reference(_ object: Any?) throws -> ImageReference {
        guard let value = object as? [String: Any], Set(value.keys) == ["path", "sha256"],
              let path = value["path"] as? String, let digest = value["sha256"] as? String,
              ProviderLogoPolicy.isDigest(digest), path == "images/\(digest).png" else {
            throw ProviderLogoError.invalidManifest
        }
        return ImageReference(path: path, sha256: digest)
    }

    /// Foundation's JSON decoders accept duplicate keys. Preflight key tokens before
    /// decoding so escaped-equivalent duplicates cannot differ from the publisher's
    /// interpretation. This schema has objects only and at most four object levels.
    private static func rejectAmbiguousObjects(_ data: Data) throws {
        let bytes = Array(data)
        var index = 0
        var keys: [Set<String>] = []
        while index < bytes.count {
            switch bytes[index] {
            case 123: // {
                keys.append([])
                guard keys.count <= 4 else { throw ProviderLogoError.invalidManifest }
            case 125: // }
                guard !keys.isEmpty else { throw ProviderLogoError.invalidManifest }
                keys.removeLast()
            case 91, 93: // Arrays are never part of the catalog schema.
                throw ProviderLogoError.invalidManifest
            case 34:
                let start = index
                index += 1
                while index < bytes.count, bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 }
                    index += 1
                }
                guard index < bytes.count else { throw ProviderLogoError.invalidManifest }
                var next = index + 1
                while next < bytes.count, [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 58 {
                    guard !keys.isEmpty else { throw ProviderLogoError.invalidManifest }
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard keys[keys.count - 1].insert(key).inserted else {
                        throw ProviderLogoError.invalidManifest
                    }
                }
            default:
                break
            }
            index += 1
        }
        guard keys.isEmpty else { throw ProviderLogoError.invalidManifest }
    }
}

struct ProviderLogoSnapshot: Codable, Sendable {
    let formatVersion: Int
    let manifestURL: String
    let manifest: Data
    let images: [String: Data]
    let fetchedAt: Date
}

/// CGImage is immutable. Only fully decoded images cross the repository boundary;
/// no mutable ImageIO source or decoding context is shared between executors.
struct ProviderLogoDecodedImage: @unchecked Sendable {
    let value: CGImage
}

struct ProviderLogoPreparedSnapshot: Sendable {
    let snapshot: ProviderLogoSnapshot
    let manifest: ProviderLogoManifest
    let images: [String: ProviderLogoDecodedImage]
}

/// Keeps file IO, JSON parsing, hashing, and bounded PNG decoding off the main actor.
actor ProviderLogoRepository {
    private let manifestURL: URL
    private let cacheURL: URL?
    private let transport: any ProviderLogoFetching
    private let allowedAssetNames: Set<String>

    init(manifestURL: URL, cacheURL: URL?, transport: any ProviderLogoFetching, allowedAssetNames: Set<String>) {
        self.manifestURL = manifestURL
        self.cacheURL = cacheURL
        self.transport = transport
        self.allowedAssetNames = allowedAssetNames
    }

    func restore() -> ProviderLogoPreparedSnapshot? {
        guard let cacheURL, cacheURL.isFileURL else { return nil }
        do {
            try Task.checkCancellation()
            let file = try FileHandle(forReadingFrom: cacheURL)
            defer { try? file.close() }
            var bytes = Data()
            // Do not trust a file-size preflight alone: the file can change during IO.
            while let chunk = try file.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                try Task.checkCancellation()
                guard chunk.count <= ProviderLogoPolicy.maximumSnapshotBytes - bytes.count else {
                    throw ProviderLogoError.tooLarge
                }
                bytes.append(chunk)
            }
            let snapshot = try JSONDecoder().decode(ProviderLogoSnapshot.self, from: bytes)
            return try prepare(snapshot)
        } catch {
            return nil
        }
    }

    func fetch(reusing previousImages: [String: Data], now: @Sendable () -> Date) async throws -> ProviderLogoPreparedSnapshot {
        guard manifestURL.absoluteString == ProviderLogoPolicy.manifestURL.absoluteString else {
            throw ProviderLogoError.invalidURL
        }
        try Task.checkCancellation()
        let bytes = try await transport.data(from: manifestURL, maximumBytes: ProviderLogoPolicy.maximumManifestBytes)
        try Task.checkCancellation()
        let manifest = try ProviderLogoManifest.parse(bytes, allowedAssetNames: allowedAssetNames)
        var images: [String: Data] = [:]
        // Sorting is deterministic; each shared light/dark digest is fetched only once.
        for (digest, reference) in manifest.references.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            if let cached = previousImages[digest] {
                images[digest] = cached
            } else {
                let url = manifestURL.deletingLastPathComponent().appending(path: reference.path)
                guard ProviderLogoPolicy.isAllowedURL(url) else { throw ProviderLogoError.invalidURL }
                let data = try await transport.data(from: url, maximumBytes: ProviderLogoPolicy.maximumImageBytes)
                guard data.count <= ProviderLogoPolicy.maximumImageBytes else { throw ProviderLogoError.tooLarge }
                images[digest] = data
            }
        }
        try Task.checkCancellation()
        return try prepare(ProviderLogoSnapshot(
            formatVersion: 1,
            manifestURL: manifestURL.absoluteString,
            manifest: bytes,
            images: images,
            fetchedAt: now()
        ))
    }

    func persist(_ snapshot: ProviderLogoSnapshot) {
        guard let cacheURL, cacheURL.isFileURL else { return }
        do {
            try Task.checkCancellation()
            let bytes = try JSONEncoder().encode(snapshot)
            guard bytes.count <= ProviderLogoPolicy.maximumSnapshotBytes else { throw ProviderLogoError.tooLarge }
            let directory = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Task.checkCancellation()
            try bytes.write(to: cacheURL, options: .atomic)
            // Public disposable cache, deliberately separate from account persistence.
            var excludedURL = cacheURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? excludedURL.setResourceValues(values)
        } catch {
            // Keep any last-good disk snapshot if replacement failed.
        }
    }

    private func prepare(_ snapshot: ProviderLogoSnapshot) throws -> ProviderLogoPreparedSnapshot {
        guard snapshot.formatVersion == 1,
              manifestURL.absoluteString == ProviderLogoPolicy.manifestURL.absoluteString,
              snapshot.manifestURL == manifestURL.absoluteString,
              snapshot.fetchedAt.timeIntervalSince1970.isFinite,
              snapshot.images.count <= ProviderLogoPolicy.maximumImages else {
            throw ProviderLogoError.invalidCache
        }
        let manifest = try ProviderLogoManifest.parse(snapshot.manifest, allowedAssetNames: allowedAssetNames)
        guard Set(snapshot.images.keys) == Set(manifest.references.keys) else {
            throw ProviderLogoError.invalidCache
        }
        var images: [String: ProviderLogoDecodedImage] = [:]
        for (digest, data) in snapshot.images {
            try Task.checkCancellation()
            images[digest] = try Self.decodePNG(data, digest: digest)
        }
        return ProviderLogoPreparedSnapshot(snapshot: snapshot, manifest: manifest, images: images)
    }

    private static func decodePNG(_ data: Data, digest: String) throws -> ProviderLogoDecodedImage {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard !data.isEmpty, data.count <= ProviderLogoPolicy.maximumImageBytes,
              data.starts(with: signature), ProviderLogoPolicy.isDigest(digest),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
            throw ProviderLogoError.invalidImage
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...ProviderLogoPolicy.maximumDimension).contains(width),
              (1...ProviderLogoPolicy.maximumDimension).contains(height) else {
            throw ProviderLogoError.invalidImage
        }
        let decodeOptions = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions),
              image.width == width, image.height == height,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ProviderLogoError.invalidImage
        }
        return ProviderLogoDecodedImage(value: image)
    }
}
