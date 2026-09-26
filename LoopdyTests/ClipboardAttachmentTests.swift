import SwiftUI
import Testing
import UIKit
@testable import Loopdy

@Suite(.serialized)
@MainActor
struct ClipboardAttachmentTests {
    @Test func expandedRichPasteControlStagesImageWithoutSending() async throws {
        let model = ChatModel(conversationID: "rich-clipboard-proof", client: ConversationFixtureClient())
        model.draft = "Rich **draft**"
        let root = ExpandedDraftEditor(model: model, agentName: "Fixture", onAttachmentTap: nil, onSend: {})
            .environment(\.loopdyUIV2Enabled, true)
        let controller = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(400))
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func targets(_ view: UIView) -> [ClipboardImagePasteControl.TargetView] {
            (view as? ClipboardImagePasteControl.TargetView).map { [$0] } ?? view.subviews.flatMap(targets)
        }
        let target = try #require(targets(controller.view).first)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        let data = try #require(image.pngData())
        target.paste(itemProviders: [NSItemProvider(item: data as NSData, typeIdentifier: "public.png")])
        for _ in 0..<30 where model.draftAttachments.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.draftAttachments.count == 1)
        #expect(model.draftAttachments.first?.kind == .image)
        #expect(model.draft == "Rich **draft**")
        #expect(!model.isSending)
    }

    @Test func nativeComposerPasteStagesImageWithoutChangingText() async throws {
        let model = ChatModel(conversationID: "clipboard-proof", client: ConversationFixtureClient())
        model.draft = "Keep this draft"
        let controller = UIHostingController(rootView: ChatView(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; UIPasteboard.general.items = [] }
        controller.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(400))
        controller.view.layoutIfNeeded()
        func textViews(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        let input = try #require(textViews(controller.view).first(where: { $0.isEditable && $0.text == "Keep this draft" }))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        UIPasteboard.general.image = image
        input.becomeFirstResponder()
        input.paste(nil)
        for _ in 0..<30 where model.draftAttachments.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.draft == "Keep this draft")
        #expect(model.draftAttachments.count == 1, "Native Paste must create an ordinary image attachment")
        try await Task.sleep(for: .milliseconds(150))
        let screenshot = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        try screenshot.pngData()?.write(to: FileManager.default.temporaryDirectory.appending(path: "clipboard-attachment-proof.png"))
        if let attachment = model.draftAttachments.first {
            #expect(attachment.kind == .image)
            #expect(UIImage(data: attachment.data) != nil)
            model.removeDraftAttachment(id: attachment.id)
            #expect(model.draftAttachments.isEmpty)
        }
        #expect(!model.isSending)
        UIPasteboard.general.string = " plus text"
        input.selectedRange = NSRange(location: (input.text as NSString).length, length: 0)
        input.paste(nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.draft == "Keep this draft plus text", "Ordinary text paste must still use native insertion")
        #expect(model.draftAttachments.isEmpty)
    }
}
