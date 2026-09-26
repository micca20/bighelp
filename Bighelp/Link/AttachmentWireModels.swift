import CryptoKit
import Foundation

struct BighelpLinkAttachmentReference: Codable, Equatable, Sendable {
    static let maximumBytes = 8 * 1_024 * 1_024

    let attachmentID: String
    let fileName: String
    let mimeType: String
    let totalBytes: Int
    let sha256: String

    private enum CodingKeys: String, CodingKey {
        case attachmentID = "attachmentId"
        case fileName
        case mimeType
        case totalBytes
        case sha256
    }

    init(
        attachmentID: String,
        fileName: String,
        mimeType: String,
        totalBytes: Int,
        sha256: String
    ) throws {
        guard
            BighelpLinkPickerValidation.opaque(attachmentID, minimum: 16, maximum: 128),
            Self.validFileName(fileName),
            Self.validMIMEType(mimeType),
            (1...Self.maximumBytes).contains(totalBytes),
            let digest = try? BighelpLinkBase64URL.decode(sha256),
            digest.count == SHA256.Digest.byteCount
        else { throw BighelpLinkWireError.invalidValue }
        self.attachmentID = attachmentID
        self.fileName = fileName
        self.mimeType = mimeType
        self.totalBytes = totalBytes
        self.sha256 = sha256
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            attachmentID: container.decode(String.self, forKey: .attachmentID),
            fileName: container.decode(String.self, forKey: .fileName),
            mimeType: container.decode(String.self, forKey: .mimeType),
            totalBytes: container.decode(Int.self, forKey: .totalBytes),
            sha256: container.decode(String.self, forKey: .sha256)
        )
    }

    private static func validFileName(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 180
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.contains("/")
            && !value.contains("\\")
            && value != "."
            && value != ".."
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validMIMEType(_ value: String) -> Bool {
        guard value.count <= 120, let slash = value.firstIndex(of: "/") else { return false }
        return slash != value.startIndex
            && value.index(after: slash) != value.endIndex
            && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || "!#$&^_.+-/".contains($0))
            }
    }
}

struct BighelpLinkAttachmentChunk: Codable, Equatable, Sendable {
    static let maximumChunkBytes = 64 * 1_024
    static let maximumChunkCount = 128

    let version = 1
    let type = "attachment.chunk"
    let uploadID: String
    let sessionID: String
    let agentID: String
    let reference: BighelpLinkAttachmentReference
    let index: Int
    let count: Int
    let data: String
    let sentAt: Int

    var attachmentID: String { reference.attachmentID }
    var fileName: String { reference.fileName }
    var mimeType: String { reference.mimeType }
    var totalBytes: Int { reference.totalBytes }
    var sha256: String { reference.sha256 }

    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case uploadID = "uploadId"
        case sessionID = "sessionId"
        case agentID = "agentId"
        case attachmentID = "attachmentId"
        case fileName
        case mimeType
        case totalBytes
        case sha256
        case index
        case count
        case data
        case sentAt
    }

    init(
        uploadID: String,
        sessionID: String,
        agentID: String,
        reference: BighelpLinkAttachmentReference,
        index: Int,
        count: Int,
        data: String,
        sentAt: Int
    ) throws {
        guard
            BighelpLinkPickerValidation.opaque(uploadID, minimum: 16, maximum: 128),
            BighelpLinkSessionCoordinate.isValid(sessionID),
            BighelpLinkPickerValidation.opaque(agentID, minimum: 1, maximum: 96),
            (1...Self.maximumChunkCount).contains(count),
            (0..<count).contains(index),
            let decoded = try? BighelpLinkBase64URL.decode(data),
            !decoded.isEmpty,
            decoded.count <= Self.maximumChunkBytes,
            sentAt > 0
        else { throw BighelpLinkWireError.invalidValue }
        self.uploadID = uploadID
        self.sessionID = sessionID
        self.agentID = agentID
        self.reference = reference
        self.index = index
        self.count = count
        self.data = data
        self.sentAt = sentAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            try container.decode(Int.self, forKey: .version) == 1,
            try container.decode(String.self, forKey: .type) == "attachment.chunk"
        else { throw BighelpLinkWireError.invalidValue }
        let reference = try BighelpLinkAttachmentReference(
            attachmentID: container.decode(String.self, forKey: .attachmentID),
            fileName: container.decode(String.self, forKey: .fileName),
            mimeType: container.decode(String.self, forKey: .mimeType),
            totalBytes: container.decode(Int.self, forKey: .totalBytes),
            sha256: container.decode(String.self, forKey: .sha256)
        )
        try self.init(
            uploadID: container.decode(String.self, forKey: .uploadID),
            sessionID: container.decode(String.self, forKey: .sessionID),
            agentID: container.decode(String.self, forKey: .agentID),
            reference: reference,
            index: container.decode(Int.self, forKey: .index),
            count: container.decode(Int.self, forKey: .count),
            data: container.decode(String.self, forKey: .data),
            sentAt: container.decode(Int.self, forKey: .sentAt)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(type, forKey: .type)
        try container.encode(uploadID, forKey: .uploadID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(agentID, forKey: .agentID)
        try container.encode(attachmentID, forKey: .attachmentID)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(totalBytes, forKey: .totalBytes)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(index, forKey: .index)
        try container.encode(count, forKey: .count)
        try container.encode(data, forKey: .data)
        try container.encode(sentAt, forKey: .sentAt)
    }
}
