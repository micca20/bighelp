import SwiftUI
import UIKit

struct DraftAttachmentStrip: View {
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    let attachments: [ChatDraftAttachment]
    let currentPDFTarget: DirectHermesPDFAttachmentTarget?
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(attachments) { value in
                    HStack(spacing: BighelpTokens.space8) {
                        thumbnail(value)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fileName(value))
                                .bighelpFont(.metadata, weight: .semibold)
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(1)
                            Text(detail(value))
                                .bighelpFont(.metadata)
                                .foregroundStyle(isStale(value) ? theme.warning : theme.secondaryText)
                                .lineLimit(2)
                        }
                        Button {
                            onRemove(value.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(theme.secondaryText)
                                .frame(minWidth: uiV3Enabled ? BighelpTokens.hitTarget : nil,
                                       minHeight: uiV3Enabled ? BighelpTokens.hitTarget : nil)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(fileName(value))")
                    }
                    .padding(.horizontal, BighelpTokens.space8)
                    .padding(.vertical, 6)
                    .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius12))
                    .overlay {
                        RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                            .stroke(
                                isStale(value) ? theme.warning : theme.border,
                                lineWidth: isStale(value) ? 1.5 : BighelpTokens.hairline
                            )
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(value.pdfSelection == nil
                        ? "chat.draft-attachment"
                        : "chat.draft-pdf-pages")
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("chat.draft-attachments")
    }

    private func fileName(_ value: ChatDraftAttachment) -> String {
        switch value {
        case .attachment(let attachment): attachment.fileName
        case .pdfPages(let selection): selection.attachment.fileName
        }
    }

    private func detail(_ value: ChatDraftAttachment) -> String {
        switch value {
        case .attachment(let attachment):
            ByteCountFormatter.string(
                fromByteCount: Int64(attachment.data.count),
                countStyle: .file
            )
        case .pdfPages(let selection):
            if isStale(value) {
                "Earlier session · remove and re-add these pages"
            } else {
                "PDF pages \(selection.pageRange.firstPage)–\(selection.pageRange.lastPage)"
            }
        }
    }

    private func isStale(_ value: ChatDraftAttachment) -> Bool {
        guard let selection = value.pdfSelection else { return false }
        return currentPDFTarget == nil || selection.target != currentPDFTarget
    }

    @ViewBuilder
    private func thumbnail(_ value: ChatDraftAttachment) -> some View {
        switch value {
        case .attachment(let attachment):
            if attachment.kind == .image, let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                documentIcon(systemImage: "doc.fill", isWarning: false)
            }
        case .pdfPages:
            documentIcon(systemImage: "photo.stack.fill", isWarning: isStale(value))
        }
    }

    private func documentIcon(systemImage: String, isWarning: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isWarning ? theme.warning : theme.action)
            .frame(width: 34, height: 34)
            .background(
                (isWarning ? theme.warning : theme.action).opacity(0.10),
                in: .rect(cornerRadius: 8)
            )
    }

    @BighelpThemeReader private var theme: BighelpTheme

}
