import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesAttachmentClientTests {
    @Test func imageUploadUsesOfficialImageAttachBytesAndReturnsPathFreeReceipt() async throws {
        let fixture = try Fixture()
        let image = try Self.png()
        let attachment = try ChatAttachment(
            id: "attachment_image_fixture", fileName: "photo.png", mimeType: "image/png", data: image
        )
        fixture.rpc.response = .object([
            "attached": .boolean(true), "path": .string("/private/hermes/images/upload_123.png"),
            "name": .string("upload_123.png"), "count": .integer(1), "bytes": .integer(image.count),
            "text": .string("[User attached image: upload_123.png]")
        ])
        let receipt = try await fixture.client.upload(attachment, runtimeID: "runtime", owner: fixture.owner)

        #expect(receipt.kind == .image)
        #expect(receipt.runtimeID == "runtime")
        #expect(receipt.attachmentID == attachment.id)
        #expect(receipt.fileName == "upload_123.png")
        #expect(receipt.referenceText == nil)
        #expect(fixture.rpc.calls.map(\.method) == ["image.attach_bytes"])
        #expect(fixture.rpc.calls[0].params["session_id"] == .string("runtime"))
        #expect(fixture.rpc.calls[0].params["filename"] == .string("photo.png"))
        #expect(fixture.rpc.calls[0].params["content_base64"] == .string(image.base64EncodedString()))
        #expect(fixture.rpc.calls[0].params["data_url"] == nil)
    }

    @Test func ordinaryFileUploadRetainsOpaqueFileReferenceReceipt() async throws {
        let fixture = try Fixture()
        let attachment = try ChatAttachment(
            id: "attachment_file_fixture", fileName: "report.txt", mimeType: "text/plain", data: Data("hello".utf8)
        )
        fixture.rpc.response = .object([
            "attached": .boolean(true), "uploaded": .boolean(true), "name": .string("report.txt"),
            "path": .string("/private/hermes/attachments/report.txt"),
            "ref_path": .string("/private/hermes/attachments/report.txt"),
            "ref_text": .string("@file:`/private/hermes/attachments/report.txt`")
        ])
        let receipt = try await fixture.client.upload(attachment, runtimeID: "runtime", owner: fixture.owner)

        #expect(receipt.kind == .file)
        #expect(receipt.fileName == "report.txt")
        #expect(receipt.referenceText == "@file:`/private/hermes/attachments/report.txt`")
        #expect(fixture.rpc.calls[0].method == "file.attach")
        #expect(fixture.rpc.calls[0].params["data_url"] == .string("data:text/plain;base64,aGVsbG8="))
    }

    @Test func malformedImageReceiptCannotBecomeAnAcceptedUpload() async throws {
        let fixture = try Fixture()
        let image = try Self.png()
        let attachment = try ChatAttachment(
            id: "attachment_image_fixture", fileName: "photo.png", mimeType: "image/png", data: image
        )
        fixture.rpc.response = .object([
            "attached": .boolean(true), "path": .string("/private/hermes/images/upload_123.png"),
            "name": .string("upload_123.png"), "count": .integer(1), "bytes": .integer(image.count + 1)
        ])
        await #expect(throws: DirectHermesError.invalidResponse) {
            _ = try await fixture.client.upload(attachment, runtimeID: "runtime", owner: fixture.owner)
        }
    }

    @Test func ownerChangeAfterHostReceiptIsOutcomeUnknownAndCannotReturnReceipt() async throws {
        let fixture = try Fixture()
        let attachment = try ChatAttachment(
            id: "attachment_file_fixture", fileName: "report.txt", mimeType: "text/plain", data: Data("hello".utf8)
        )
        fixture.rpc.response = .object([
            "attached": .boolean(true), "uploaded": .boolean(true), "name": .string("report.txt"),
            "path": .string("/private/hermes/attachments/report.txt"),
            "ref_path": .string("/private/hermes/attachments/report.txt"),
            "ref_text": .string("@file:`/private/hermes/attachments/report.txt`")
        ])
        fixture.rpc.afterResponse = { fixture.owner = UUID() }

        await #expect(throws: DirectHermesError.disconnected(outcomeUnknown: true)) {
            _ = try await fixture.client.upload(attachment, runtimeID: "runtime", owner: fixture.initialOwner)
        }
    }

    @Test func batchValidationAllowsImagesAndFilesBeforeAnyUpload() throws {
        let image = try Self.png()
        let imageAttachment = try ChatAttachment(
            id: "attachment_image_fixture", fileName: "photo.png", mimeType: "image/png", data: image
        )
        let fileAttachment = try ChatAttachment(
            id: "attachment_file_fixture", fileName: "report.txt", mimeType: "text/plain", data: Data("hello".utf8)
        )
        try DirectHermesAttachmentClient.validate(
            [imageAttachment, fileAttachment], message: "Caption"
        )
    }

    @Test func imageFrameAllowlistAcceptsOnlyBoundedOfficialPayload() throws {
        let image = try Self.png()
        let valid: [String: BighelpJSONValue] = [
            "session_id": .string("runtime"), "filename": .string("photo.png"),
            "content_base64": .string(image.base64EncodedString())
        ]
        #expect(DirectHermesAttachmentClient.permitsLargeFrame(method: "image.attach_bytes", params: valid))
        var extra = valid
        extra["mime_type"] = .string("image/png")
        #expect(!DirectHermesAttachmentClient.permitsLargeFrame(method: "image.attach_bytes", params: extra))
        #expect(!DirectHermesAttachmentClient.permitsLargeFrame(method: "image.attach_bytes", params: [
            "session_id": .string("runtime"), "filename": .string("photo.png"),
            "content_base64": .string(String(repeating: "A", count: 12 * 1_024 * 1_024))
        ]))
    }

    @Test func nonImageBytesWithImageMimeAreRejectedBeforeHostCall() async throws {
        let fixture = try Fixture()
        let attachment = try ChatAttachment(
            id: "attachment_image_fixture", fileName: "photo.png", mimeType: "image/png", data: Data("not image".utf8)
        )
        await #expect(throws: ChatAttachmentError.unsupportedKind) {
            _ = try await fixture.client.upload(attachment, runtimeID: "runtime", owner: fixture.owner)
        }
        #expect(fixture.rpc.calls.isEmpty)
    }

    private static func png() throws -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }

    @MainActor
    private final class Fixture {
        let initialOwner = UUID()
        var owner: UUID
        let rpc = RPC()
        lazy var client = DirectHermesAttachmentClient(rpc: rpc, currentOwner: { [weak self] in self?.owner })

        init() {
            owner = initialOwner
        }
    }

    @MainActor
    private final class RPC: DirectHermesRPC {
        struct Call {
            let method: String
            let params: [String: BighelpJSONValue]
        }

        var onEvent: ((DirectHermesEvent) -> Void)?
        var calls: [Call] = []
        var response: BighelpJSONValue = .object([:])
        var afterResponse: (() -> Void)?

        func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            calls.append(Call(method: method, params: params))
            let response = self.response
            afterResponse?()
            return response
        }

        func disconnect() async {}
    }
}
