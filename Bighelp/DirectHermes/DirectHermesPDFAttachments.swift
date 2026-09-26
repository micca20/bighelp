import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Stock `pdf.attach` limits. bighelp keeps its existing, smaller local-upload
/// ceiling so the first `file.attach` staging request remains bounded by the
/// native websocket transport.
enum DirectHermesPDFAttachmentLimits {
    static let stockMaximumBytes = 50 * 1_024 * 1_024
    static let maximumUploadBytes = ChatAttachment.maximumBytes
    static let maximumPagesPerRequest = 25
    static let maximumDocumentPages = 100_000
}

enum DirectHermesPDFAttachmentError: Error, Equatable, LocalizedError {
    case invalidTarget
    case invalidPDF
    case encryptedPDF
    case fileTooLarge(limit: Int)
    case invalidPageCount
    case invalidPageRange
    case targetChanged

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            "This chat is no longer available for PDF pages. Reopen it and try again."
        case .invalidPDF:
            "Choose a readable PDF document."
        case .encryptedPDF:
            "Password-protected PDFs cannot be attached as pages."
        case .fileTooLarge(let limit):
            "Choose a PDF no larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        case .invalidPageCount:
            "This PDF does not contain a supported number of pages."
        case .invalidPageRange:
            "Choose between 1 and 25 consecutive PDF pages."
        case .targetChanged:
            "The active chat changed. Reopen PDF pages from the current chat."
        }
    }
}

/// Immutable identity for the exact live Hermes session that may receive the
/// queued page images. The generation is checked before and after every RPC.
struct DirectHermesPDFAttachmentTarget: Equatable, Sendable {
    let runtimeID: String
    let profileID: String
    let owner: UUID

    init(runtimeID: String, profileID: String, owner: UUID) throws {
        guard !runtimeID.isEmpty, runtimeID.utf8.count <= 512,
              runtimeID == runtimeID.trimmingCharacters(in: .whitespacesAndNewlines),
              !profileID.isEmpty, profileID.utf8.count <= 512,
              profileID == profileID.trimmingCharacters(in: .whitespacesAndNewlines),
              [runtimeID, profileID].allSatisfy({
                  !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }) else {
            throw DirectHermesPDFAttachmentError.invalidTarget
        }
        self.runtimeID = runtimeID
        self.profileID = profileID
        self.owner = owner
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner == rhs.owner
            && Data(lhs.runtimeID.utf8) == Data(rhs.runtimeID.utf8)
            && Data(lhs.profileID.utf8) == Data(rhs.profileID.utf8)
    }
}

/// Inclusive, one-based range used by stock `pdf.attach`.
struct DirectHermesPDFPageRange: Equatable, Hashable, Sendable {
    let firstPage: Int
    let lastPage: Int

    init(firstPage: Int, lastPage: Int) throws {
        let distance = lastPage.subtractingReportingOverflow(firstPage)
        guard firstPage >= 1, lastPage >= firstPage, !distance.overflow,
              distance.partialValue < DirectHermesPDFAttachmentLimits.maximumPagesPerRequest else {
            throw DirectHermesPDFAttachmentError.invalidPageRange
        }
        self.firstPage = firstPage
        self.lastPage = lastPage
    }

    var count: Int { lastPage - firstPage + 1 }
}

/// A local draft. Creating this value does not call Hermes and never submits a
/// prompt; the conversation owner invokes `attachPDFPages` only from an explicit
/// Send operation.
struct DirectHermesPDFPageSelection: Equatable, Sendable {
    let target: DirectHermesPDFAttachmentTarget
    let attachment: ChatAttachment
    let documentPageCount: Int
    let pageRange: DirectHermesPDFPageRange

