import Foundation
import ImageIO

struct DirectHermesAttachmentUploadReceipt: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case image
        case file
    }

    let kind: Kind
    let runtimeID: String
    let attachmentID: String
    let fileName: String
    /// Files are represented by Hermes' opaque context reference. Image
    /// attachments are already queued on the session and have no prompt ref.
    let referenceText: String?
}

/// Owns one direct-Hermes attachment upload and validates the host receipt.
///
/// Hermes' `image.attach_bytes` stages image bytes in the current TUI session,
/// while `file.attach` stages a non-image file and returns an `@file:` context
/// reference. Host paths are never exposed to callers; PDF pages may pass the
/// validated staging receipt's path directly into stock `pdf.attach`.
@MainActor
final class DirectHermesAttachmentClient {
    private let rpc: any DirectHermesRPC
    private let currentOwner: @MainActor () -> UUID?
    private let currentPDFTarget: (@MainActor () -> DirectHermesPDFAttachmentTarget?)?

    init(rpc: any DirectHermesRPC, currentOwner: @escaping @MainActor () -> UUID?) {
        self.rpc = rpc
        self.currentOwner = currentOwner
        currentPDFTarget = nil
    }

    /// PDF pages require the complete live-session identity, not only a
    /// connection generation. The conversation owner supplies this closure so
    /// a reconnect, profile switch, or runtime replacement retires the draft.
    init(
        rpc: any DirectHermesRPC,
        currentPDFTarget: @escaping @MainActor () -> DirectHermesPDFAttachmentTarget?
    ) {
        self.rpc = rpc
        self.currentPDFTarget = currentPDFTarget
        currentOwner = { currentPDFTarget()?.owner }
    }

    func upload(
        _ attachment: ChatAttachment,
        runtimeID: String,
        owner: UUID
    ) async throws -> DirectHermesAttachmentUploadReceipt {
        try checkOwner(owner, beforeRequest: true)
        try Self.validateRuntimeID(runtimeID)
        try Self.validateAttachment(attachment)

        let method: String
        let params: [String: LoopdyJSONValue]
        switch attachment.kind {
        case .image:
            method = "image.attach_bytes"
            params = Self.imagePayload(attachment, runtimeID: runtimeID)
        case .file:
            method = "file.attach"
            params = DirectHermesFileAttachments.payload(attachment, runtimeID: runtimeID)
        }

        let response: LoopdyJSONValue
        do {
            response = try await rpc.request(method, params: params)
        } catch {
            try checkOwner(owner, beforeRequest: false)
            throw error
        }
        try checkOwner(owner, beforeRequest: false)

        switch attachment.kind {
        case .image:
            try Self.validateImageReceipt(response, byteCount: attachment.data.count)
            let name = try Self.imageName(response)
            return DirectHermesAttachmentUploadReceipt(
                kind: .image, runtimeID: runtimeID, attachmentID: attachment.id,
                fileName: name, referenceText: nil
            )
        case .file:
            let reference = try DirectHermesFileAttachments.reference(response)
            let name = response.object?["name"]?.string ?? attachment.fileName
            return DirectHermesAttachmentUploadReceipt(
                kind: .file, runtimeID: runtimeID, attachmentID: attachment.id,
                fileName: try Self.fileName(name), referenceText: reference
            )
        }
    }

