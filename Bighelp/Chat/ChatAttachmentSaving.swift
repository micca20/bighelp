import AVFoundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

enum ChatAttachmentAction: Equatable, Sendable {
    case preview
    case save
}

enum ChatAttachmentActionPolicy {
    static func actions(for destination: ChatAttachmentSaveDestination) -> [ChatAttachmentAction] {
        destination.canSave ? [.preview, .save] : [.preview]
    }
}

enum ChatAttachmentSaveDestination: Equatable, Sendable {
    case photosImage
    case photosVideo
    case files
    case unavailable(ChatAttachmentSaveError)

    var canSave: Bool {
        if case .unavailable = self { return false }
        return true
    }

    var accessibilityLabel: String {
        switch self {
        case .photosImage:
            "Save Image"
        case .photosVideo:
            "Save Video"
        case .files:
            "Save to Files"
        case .unavailable:
            "Save unavailable"
        }
    }
}

enum ChatAttachmentSaveError: Error, Equatable, Sendable {
    case invalidImage
    case invalidVideo
    case temporaryResource
    case photoLibraryRejectedResource

    var message: String {
        switch self {
        case .invalidImage:
            "This attachment is not a valid image and cannot be saved to Photos."
        case .invalidVideo:
            "This attachment is not a playable video and cannot be saved to Photos."
        case .temporaryResource:
            "This attachment could not be prepared for saving."
        case .photoLibraryRejectedResource:
            "Photos rejected this media resource."
        }
    }
}

struct ChatAttachmentSaveActivity: Equatable, Sendable {
    private(set) var isBusy = false

    mutating func begin() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    mutating func finish() {
        isBusy = false
    }
}

enum ChatAttachmentPhotosAuthorizationRecovery {
    static func requiresSettings(_ status: PHAuthorizationStatus) -> Bool {
        status == .denied || status == .restricted
    }
}

@MainActor
protocol ChatAttachmentVideoValidating {
    func isPlayableVideo(at url: URL) async -> Bool
}

struct LiveChatAttachmentVideoValidator: ChatAttachmentVideoValidating {
    func isPlayableVideo(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            return isPlayable && !videoTracks.isEmpty
        } catch {
            return false
        }
    }
}

@MainActor
enum ChatAttachmentMediaValidator {
    static func destination(
        for attachment: ChatAttachment,
        videoValidator: any ChatAttachmentVideoValidating = LiveChatAttachmentVideoValidator()
    ) async -> ChatAttachmentSaveDestination {
        let mimeType = attachment.mimeType.lowercased()
        let declaredType = UTType(mimeType: mimeType)
        let claimsImage = mimeType.hasPrefix("image/") || declaredType?.conforms(to: .image) == true
        let claimsVideo = mimeType.hasPrefix("video/") || declaredType?.conforms(to: .movie) == true

        if claimsImage {
            return isDecodableImage(attachment.data) ? .photosImage : .unavailable(.invalidImage)
        }
        if claimsVideo {
            do {
                let resource = try ChatAttachmentTemporaryResource(
                    data: attachment.data,
                    fileName: attachment.fileName,
                    purpose: "video-validation"
                )
                defer { resource.remove() }
                return await videoValidator.isPlayableVideo(at: resource.url)
                    ? .photosVideo
                    : .unavailable(.invalidVideo)
            } catch {
                return .unavailable(.temporaryResource)
            }
        }
        return .files
    }

    static func isDecodableImage(_ data: Data) -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard
            let source = CGImageSourceCreateWithData(data as CFData, options),
            CGImageSourceGetCount(source) > 0,
            let sourceType = CGImageSourceGetType(source),
            let payloadType = UTType(sourceType as String),
            payloadType.conforms(to: .image),
            CGImageSourceCreateImageAtIndex(source, 0, options) != nil
        else { return false }
        return true
    }
}

protocol ChatAttachmentPhotoLibraryWriting: Sendable {
    func addImage(_ data: Data) async throws
    func addVideo(at url: URL) async throws
}

struct LiveChatAttachmentPhotoLibraryWriter: ChatAttachmentPhotoLibraryWriting {
    func addImage(_ data: Data) async throws {
        let resourceData = data
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: resourceData, options: nil)
        }
    }

    func addVideo(at url: URL) async throws {
        let resourceURL = url
        final class RequestState: @unchecked Sendable {
            var created = false
        }
        let state = RequestState()
        try await PHPhotoLibrary.shared().performChanges {
            state.created = PHAssetChangeRequest.creationRequestForAssetFromVideo(
                atFileURL: resourceURL
            ) != nil
        }
        guard state.created else {
            throw ChatAttachmentSaveError.photoLibraryRejectedResource
        }
    }
}

@MainActor
enum ChatAttachmentPhotosSaver {
    static func saveImage(
        _ data: Data,
        writer: any ChatAttachmentPhotoLibraryWriting = LiveChatAttachmentPhotoLibraryWriter()
    ) async throws {
        guard ChatAttachmentMediaValidator.isDecodableImage(data) else {
            throw ChatAttachmentSaveError.invalidImage
        }
        try await writer.addImage(data)
    }

    static func saveVideo(
        data: Data,
        fileName: String,
        videoValidator: any ChatAttachmentVideoValidating = LiveChatAttachmentVideoValidator(),
        writer: any ChatAttachmentPhotoLibraryWriting = LiveChatAttachmentPhotoLibraryWriter()
    ) async throws {
        let resource: ChatAttachmentTemporaryResource
        do {
            resource = try ChatAttachmentTemporaryResource(
                data: data,
                fileName: fileName,
                purpose: "photos-video"
            )
        } catch {
            throw ChatAttachmentSaveError.temporaryResource
        }
        defer { resource.remove() }
        guard await videoValidator.isPlayableVideo(at: resource.url) else {
            throw ChatAttachmentSaveError.invalidVideo
        }
        try await writer.addVideo(at: resource.url)
    }
}

final class ChatAttachmentTemporaryResource {
    let url: URL
    private let directoryURL: URL
    private var isRemoved = false

    init(data: Data, fileName: String, purpose: String) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-\(purpose)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        url = directoryURL.appending(path: fileName, directoryHint: .notDirectory)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    func remove() {
        guard !isRemoved else { return }
        isRemoved = true
        try? FileManager.default.removeItem(at: directoryURL)
    }

    deinit {
        remove()
    }
}