    init(
        target: DirectHermesPDFAttachmentTarget,
        attachment: ChatAttachment,
        documentPageCount: Int,
        pageRange: DirectHermesPDFPageRange
    ) throws {
        guard attachment.kind == .file,
              attachment.mimeType == "application/pdf",
              URL(fileURLWithPath: attachment.fileName).pathExtension.lowercased() == "pdf",
              attachment.data.count <= DirectHermesPDFAttachmentLimits.maximumUploadBytes,
              attachment.data.count <= DirectHermesPDFAttachmentLimits.stockMaximumBytes,
              attachment.data.starts(with: Data("%PDF-".utf8)) else {
            throw DirectHermesPDFAttachmentError.invalidPDF
        }
        guard (1...DirectHermesPDFAttachmentLimits.maximumDocumentPages).contains(documentPageCount) else {
            throw DirectHermesPDFAttachmentError.invalidPageCount
        }
        guard pageRange.lastPage <= documentPageCount else {
            throw DirectHermesPDFAttachmentError.invalidPageRange
        }
        self.target = target
        self.attachment = attachment
        self.documentPageCount = documentPageCount
        self.pageRange = pageRange
    }

    func selecting(_ pageRange: DirectHermesPDFPageRange) throws -> Self {
        try Self(
            target: target,
            attachment: attachment,
            documentPageCount: documentPageCount,
            pageRange: pageRange
        )
    }
}

struct DirectHermesPDFPageIdentity: Hashable, Sendable {
    let sourceAttachmentID: String
    let pageNumber: Int
}

/// One image queued by stock `pdf.attach`. The host path is intentionally not
/// exposed; callers receive a typed image receipt rather than a reusable path.
struct DirectHermesPDFPageImageReceipt: Identifiable, Equatable, Sendable {
    let id: DirectHermesPDFPageIdentity
    let image: DirectHermesAttachmentUploadReceipt
    let pageNumber: Int
    let width: Int?
    let height: Int?
    let tokenEstimate: Int?

    fileprivate init(
        sourceAttachmentID: String,
        runtimeID: String,
        pageNumber: Int,
        fileName: String,
        width: Int?,
        height: Int?,
        tokenEstimate: Int?
    ) {
        id = .init(sourceAttachmentID: sourceAttachmentID, pageNumber: pageNumber)
        image = .init(
            kind: .image,
            runtimeID: runtimeID,
            attachmentID: sourceAttachmentID,
            fileName: fileName,
            referenceText: nil
        )
        self.pageNumber = pageNumber
        self.width = width
        self.height = height
        self.tokenEstimate = tokenEstimate
    }
}

/// Validated stock `PdfAttachResult`, retaining server page order exactly.
struct DirectHermesPDFAttachmentReceipt: Equatable, Sendable {
    let target: DirectHermesPDFAttachmentTarget
    let sourceAttachmentID: String
    let fileName: String
    let requestedPageRange: DirectHermesPDFPageRange
    let pages: [DirectHermesPDFPageImageReceipt]
    let totalQueuedImageCount: Int
    let confirmationText: String

    static func decode(
        _ value: BighelpJSONValue,
        selection: DirectHermesPDFPageSelection,
        stagedFileName: String
    ) throws -> Self {
        guard let object = value.object,
              Set(object.keys) == ["attached", "filename", "pages_attached", "pages", "count", "text"],
              object["attached"]?.boolean == true,
              let fileName = object["filename"]?.string,
              fileName.utf8.elementsEqual(stagedFileName.utf8),
              let pagesAttached = object["pages_attached"]?.integer,
              let pageValues = object["pages"]?.array,
              pagesAttached == selection.pageRange.count,
              pageValues.count == pagesAttached,
              let totalCount = object["count"]?.integer,
              totalCount >= pagesAttached,
              let text = object["text"]?.string,
              text == "[User attached PDF: \(fileName) (\(pagesAttached) page(s))]" else {
            throw DirectHermesError.invalidResponse
        }

        var pages: [DirectHermesPDFPageImageReceipt] = []
        pages.reserveCapacity(pageValues.count)
        for (offset, value) in pageValues.enumerated() {
            guard let page = value.object,
                  Set(page.keys).isSubset(of: ["path", "page", "name", "width", "height", "token_estimate"]),
                  page["path"] != nil, page["page"] != nil,
                  let rawPath = page["path"]?.string,
                  let normalizedPath = try? DirectHermesWorkspaceFileScope.path(rawPath),
                  normalizedPath.utf8.elementsEqual(rawPath.utf8),
                  let pageNumber = page["page"]?.integer,
                  pageNumber == selection.pageRange.firstPage + offset else {
                throw DirectHermesError.invalidResponse
            }
            let pathName = rawPath.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/").last.map(String.init)
            let fileName = page["name"]?.string ?? pathName
            guard let fileName, (1...180).contains(fileName.count),
                  pathName.map({ Data(fileName.utf8) == Data($0.utf8) }) == true,
                  URL(fileURLWithPath: fileName).pathExtension.lowercased() == "png",
                  !fileName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw DirectHermesError.invalidResponse
            }
            let width = try optionalPositiveInteger(page["width"])
            let height = try optionalPositiveInteger(page["height"])
            let tokenEstimate = try optionalNonnegativeInteger(page["token_estimate"])
            pages.append(.init(
                sourceAttachmentID: selection.attachment.id,
                runtimeID: selection.target.runtimeID,
                pageNumber: pageNumber,
                fileName: fileName,
                width: width,
                height: height,
                tokenEstimate: tokenEstimate
            ))
        }

