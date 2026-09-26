import Foundation

/// One composer attachment intent. PDF-page selections stay distinct from
/// ordinary files so they can never fall through the existing `file.attach`
/// document path. Array order is the staging order used by explicit Send.
enum ChatDraftAttachment: Identifiable, Equatable, Sendable {
    case attachment(ChatAttachment)
    case pdfPages(DirectHermesPDFPageSelection)

    var id: String {
        switch self {
        case .attachment(let attachment):
            "attachment:\(attachment.id)"
        case .pdfPages(let selection):
            "pdf-pages:\(selection.attachment.id)"
        }
    }

    var sourceAttachmentID: String {
        switch self {
        case .attachment(let attachment): attachment.id
        case .pdfPages(let selection): selection.attachment.id
        }
    }

    var byteCount: Int {
        switch self {
        case .attachment(let attachment): attachment.data.count
        case .pdfPages(let selection): selection.attachment.data.count
        }
    }

    var ordinaryAttachment: ChatAttachment? {
        guard case .attachment(let attachment) = self else { return nil }
        return attachment
    }

    var pdfSelection: DirectHermesPDFPageSelection? {
        guard case .pdfPages(let selection) = self else { return nil }
        return selection
    }
}

/// Accepted transport receipt for one mixed attachment draft. PDF images remain
/// typed and path-free; the ordinary conversation response keeps its existing
/// reducer ownership.
struct DirectHermesDraftAttachmentSendReceipt: Equatable, Sendable {
    let response: ConversationResponse
    let pdfAttachments: [DirectHermesPDFAttachmentReceipt]
}

/// Immutable item used to present a picker for the exact mounted chat owner.
struct ChatPDFPagesPickerTarget: Identifiable, Equatable {
    let sessionID: String
    let target: DirectHermesPDFAttachmentTarget

    var id: String { "\(sessionID):\(target.owner.uuidString)" }
}

/// The action drawer is hosted beside `ChatView` by the app root. Register only
/// the currently mounted ChatView so the drawer can resolve its exact model
/// without a root-owned callback or a process-wide transport authority.
@MainActor
enum ChatPDFPagesDraftRegistry {
    private final class WeakModel {
        weak var value: ChatModel?
        init(_ value: ChatModel) { self.value = value }
    }

    private static var mounted: [String: WeakModel] = [:]

    static func mount(_ model: ChatModel) {
        mounted[model.conversationID] = WeakModel(model)
    }

    static func unmount(_ model: ChatModel) {
        guard mounted[model.conversationID]?.value === model else { return }
        mounted[model.conversationID] = nil
    }

    static func model(for sessionID: String) -> ChatModel? {
        guard let model = mounted[sessionID]?.value else {
            mounted[sessionID] = nil
            return nil
        }
        return model
    }

    static func owns(_ model: ChatModel, sessionID: String) -> Bool {
        model.conversationID.utf8.elementsEqual(sessionID.utf8)
            && mounted[sessionID]?.value === model
    }
}
