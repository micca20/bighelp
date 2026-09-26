import CryptoKit
import Foundation

struct BighelpCardCatalogSnapshot: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case index
        case cache
    }

    let entries: [BighelpCardCatalogEntry]
    let source: Source
}

struct BighelpCardCatalogEntry: Identifiable, Equatable, Sendable {
    let template: BighelpCardTemplate
    let minimumBighelpVersion: String
    let bundleData: Data

    var id: String { template.id }
    var version: Int { template.version }
    var name: String { template.name }
    var summary: String { template.summary }
    var author: String { template.author }
    var license: String { template.license }
    var minimumCardVersion: Int { template.minimumCardVersion }
    var parametersSchema: [String: BighelpJSONValue] { template.parametersSchema }
    var document: BighelpCardDocument { template.document }

    var dataSourceDisclosures: [BighelpCardCatalogDataSourceDisclosure] {
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
            return BighelpCardCatalogDataSourceDisclosure(
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

struct BighelpCardCatalogDataSourceDisclosure: Identifiable, Equatable, Sendable {
    let host: String
    let minimumIntervalSeconds: Int
    let staleAfterSeconds: Int
    let expiresAt: String

    var id: String { "\(host)-\(minimumIntervalSeconds)-\(expiresAt)" }
}

enum BighelpCardCatalogError: Error, Equatable, LocalizedError {
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

actor BighelpCardCatalogClient {
    typealias DataLoader = @Sendable (URL) async throws -> Data

    /// Intentionally absent until a separately reviewed catalog repository and license exist.
    static let productionIndexURL: URL? = nil

    /// Test-only key matching `BighelpTests/Fixtures/card-catalog-index.json`.
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
        let minimumBighelpVersion: String
        let bundle: String
        let bundleSHA256: String

        enum CodingKeys: String, CodingKey {
            case id
            case minimumBighelpVersion = "minimum_loopdy_version"
            case bundle
            case bundleSHA256 = "bundle_sha256"
        }
    }


    private let indexURL: URL?
    private let pinnedPublicKey: Data
    private let supportedBighelpVersion: BighelpCardCatalogVersion
    private let supportedCardVersion: Int
    private let cacheURL: URL
    private let dataLoader: DataLoader
    private let fileManager: FileManager

    init(
        indexURL: URL?,
        pinnedPublicKey: Data,
        supportedBighelpVersion: String,
        supportedCardVersion: Int,
        cacheURL: URL = BighelpCardCatalogClient.defaultCacheURL,
        fileManager: FileManager = .default,
        dataLoader: @escaping DataLoader = { url in
            try await BighelpCardCatalogClient.loadData(from: url)
        }
    ) {
        self.indexURL = indexURL
        self.pinnedPublicKey = pinnedPublicKey
        self.supportedBighelpVersion = BighelpCardCatalogVersion(supportedBighelpVersion)
        self.supportedCardVersion = supportedCardVersion
        self.cacheURL = cacheURL
        self.fileManager = fileManager
        self.dataLoader = dataLoader
    }

    func load() async throws -> BighelpCardCatalogSnapshot {
        guard let indexURL else { throw BighelpCardCatalogError.unavailable }
        do {
            let data = try await dataLoader(indexURL)
            let entries = try decodeAndValidate(data)
            try persistVerifiedIndex(data)
            return BighelpCardCatalogSnapshot(entries: entries, source: .index)
        } catch {
            guard let cachedData = try? Data(contentsOf: cacheURL) else { throw error }
            let entries = try decodeAndValidate(cachedData)
            return BighelpCardCatalogSnapshot(entries: entries, source: .cache)
        }
    }

    private func decodeAndValidate(_ data: Data) throws -> [BighelpCardCatalogEntry] {
        let signedIndex: SignedIndex
        do {
            signedIndex = try JSONDecoder().decode(SignedIndex.self, from: data)
        } catch {
            throw BighelpCardCatalogError.malformedIndex
        }
        guard
            signedIndex.schema == "loopdy.card.catalog-index",
            signedIndex.version == 1,
            let payloadData = Data(base64Encoded: signedIndex.payload),
            let signatureData = Data(base64Encoded: signedIndex.signature)
        else { throw BighelpCardCatalogError.malformedIndex }

        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: pinnedPublicKey)
        } catch {
            throw BighelpCardCatalogError.invalidSignature
        }
        guard publicKey.isValidSignature(signatureData, for: payloadData) else {
            throw BighelpCardCatalogError.invalidSignature
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: payloadData)
        } catch {
            throw BighelpCardCatalogError.malformedIndex
        }
        guard
            payload.schema == "loopdy.card.catalog-payload",
            payload.version == 1
        else { throw BighelpCardCatalogError.malformedIndex }

        var seenIDs = Set<String>()
        var result: [BighelpCardCatalogEntry] = []
        result.reserveCapacity(payload.entries.count)
        for rawEntry in payload.entries {
            guard !rawEntry.id.isEmpty, seenIDs.insert(rawEntry.id).inserted else {
                if rawEntry.id.isEmpty { throw BighelpCardCatalogError.malformedIndex }
                throw BighelpCardCatalogError.duplicateID(rawEntry.id)
            }
            let minimumBighelpVersion = BighelpCardCatalogVersion(rawEntry.minimumBighelpVersion)
            guard minimumBighelpVersion.isValid else {
                throw BighelpCardCatalogError.malformedIndex
            }
            guard minimumBighelpVersion <= supportedBighelpVersion else { continue }
            guard
                let bundleData = Data(base64Encoded: rawEntry.bundle),
                rawEntry.bundleSHA256 == Self.sha256(bundleData)
            else { throw BighelpCardCatalogError.bundleHashMismatch(id: rawEntry.id) }

            let bundle: BighelpCardTemplate
            do {
                bundle = try JSONDecoder().decode(BighelpCardTemplate.self, from: bundleData)
            } catch {
                throw BighelpCardCatalogError.invalidTemplate(id: rawEntry.id)
            }
            guard
                bundle.id == rawEntry.id,
                bundle.version > 0,
                !bundle.name.isEmpty,
                !bundle.summary.isEmpty,
                !bundle.author.isEmpty,
                !bundle.license.isEmpty,
                bundle.sha256.count == 64,
                (try? BighelpCardTemplate.sha256(for: bundle.document.document)) == bundle.sha256
            else { throw BighelpCardCatalogError.invalidTemplate(id: rawEntry.id) }
            guard bundle.minimumCardVersion <= supportedCardVersion else {
                throw BighelpCardCatalogError.unsupportedCardVersion(
                    id: rawEntry.id,
                    version: bundle.minimumCardVersion
                )
            }
            let document: BighelpCardDocument
            do {
                document = try BighelpCardValidator.validate(bundle.document)
            } catch {
                throw BighelpCardCatalogError.invalidTemplate(id: rawEntry.id)
            }
            result.append(BighelpCardCatalogEntry(
                template: BighelpCardTemplate(
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
                minimumBighelpVersion: rawEntry.minimumBighelpVersion,
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
            throw BighelpCardCatalogError.unavailable
        }
        return data
    }

    private static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Loopdy/CardCatalog", directoryHint: .isDirectory)
            .appending(path: "signed-index.json")
    }
}

struct BighelpCardCatalogVersion: Comparable, Sendable {
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