        return .init(
            target: selection.target,
            sourceAttachmentID: selection.attachment.id,
            fileName: fileName,
            requestedPageRange: selection.pageRange,
            pages: pages,
            totalQueuedImageCount: totalCount,
            confirmationText: text
        )
    }

    private static func optionalPositiveInteger(_ value: BighelpJSONValue?) throws -> Int? {
        guard let value, value != .null else { return nil }
        guard let integer = value.integer, (1...100_000).contains(integer) else {
            throw DirectHermesError.invalidResponse
        }
        return integer
    }

    private static func optionalNonnegativeInteger(_ value: BighelpJSONValue?) throws -> Int? {
        guard let value, value != .null else { return nil }
        guard let integer = value.integer, (0...100_000_000).contains(integer) else {
            throw DirectHermesError.invalidResponse
        }
        return integer
    }
}

/// Reads only a user-selected security-scoped PDF URL. There is deliberately no
/// host-path or free-form path initializer in this attachment flow.
@MainActor
enum DirectHermesPDFImportPreparer {
    static func prepare(
        url: URL,
        target: DirectHermesPDFAttachmentTarget
    ) async throws -> DirectHermesPDFPageSelection {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()

        let imported = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentTypeKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0 else {
                throw DirectHermesPDFAttachmentError.invalidPDF
            }
            guard size <= DirectHermesPDFAttachmentLimits.maximumUploadBytes else {
                throw DirectHermesPDFAttachmentError.fileTooLarge(
                    limit: DirectHermesPDFAttachmentLimits.maximumUploadBytes
                )
            }
            let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
            guard type?.conforms(to: .pdf) == true,
                  url.pathExtension.lowercased() == "pdf" else {
                throw DirectHermesPDFAttachmentError.invalidPDF
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try Task.checkCancellation()
            guard data.count == size, data.starts(with: Data("%PDF-".utf8)),
                  let document = PDFDocument(data: data) else {
                throw DirectHermesPDFAttachmentError.invalidPDF
            }
            guard !document.isLocked else {
                throw DirectHermesPDFAttachmentError.encryptedPDF
            }
            guard (1...DirectHermesPDFAttachmentLimits.maximumDocumentPages).contains(document.pageCount) else {
                throw DirectHermesPDFAttachmentError.invalidPageCount
            }
            return (data: data, pageCount: document.pageCount, fileName: url.lastPathComponent)
        }.value

        try Task.checkCancellation()
        let attachment = try ChatAttachment(
            id: "attachment_\(UUID().uuidString.lowercased())",
            fileName: imported.fileName,
            mimeType: UTType.pdf.preferredMIMEType ?? "application/pdf",
            data: imported.data
        )
        let range = try DirectHermesPDFPageRange(
            firstPage: 1,
            lastPage: min(imported.pageCount, DirectHermesPDFAttachmentLimits.maximumPagesPerRequest)
        )
        return try .init(
            target: target,
            attachment: attachment,
            documentPageCount: imported.pageCount,
            pageRange: range
        )
    }
}
