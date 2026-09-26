import CryptoKit
import Foundation

struct BighelpCardTemplate: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let version: Int
    let name: String
    let summary: String
    let author: String
    let license: String
    let minimumCardVersion: Int
    let parametersSchema: [String: BighelpJSONValue]
    let wireDocument: [String: BighelpJSONValue]
    let document: BighelpCardDocument
    let sha256: String

    private static let runtimeDocumentKeys: Set<String> = [
        "content_hash", "card_id", "origin", "created_at",
    ]
    private static let projectionCreatedAt = "2001-01-01T00:00:00Z"

    enum CodingKeys: String, CodingKey {
        case id
        case version
        case name
        case summary
        case author
        case license
        case minimumCardVersion = "minimum_card_version"
        case parametersSchema = "parameters_schema"
        case document
        case sha256
    }

    init(
        id: String,
        version: Int,
        name: String,
        summary: String,
        author: String,
        license: String,
        minimumCardVersion: Int,
        parametersSchema: [String: BighelpJSONValue],
        document: BighelpCardDocument,
        sha256: String
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.summary = summary
        self.author = author
        self.license = license
        self.minimumCardVersion = minimumCardVersion
        self.parametersSchema = parametersSchema
        wireDocument = document.document
        self.document = document
        self.sha256 = sha256
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decode(Int.self, forKey: .version)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decode(String.self, forKey: .summary)
        author = try container.decode(String.self, forKey: .author)
        license = try container.decode(String.self, forKey: .license)
        minimumCardVersion = try container.decode(Int.self, forKey: .minimumCardVersion)
        parametersSchema = try container.decode(
            [String: BighelpJSONValue].self,
            forKey: .parametersSchema
        )
        wireDocument = try container.decode(
            [String: BighelpJSONValue].self,
            forKey: .document
        )
        document = try Self.renderDocument(from: wireDocument)
        sha256 = try container.decode(String.self, forKey: .sha256)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(name, forKey: .name)
        try container.encode(summary, forKey: .summary)
        try container.encode(author, forKey: .author)
        try container.encode(license, forKey: .license)
        try container.encode(minimumCardVersion, forKey: .minimumCardVersion)
        try container.encode(parametersSchema, forKey: .parametersSchema)
        try container.encode(wireDocument, forKey: .document)
        try container.encode(sha256, forKey: .sha256)
    }

    static func renderDocument(
        from wireDocument: [String: BighelpJSONValue]
    ) throws -> BighelpCardDocument {
        let metadataKeys = runtimeDocumentKeys.intersection(wireDocument.keys)
        guard metadataKeys.isEmpty else {
            return try BighelpCardDocument(document: wireDocument)
        }

        let digest = try sha256(for: wireDocument)
        var renderedDocument = wireDocument
        renderedDocument["content_hash"] = .string(digest)
        renderedDocument["card_id"] = .string(String(digest.prefix(32)))
        renderedDocument["origin"] = .string("live")
        renderedDocument["created_at"] = .string(projectionCreatedAt)
        return try BighelpCardDocument(document: renderedDocument)
    }

    static func sha256(for document: [String: BighelpJSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonicalDocument = try encoder.encode(document)
        return SHA256.hash(data: canonicalDocument)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
