#if DEBUG
import Foundation
import UIKit

/// Explicit local preview data only, never inserted into authenticated sessions.
@MainActor
enum GeneratedMediaAcceptanceFixture {
    static func session(mode: String) throws -> SessionRecord {
        if mode == "pdf" {
            let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 360, height: 480)).pdfData { context in
                context.beginPage()
                ("Native attachment preview" as NSString).draw(at: CGPoint(x: 24, y: 30),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
                ("A local PDF fixture for preview and Files export." as NSString).draw(at: CGPoint(x: 24, y: 80),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
            }
            let attachment = try DirectHermesGeneratedMediaClient.attachment(
                .object(["data_url": .string("data:application/pdf;base64," + bytes.base64EncodedString())]),
                path: "/fixture/.hermes/attachments/attachment-preview.pdf", scope: "fixture")
            return attachmentSession(attachment)
        }
        let kind: GeneratedMediaKind = mode == "video" || mode == "invalid-video" ? .video : .image
        let lifecycle: ChatActivityLifecycle = switch mode {
        case "image", "video", "invalid-video": .succeeded
        case "failed": .failed
        case "cancelled": .cancelled
        default: .running
        }
        var resolution: GeneratedMediaResolution?
        if mode == "image" || mode == "attachment-image" {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 288)).image { context in
                UIColor(red: 0.19, green: 0.46, blue: 0.68, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 512, height: 288))
                UIColor(red: 0.65, green: 0.87, blue: 1, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: 150, y: 55, width: 210, height: 180), cornerRadius: 36).fill()
            }
            guard let data = image.pngData() else { throw CocoaError(.fileReadCorruptFile) }
            resolution = .init(state: .ready, attachments: [try ChatAttachment(
                id: "media_fixture_image_0001", fileName: "preview.png", mimeType: "image/png", data: data
            )])
        } else if mode == "video" || mode == "invalid-video" {
            let data: Data
            if mode == "invalid-video" {
                data = Data("not a playable video".utf8)
            } else {
                guard let url = Bundle.main.url(forResource: "generation-preview", withExtension: "mp4") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                data = try Data(contentsOf: url)
            }
            resolution = .init(state: .ready, attachments: [try ChatAttachment(
                id: "media_fixture_video_0001", fileName: "preview.mp4", mimeType: "video/mp4", data: data
            )])
        }
        if mode == "attachment-image", let attachment = resolution?.attachments.first {
            return attachmentSession(attachment)
        }
        let event = ChatActivityEvent(eventID: "media-preview", sessionID: "demo-finance", turnID: "media-preview-turn",
            kind: .tool, lifecycle: lifecycle, title: "Generate preview", summary: nil, detail: nil, occurredAt: 2,
            toolCallID: "media_preview_call", toolName: kind == .image ? "image_generate" : "video_generate",
            generatedMedia: resolution, sourceOrder: 2)
        return SessionRecord(id: "demo-finance", kind: .direct, agentIDs: ["finance"], title: "Generation preview",
            items: [TimelineItem(id: "media-preview-prompt", role: .human, sender: .user(snapshot: .init(name: "You")),
                content: .message("Local preview of the generation card."), metadata: .init(sourceOrder: 1))],
            activityEvents: [event], hasAcceptedMessage: true)
    }
    private static func attachmentSession(_ attachment: ChatAttachment) -> SessionRecord {
        SessionRecord(id: "demo-finance", kind: .direct, agentIDs: ["finance"], title: "Attachment preview",
            items: [TimelineItem(id: "attachment-answer", role: .assistant,
                sender: .agent(id: "finance", snapshot: .init(name: "Studio")),
                content: .message("Your file is ready."), metadata: .init(sourceOrder: 1), attachments: [attachment])],
            hasAcceptedMessage: true)
    }
}
#endif