    /// Stages the selected PDF through the existing bounded `file.attach`
    /// upload, then passes only that authenticated host receipt's resolved path
    /// to stock `pdf.attach`. This method queues images; it never submits a
    /// prompt. The caller must invoke it only from an explicit Send operation.
    func attachPDFPages(
        _ selection: DirectHermesPDFPageSelection
    ) async throws -> DirectHermesPDFAttachmentReceipt {
        try Task.checkCancellation()
        try checkPDFTarget(selection.target, beforeRequest: true)
        try Self.validatePDFSelection(selection)

        let stagedResponse: LoopdyJSONValue
        do {
            stagedResponse = try await rpc.request(
                "file.attach",
                params: DirectHermesFileAttachments.payload(
                    selection.attachment,
                    runtimeID: selection.target.runtimeID
                )
            )
        } catch {
            try checkPDFTarget(selection.target, beforeRequest: false)
            throw error
        }
        try checkPDFTarget(selection.target, beforeRequest: false)
        let staged = try Self.stagedPDFSource(
            stagedResponse,
            expectedFileName: selection.attachment.fileName
        )
        try Task.checkCancellation()
        try checkPDFTarget(selection.target, beforeRequest: true)

        let response: LoopdyJSONValue
        do {
            response = try await rpc.request("pdf.attach", params: [
                "session_id": .string(selection.target.runtimeID),
                "profile": .string(selection.target.profileID),
                "path": .string(staged.path),
                "first_page": .integer(selection.pageRange.firstPage),
                "last_page": .integer(selection.pageRange.lastPage),
            ])
        } catch {
            try checkPDFTarget(selection.target, beforeRequest: false)
            throw error
        }
        try checkPDFTarget(selection.target, beforeRequest: false)
        if Task.isCancelled {
            // The host may already have queued every page. Do not return a
            // receipt that a cancelled send path could accidentally submit.
            throw DirectHermesError.cancelled(outcomeUnknown: true)
        }
        return try DirectHermesPDFAttachmentReceipt.decode(
            response,
            selection: selection,
            stagedFileName: staged.fileName
        )
    }

    private func checkOwner(_ owner: UUID, beforeRequest: Bool) throws {
        guard currentOwner() == owner else {
            throw beforeRequest
                ? DirectHermesError.notConnected
                : DirectHermesError.disconnected(outcomeUnknown: true)
        }
    }

    private func checkPDFTarget(
        _ target: DirectHermesPDFAttachmentTarget,
        beforeRequest: Bool
    ) throws {
        guard let current = currentPDFTarget?(), current.owner == target.owner,
              Data(current.runtimeID.utf8) == Data(target.runtimeID.utf8),
              Data(current.profileID.utf8) == Data(target.profileID.utf8) else {
            throw beforeRequest
                ? DirectHermesError.notConnected
                : DirectHermesError.disconnected(outcomeUnknown: true)
        }
    }

    /// The websocket transport uses this allowlist to raise its frame budget
    /// only for bounded, base64 attachment payloads. No caller supplied method
    /// can widen the transport limits.
    static func permitsLargeFrame(method: String, params: [String: LoopdyJSONValue]) -> Bool {
        if method == "file.attach" {
            return DirectHermesFileAttachments.permitsLargeFrame(method: method, params: params)
        }
        guard method == "image.attach_bytes", Set(params.keys) == ["session_id", "filename", "content_base64"],
              let session = params["session_id"]?.string, !session.isEmpty, session.utf8.count <= 512,
              let filename = params["filename"]?.string, (1...180).contains(filename.count),
              filename == URL(fileURLWithPath: filename).lastPathComponent,
              let base64 = params["content_base64"]?.string, !base64.isEmpty,
              base64.utf8.count <= ((ChatAttachment.maximumBytes + 2) / 3) * 4,
              base64.utf8.allSatisfy({
                  ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                  ($0 >= 48 && $0 <= 57) || $0 == 43 || $0 == 47 || $0 == 61
              }) else {
            return false
        }
        return true
    }

    static func validate(_ attachments: [ChatAttachment], message: String) throws {
        guard !attachments.isEmpty, attachments.count <= 10,
              Set(attachments.map(\.id)).count == attachments.count,
              message.utf8.count <= 1_048_576 else {
            throw DirectHermesError.messageTooLarge
        }
        var total = 0
        for attachment in attachments {
            try validateAttachment(attachment)
            let sum = total.addingReportingOverflow(attachment.data.count)
            guard !sum.overflow, sum.partialValue <= DirectHermesFileAttachments.maximumBatchBytes else {
                throw ChatAttachmentError.invalidSize
            }
            total = sum.partialValue
        }
    }

