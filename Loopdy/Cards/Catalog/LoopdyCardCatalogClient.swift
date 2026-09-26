import CryptoKit
import Foundation

struct LoopdyCardCatalogSnapshot: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case index
        case cache
    }

    let entries: [LoopdyCardCatalogEntry]
    let source: Source
}

struct LoopdyCardCatalogEntry: Identifiable, Equatable, Sendable {
    let template: LoopdyCardTemplate
    let minimumLoopdyVersion: String
    let bundleData: Data

    var id: String { template.id }
    var version: Int { template.version }
    var name: String { template.name }
    var summary: String { template.summary }
    var author: String { template.author }
    var license: String { template.license }
    var minimumCardVersion: Int { template.minimumCardVersion }
    var parametersSchema: [String: LoopdyJSONValue] { template.parametersSchema }
    var document: LoopdyCardDocument { template.document }

    var dataSourceDisclosures: [LoopdyCardCatalogDataSourceDisclosure] {
        document.dataSources.compactMap { rawValue in
            guard
                let source = rawValue.object,
                let rawURL = source["request"]?.object?["url"]?.string,
                let host = URL(string: rawURL)?.host,
                let refresh = source["refresh"]?.object,
                let minimumInterval = refresh["minimum_interval_seconds"]?.integer,
                let staleAfter = refresh["stale_after_seconds"]?.integer,
                let expiresAt = refresh["expires_at"]?.string
            else { return nil }
            return LoopdyCardCatalogDataSourceDisclosure(
                host: host,
                minimumIntervalSeconds: minimumInterval,
                staleAfterSeconds: staleAfter,
                expiresAt: expiresAt
            )
        }
    }

    var requestedComponentTypes: [String] {
        Array(Set(document.elements.values.compactMap { $0.object?["type"]?.string })).sorted()
    }
}

struct LoopdyCardCatalogDataSourceDisclosure: Identifiable, Equatable, Sendable {
    let host: String
    let minimumIntervalSeconds: Int
    let staleAfterSeconds: Int
    let expiresAt: String

    var id: String { "\(host)-\(minimumIntervalSeconds)-\(expiresAt)" }
}

enum LoopdyCardCatalogError: Error, Equatable, LocalizedError {
    case unavailable
    case malformedIndex
    case invalidSignature
    case bundleHashMismatch(id: String)
    case duplicateID(String)
    case unsupportedCardVersion(id: String, version: Int)
    case invalidTemplate(id: String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The card catalog is not configured."
        case .malformedIndex:
            "The card catalog index is malformed."
        case .invalidSignature:
            "The card catalog signature could not be verified."
        case .bundleHashMismatch:
            "A card template failed its integrity check."
        case .duplicateID:
            "The card catalog contains a duplicate template."
        case .unsupportedCardVersion:
            "A card template requires an unsupported card format."
        case .invalidTemplate:
            "A card template is invalid."
        }
    }
}

