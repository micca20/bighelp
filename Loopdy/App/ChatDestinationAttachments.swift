import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Attachment work remains bound to the existing conversation and view state.
extension ChatDestinationView {
    func performChatAction(_ action: ChatActionMenuAction) {
        switch action {
            case .camera:
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    attachmentRecoveryKind = nil
                    attachmentErrorMessage = "Camera capture is unavailable on this device."
                    return
                }
                Task {
                    guard await permissionCenter.authorizeContextualAccess(.camera) else {
                        attachmentRecoveryKind = .camera
                        attachmentErrorMessage = "Camera access is unavailable. You can change it in iOS Settings."
                        return
                    }
                    reflectiveVisionCamera?.suspend()
                    isCameraPickerPresented = true
                }
            case .scanDocument:
                guard ChatDocumentScanner.isSupported, model.supportedAttachmentKinds.contains(.file),
                      model.draftAttachments.count < 10 else {
                    attachmentErrorMessage = "Document scanning requires a supported camera and space for a PDF attachment."
                    return
                }
                let members = model.memberIDs
                Task { @MainActor in
                    guard await permissionCenter.authorizeContextualAccess(.camera) else {
                        attachmentRecoveryKind = .camera
                        attachmentErrorMessage = "Camera access is unavailable. You can change it in iOS Settings."
                        return
                    }
                    guard appState.activeConversationID == model.conversationID,
                          model.memberIDs == members else { return }
                    documentScanMembers = members
                    documentScanResult = nil
                    reflectiveVisionCamera?.suspend()
                    isDocumentScannerPresented = true
                }
            case .photo:
                isPhotoPickerPresented = true
            case .file:
                isFilePickerPresented = true
            case .voice:
                attachmentFlow.isActionMenuPresented = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    voicePresentation = featureStore.makeVoicePresentation(
                        for: model.conversationID,
                        mode: settings.voiceMode,
                        conversationMode: settings.voiceConversationMode,
                        liveProvider: settings.liveVoiceProvider,
                        liveVoice: settings.liveVoice(for: settings.liveVoiceProvider)
                    )
                }
            case .startSession:
                attachmentFlow.isActionMenuPresented = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    onStartSession()
                }
            case .chooseAgent, .skillsAndTools, .changeModel, .workspace:
                // These actions are owned by nested pages inside the drawer.
                break
            }
    }

    func finishDocumentScan() {
        defer {
            documentScanResult = nil
            Task { await reflectiveVisionCamera?.update(enabled: reflectiveVisionEnabled) }
        }
        guard let result = documentScanResult,
              appState.activeConversationID == model.conversationID,
              model.memberIDs == documentScanMembers else { return }
        do {
            try model.addDraftAttachment(result.get())
            attachmentFlow.completeSuccessfulImport()
        } catch is CancellationError {
            return
        } catch {
            attachmentErrorMessage = (error as? ChatScannedDocument.ScanError)?.localizedDescription
                ?? attachmentErrorDescription(error)
        }
    }

    func importCameraImage(_ image: UIImage) {
        do {
            guard let data = image.jpegData(compressionQuality: 1) else {
                throw ChatAttachmentError.invalidSize
            }
            let attachment = try ChatAttachmentPreparer().prepare(
                id: Self.attachmentID(),
                fileName: "camera-\(UUID().uuidString.lowercased()).jpg",
                mimeType: "image/jpeg",
                data: data
            )
            try model.addDraftAttachment(attachment)
            attachmentFlow.completeSuccessfulImport()
        } catch {
            attachmentErrorMessage = attachmentErrorDescription(error)
        }
    }

    func attachReference(to summary: SessionSummary) async {
        do {
            let record = try await catalog.hydrateSession(id: summary.id)
            let body = try ChatReferenceDocumentBuilder.markdown(for: record)
            let attachment = try ChatAttachment(
                id: Self.attachmentID(),
                fileName: ChatReferenceDocumentBuilder.fileName(for: record),
                mimeType: "text/markdown",
                data: Data(body.utf8)
            )
            try model.addDraftAttachment(attachment)
            attachmentFlow.completeSuccessfulImport()
        } catch {
            attachmentErrorMessage = attachmentErrorDescription(error)
        }
    }

    func importPhotos(_ selections: [PhotosPickerItem]) async {
        defer { photoSelections = [] }
        for selection in selections {
            do {
                guard let data = try await selection.loadTransferable(type: Data.self) else {
                    throw ChatAttachmentError.invalidSize
                }
                let type = selection.supportedContentTypes.first ?? .jpeg
                let extensionValue = type.preferredFilenameExtension ?? "jpg"
                let attachment = try ChatAttachmentPreparer().prepare(
                    id: Self.attachmentID(),
                    fileName: "image-\(UUID().uuidString.lowercased()).\(extensionValue)",
                    mimeType: type.preferredMIMEType ?? "image/jpeg",
                    data: data
                )
                try model.addDraftAttachment(attachment)
            } catch {
                attachmentErrorMessage = attachmentErrorDescription(error)
                return
            }
        }
        attachmentFlow.completeSuccessfulImport()
    }

    func importFiles(_ result: Result<[URL], any Error>) {
        do {
            for url in try result.get() {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
                    ?? UTType(filenameExtension: url.pathExtension)
                    ?? .data
                let attachment = try ChatAttachmentPreparer().prepare(
                    id: Self.attachmentID(),
                    fileName: url.lastPathComponent,
                    mimeType: type.preferredMIMEType ?? "application/octet-stream",
                    data: data
                )
                try model.addDraftAttachment(attachment)
            }
            attachmentFlow.completeSuccessfulImport()
        } catch {
            attachmentErrorMessage = attachmentErrorDescription(error)
        }
    }

    func attachmentErrorDescription(_ error: any Error) -> String {
        if error as? ChatAttachmentError == .unsupportedClient { return error.localizedDescription }
        if error as? ChatAttachmentError == .unsupportedKind { return DirectHermesFileAttachments.imagesUnavailable }
        if error as? ChatAttachmentError == .invalidSize {
            return "Each attachment can be up to 8 MB, with up to 24 MB in one message."
        }
        if let imageError = error as? ImageAttachmentPreparer.Error {
            switch imageError {
            case .sourceTooLarge, .sourceDimensionsTooLarge, .outputTooLarge:
                return "That image is still too large after preparation. Choose a smaller photo and try again."
            case .invalidData, .unsupportedFormat, .processingFailed:
                break
            }
        }
        return "bighelp could not read that attachment. Choose another file and try again."
    }

    static func attachmentID() -> String {
        "attachment_\(UUID().uuidString.lowercased())"
    }

}