    private static func validateRuntimeID(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 512,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DirectHermesError.invalidResponse
        }
    }

    private static func validateAttachment(_ attachment: ChatAttachment) throws {
        guard (1...ChatAttachment.maximumBytes).contains(attachment.data.count),
              attachment.fileName.utf8.count <= 180 else {
            throw ChatAttachmentError.invalidSize
        }
        if attachment.kind == .image {
            guard let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
                throw ChatAttachmentError.unsupportedKind
            }
        } else {
            try DirectHermesFileAttachments.validate([attachment], message: "")
        }
    }

    private static func validatePDFSelection(
        _ selection: DirectHermesPDFPageSelection
    ) throws {
        try validateRuntimeID(selection.target.runtimeID)
        guard !selection.target.profileID.isEmpty,
              selection.target.profileID.utf8.count <= 512,
              selection.target.profileID == selection.target.profileID
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !selection.target.profileID.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
              ) else {
            throw DirectHermesPDFAttachmentError.invalidTarget
        }
        try validateAttachment(selection.attachment)
        guard selection.attachment.mimeType == "application/pdf",
              URL(fileURLWithPath: selection.attachment.fileName).pathExtension.lowercased() == "pdf",
              selection.attachment.data.count <= DirectHermesPDFAttachmentLimits.maximumUploadBytes,
              selection.attachment.data.starts(with: Data("%PDF-".utf8)),
              selection.pageRange.lastPage <= selection.documentPageCount else {
            throw DirectHermesPDFAttachmentError.invalidPDF
        }
    }

    private struct StagedPDFSource {
        let path: String
        let fileName: String
    }

    /// Accepts a path only from the validated result of the fixed
    /// `file.attach` call above. No public/raw host-path entry point exists.
    private static func stagedPDFSource(
        _ value: LoopdyJSONValue,
        expectedFileName: String
    ) throws -> StagedPDFSource {
        _ = try DirectHermesFileAttachments.reference(value)
        guard let object = value.object,
              Set(object.keys) == ["attached", "name", "path", "ref_path", "ref_text", "uploaded"],
              let path = object["path"]?.string,
              let normalizedPath = try? DirectHermesWorkspaceFileScope.path(path),
              Data(normalizedPath.utf8) == Data(path.utf8),
              let name = object["name"]?.string,
              path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last
                .map({ Data(String($0).utf8) == Data(name.utf8) }) == true,
              URL(fileURLWithPath: name).pathExtension.lowercased() == "pdf",
              isExpectedStagedName(name, original: expectedFileName) else {
            throw DirectHermesError.invalidResponse
        }
        return .init(path: path, fileName: try fileName(name))
    }

    private static func isExpectedStagedName(_ staged: String, original: String) -> Bool {
        if Data(staged.utf8) == Data(original.utf8) { return true }
        let stagedURL = URL(fileURLWithPath: staged)
        let originalURL = URL(fileURLWithPath: original)
        guard stagedURL.pathExtension.lowercased() == originalURL.pathExtension.lowercased() else {
            return false
        }
        let stagedStem = stagedURL.deletingPathExtension().lastPathComponent
        let originalStem = originalURL.deletingPathExtension().lastPathComponent
        let prefix = originalStem + "-"
        guard stagedStem.hasPrefix(prefix),
              let suffix = Int(stagedStem.dropFirst(prefix.count)), suffix >= 2 else {
            return false
        }
        return true
    }

    private static func imagePayload(_ attachment: ChatAttachment, runtimeID: String) -> [String: LoopdyJSONValue] {
        [
            "session_id": .string(runtimeID),
            "filename": .string(attachment.fileName),
            "content_base64": .string(attachment.data.base64EncodedString())
        ]
    }

    private static func validateImageReceipt(_ value: LoopdyJSONValue, byteCount: Int) throws {
        guard let object = value.object,
              object["attached"]?.boolean == true,
              let path = object["path"]?.string,
              let name = object["name"]?.string,
              let count = object["count"]?.integer,
              let bytes = object["bytes"]?.integer,
              (1...256).contains(count), bytes == byteCount,
              path.utf8.count <= 4_096,
              !path.isEmpty, !name.isEmpty,
              name.utf8.count <= 180,
              path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) == name,
              [path, name].allSatisfy({
                  !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }) else {
            throw DirectHermesError.invalidResponse
        }
        if let text = object["text"]?.string {
            guard text.utf8.count <= 8_192,
                  !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw DirectHermesError.invalidResponse
            }
        }
    }

    private static func imageName(_ value: LoopdyJSONValue) throws -> String {
        guard let name = value.object?["name"]?.string else { throw DirectHermesError.invalidResponse }
        return try fileName(name)
    }

    private static func fileName(_ value: String) throws -> String {
        guard (1...180).contains(value.count), value == URL(fileURLWithPath: value).lastPathComponent,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DirectHermesError.invalidResponse
        }
        return value
    }
}