actor LoopdyCardCatalogClient {
    typealias DataLoader = @Sendable (URL) async throws -> Data

    /// Intentionally absent until a separately reviewed catalog repository and license exist.
    static let productionIndexURL: URL? = nil

    /// Test-only key matching `LoopdyTests/Fixtures/card-catalog-index.json`.
    static let fixturePinnedPublicKey = Data(base64Encoded: "ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=")!

    private struct SignedIndex: Decodable {
        let schema: String
        let version: Int
        let payload: String
        let signature: String
    }

    private struct Payload: Decodable {
        let schema: String
        let version: Int
        let entries: [IndexEntry]
    }

    private struct IndexEntry: Decodable {
        let id: String
        let minimumLoopdyVersion: String
        let bundle: String
        let bundleSHA256: String

        enum CodingKeys: String, CodingKey {
            case id
            case minimumLoopdyVersion = "minimum_loopdy_version"
            case bundle
            case bundleSHA256 = "bundle_sha256"
        }
    }


    private let indexURL: URL?
    private let pinnedPublicKey: Data
    private let supportedLoopdyVersion: LoopdyCardCatalogVersion
    private let supportedCardVersion: Int
    private let cacheURL: URL
    private let dataLoader: DataLoader
    private let fileManager: FileManager

    init(
        indexURL: URL?,
        pinnedPublicKey: Data,
        supportedLoopdyVersion: String,
        supportedCardVersion: Int,
        cacheURL: URL = LoopdyCardCatalogClient.defaultCacheURL,
        fileManager: FileManager = .default,
        dataLoader: @escaping DataLoader = { url in
            try await LoopdyCardCatalogClient.loadData(from: url)
        }
    ) {
        self.indexURL = indexURL
        self.pinnedPublicKey = pinnedPublicKey
        self.supportedLoopdyVersion = LoopdyCardCatalogVersion(supportedLoopdyVersion)
        self.supportedCardVersion = supportedCardVersion
        self.cacheURL = cacheURL
        self.fileManager = fileManager
        self.dataLoader = dataLoader
    }

    func load() async throws -> LoopdyCardCatalogSnapshot {
        guard let indexURL else { throw LoopdyCardCatalogError.unavailable }
        do {
            let data = try await dataLoader(indexURL)
            let entries = try decodeAndValidate(data)
            try persistVerifiedIndex(data)
            return LoopdyCardCatalogSnapshot(entries: entries, source: .index)
        } catch {
            guard let cachedData = try? Data(contentsOf: cacheURL) else { throw error }
            let entries = try decodeAndValidate(cachedData)
            return LoopdyCardCatalogSnapshot(entries: entries, source: .cache)
        }
    }

    private func decodeAndValidate(_ data: Data) throws -> [LoopdyCardCatalogEntry] {
        let signedIndex: SignedIndex
        do {
            signedIndex = try JSONDecoder().decode(SignedIndex.self, from: data)
        } catch {
            throw LoopdyCardCatalogError.malformedIndex
        }
        guard
            signedIndex.schema == "loopdy.card.catalog-index",
            signedIndex.version == 1,
            let payloadData = Data(base64Encoded: signedIndex.payload),
            let signatureData = Data(base64Encoded: signedIndex.signature)
        else { throw LoopdyCardCatalogError.malformedIndex }

        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: pinnedPublicKey)
        } catch {
            throw LoopdyCardCatalogError.invalidSignature
        }
        guard publicKey.isValidSignature(signatureData, for: payloadData) else {
            throw LoopdyCardCatalogError.invalidSignature
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: payloadData)
        } catch {
            throw LoopdyCardCatalogError.malformedIndex
        }
        guard
            payload.schema == "loopdy.card.catalog-payload",
            payload.version == 1
        else { throw LoopdyCardCatalogError.malformedIndex }

        var seenIDs = Set<String>()
        var result: [LoopdyCardCatalogEntry] = []
        result.reserveCapacity(payload.entries.count)
        for rawEntry in payload.entries {
            guard !rawEntry.id.isEmpty, seenIDs.insert(rawEntry.id).inserted else {
                if rawEntry.id.isEmpty { throw LoopdyCardCatalogError.malformedIndex }
                throw LoopdyCardCatalogError.duplicateID(rawEntry.id)
            }
            let minimumLoopdyVersion = LoopdyCardCatalogVersion(rawEntry.minimumLoopdyVersion)
            guard minimumLoopdyVersion.isValid else {
                throw LoopdyCardCatalogError.malformedIndex
            }
            guard minimumLoopdyVersion <= supportedLoopdyVersion else { continue }
            guard
                let bundleData = Data(base64Encoded: rawEntry.bundle),
                rawEntry.bundleSHA256 == Self.sha256(bundleData)
            else { throw LoopdyCardCatalogError.bundleHashMismatch(id: rawEntry.id) }

            let bundle: LoopdyCardTemplate
            do {
                bundle = try JSONDecoder().decode(LoopdyCardTemplate.self, from: bundleData)
            } catch {
                throw LoopdyCardCatalogError.invalidTemplate(id: rawEntry.id)
            }
            guard
                bundle.id == rawEntry.id,
                bundle.version > 0,
                !bundle.name.isEmpty,
                !bundle.summary.isEmpty,
                !bundle.author.isEmpty,
                !bundle.license.isEmpty,
                bundle.sha256.count == 64,
                (try? LoopdyCardTemplate.sha256(for: bundle.document.document)) == bundle.sha256
            else { throw LoopdyCardCatalogError.invalidTemplate(id: rawEntry.id) }
            guard bundle.minimumCardVersion <= supportedCardVersion else {
                throw LoopdyCardCatalogError.unsupportedCardVersion(
                    id: rawEntry.id,
                    version: bundle.minimumCardVersion
                )
            }
            let document: LoopdyCardDocument
            do {
                document = try LoopdyCardValidator.validate(bundle.document)
            } catch {
                throw LoopdyCardCatalogError.invalidTemplate(id: rawEntry.id)
            }
            result.append(LoopdyCardCatalogEntry(
                template: LoopdyCardTemplate(
                    id: bundle.id,
                    version: bundle.version,
                    name: bundle.name,
                    summary: bundle.summary,
                    author: bundle.author,
                    license: bundle.license,
                    minimumCardVersion: bundle.minimumCardVersion,
                    parametersSchema: bundle.parametersSchema,
                    document: document,
                    sha256: bundle.sha256
                ),
                minimumLoopdyVersion: rawEntry.minimumLoopdyVersion,
                bundleData: bundleData
            ))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func persistVerifiedIndex(_ data: Data) throws {
        try fileManager.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: cacheURL, options: [.atomic, .completeFileProtection])
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadData(from url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw LoopdyCardCatalogError.unavailable
        }
        return data
    }

    private static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Loopdy/CardCatalog", directoryHint: .isDirectory)
            .appending(path: "signed-index.json")
    }
}

struct LoopdyCardCatalogVersion: Comparable, Sendable {
    private let components: [Int]
    let isValid: Bool

    init(_ rawValue: String) {
        let pieces = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        let values = pieces.compactMap { Int($0) }
        isValid = !pieces.isEmpty && values.count == pieces.count && values.allSatisfy { $0 >= 0 }
        components = values
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
