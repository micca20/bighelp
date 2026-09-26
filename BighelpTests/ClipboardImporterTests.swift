import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Bighelp

@MainActor
struct ClipboardImporterTests {
    private func png() throws -> Data {
        try #require(UIGraphicsImageRenderer(size: CGSize(width: 16, height: 12)).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        }.pngData())
    }

    @Test func providerUsesNormalAttachmentNormalizationAndBounds() async throws {
        let data = try png()
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
        let attachments = try await ClipboardImageImporter().importImages(from: [provider])
        let attachment = try #require(attachments.first)
        #expect(attachments.count == 1)
        #expect(attachment.kind == .image)
        #expect(UIImage(data: attachment.data) != nil)
        #expect(attachment.data.count <= ChatAttachment.maximumBytes)
        #expect(attachment.fileName.hasPrefix("Clipboard image."))
    }

    @Test func invalidImageAndExcessiveProviderCountFailWithoutAttachments() async throws {
        let bad = NSItemProvider(item: Data("not an image".utf8) as NSData, typeIdentifier: UTType.png.identifier)
        do {
            _ = try await ClipboardImageImporter().importImages(from: [bad])
            Issue.record("Spoofed image bytes must be rejected")
        } catch { }
        do {
            _ = try await ClipboardImageImporter().importImages(from: Array(repeating: bad, count: 11))
            Issue.record("Excessive provider count must be rejected")
        } catch {
            #expect(error as? ClipboardImageImportError == .tooManyImages)
        }
    }

    @Test func importOwnershipRejectsReplacementAndDismissedDestinations() {
        let first = NSObject()
        let second = NSObject()
        let ownership = ClipboardImageImportSession()
        let token = ownership.begin(target: first)
        #expect(ownership.owns(token, target: first))
        #expect(!ownership.owns(token, target: second))
        ownership.invalidate()
        #expect(!ownership.owns(token, target: first))
        let next = ownership.begin(target: second)
        #expect(ownership.owns(next, target: second))
        #expect(!ownership.owns(token, target: first))
    }
}
