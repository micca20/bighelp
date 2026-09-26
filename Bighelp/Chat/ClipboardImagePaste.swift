import Foundation
import UIKit
import UniformTypeIdentifiers

/// A paste request captured synchronously from UIKit's public pasteboard API.
/// The providers belong to this exact paste action; import never polls the
/// pasteboard again after asynchronous work begins.
@MainActor
struct ClipboardImagePasteRequest {
    let providers: [NSItemProvider]

    static func capture(from pasteboard: UIPasteboard = .general) -> ClipboardImagePasteRequest? {
        let providers = imageProviders(in: pasteboard.itemProviders)
        guard !providers.isEmpty else { return nil }
        return ClipboardImagePasteRequest(providers: providers)
    }

    static func imageProviders(in providers: [NSItemProvider]) -> [NSItemProvider] {
        providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
    }
}

/// UITextView owns the native Paste / Command-V responder route. Overriding
/// `paste(_:)` keeps text paste entirely native while diverting image providers
/// into the app's ordinary attachment pipeline.
@MainActor
final class ClipboardPasteTextView: UITextView {
    var onPasteImageProviders: (([NSItemProvider]) -> Void)?
    var isClipboardImagePasteEnabled = true

    override func paste(_ sender: Any?) {
        guard let request = ClipboardImagePasteRequest.capture() else {
            super.paste(sender)
            return
        }
        guard
            isClipboardImagePasteEnabled,
            isEditable,
            window != nil,
            let onPasteImageProviders
        else { return }
        onPasteImageProviders(request.providers)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)),
           UIPasteboard.general.hasImages {
            return isClipboardImagePasteEnabled
                && isEditable
                && window != nil
                && onPasteImageProviders != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

@MainActor
final class ClipboardImageImportSession {
    struct Token: Equatable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let target: ObjectIdentifier
    }

    private var generation: UInt64 = 0

    func begin(target: AnyObject) -> Token {
        generation &+= 1
        return Token(generation: generation, target: ObjectIdentifier(target))
    }

    func invalidate() {
        generation &+= 1
    }

    func owns(_ token: Token, target: AnyObject) -> Bool {
        token.generation == generation && token.target == ObjectIdentifier(target)
    }
}

enum ClipboardImageImportError: Error, Equatable, LocalizedError {
    case noReadableImage
    case tooManyImages
    case sourceTooLarge

    var errorDescription: String? {
        switch self {
        case .noReadableImage:
            "bighelp could not read that image from the clipboard. Copy it again and try pasting."
        case .tooManyImages:
            "Paste up to 10 images at a time."
        case .sourceTooLarge:
            "That clipboard image is too large to process. Copy a smaller image and try again."
        }
    }

    static func userMessage(for error: any Error) -> String {
        if let error = error as? ClipboardImageImportError {
            return error.localizedDescription
        }
        if error as? ChatAttachmentError == .invalidSize {
            return "Each attachment can be up to 8 MB, with up to 24 MB in one message."
        }
        if let imageError = error as? ImageAttachmentPreparer.Error {
            switch imageError {
            case .sourceTooLarge, .sourceDimensionsTooLarge, .outputTooLarge:
                return "That image is still too large after preparation. Copy a smaller image and try again."
            case .invalidData, .unsupportedFormat, .processingFailed:
                break
            }
        }
        return "bighelp could not read that image from the clipboard. Copy it again and try pasting."
    }
}

/// The clipboard-facing photo processor produces the same ordinary attachment
/// as camera, Photos, and file import. `ChatAttachmentPreparer` remains the
/// single source of truth for decoding, resizing, encoding, and the 8 MiB cap.
struct ChatImageProcessor: Sendable {
    static func processPhoto(
        data: Data,
        suggestedFileExtension: String,
        suggestedMIMEType: String
    ) throws -> ChatAttachment {
        try ChatAttachmentPreparer().prepare(
            id: "attachment_\(UUID().uuidString.lowercased())",
            fileName: "Clipboard image.\(suggestedFileExtension)",
            mimeType: suggestedMIMEType,
            data: data
        )
    }
}

/// Loads a bounded set of image item providers and runs each through the same
/// image preparation path used by Photos and file attachments.
@MainActor
struct ClipboardImageImporter {
    static let maximumImageCount = 10
    static let maximumInputBytes = ImageAttachmentPreparer.maximumInputBytes

    func importImages(from providers: [NSItemProvider]) async throws -> [ChatAttachment] {
        let imageProviders = ClipboardImagePasteRequest.imageProviders(in: providers)
        guard !imageProviders.isEmpty else {
            throw ClipboardImageImportError.noReadableImage
        }
        guard imageProviders.count <= Self.maximumImageCount else {
            throw ClipboardImageImportError.tooManyImages
        }

        var attachments: [ChatAttachment] = []
        attachments.reserveCapacity(imageProviders.count)
        for provider in imageProviders {
            try Task.checkCancellation()
            let representation = try await loadImageRepresentation(from: provider)
            guard representation.data.count <= Self.maximumInputBytes else {
                throw ClipboardImageImportError.sourceTooLarge
            }
            try Task.checkCancellation()

            let attachment = try await Task.detached(priority: .userInitiated) {
                try ChatImageProcessor.processPhoto(
                    data: representation.data,
                    suggestedFileExtension: representation.fileExtension,
                    suggestedMIMEType: representation.mimeType
                )
            }.value
            try Task.checkCancellation()
            attachments.append(attachment)
        }
        return attachments
    }

    private func loadImageRepresentation(
        from provider: NSItemProvider
    ) async throws -> (data: Data, fileExtension: String, mimeType: String) {
        guard let type = preferredImageType(from: provider) else {
            throw ClipboardImageImportError.noReadableImage
        }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ClipboardImageImportError.noReadableImage)
                }
            }
        }
        try Task.checkCancellation()
        return (
            data,
            type.preferredFilenameExtension ?? "png",
            type.preferredMIMEType ?? "image/png"
        )
    }

    private func preferredImageType(from provider: NSItemProvider) -> UTType? {
        let registered = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        let supported = [UTType.png, .jpeg, .heic, .heif]
        if let exact = supported.first(where: { candidate in
            registered.contains(where: { $0 == candidate })
        }) {
            return exact
        }
        return registered.first(where: { $0.conforms(to: .image) })
            ?? (provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? .image : nil)
    }
}
