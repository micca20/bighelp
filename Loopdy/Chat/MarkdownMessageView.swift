import SwiftUI

struct MarkdownMessageView: View {
    let document: MarkdownDocument
    let proseLineSpacing: CGFloat
    let primaryText: Color?
    let secondaryText: Color?
    let accent: Color?
    let codeBackground: Color?

    init(
        document: MarkdownDocument,
        proseLineSpacing: CGFloat = 0,
        primaryText: Color? = nil,
        secondaryText: Color? = nil,
        accent: Color? = nil,
        codeBackground: Color? = nil
    ) {
        self.document = document
        self.proseLineSpacing = proseLineSpacing
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.accent = accent
        self.codeBackground = codeBackground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .padding(.top, spacing(beforeBlockAt: index))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func spacing(beforeBlockAt index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        return ChatMarkdownLayoutPolicy.spacing(
            after: document.blocks[index - 1],
            before: document.blocks[index]
        )
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let markdown):
            inlineText(markdown)
                .loopdyMessageFont(ChatMarkdownTypography.headingRole(for: level))
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let markdown):
            inlineText(markdown)
                .loopdyMessageFont(.body)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: ChatMarkdownLayoutPolicy.listRowSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: LoopdyTokens.space8) {
                        Text("•")
                            .frame(
                                width: ChatMarkdownLayoutPolicy.unorderedMarkerWidth,
                                alignment: .trailing
                            )
                        inlineText(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .loopdyMessageFont(.body)
        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: ChatMarkdownLayoutPolicy.listRowSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: LoopdyTokens.space8) {
                        Text("\(start + offset).")
                            .monospacedDigit()
                            .frame(
                                width: ChatMarkdownLayoutPolicy.orderedMarkerWidth,
                                alignment: .trailing
                            )
                        inlineText(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .loopdyMessageFont(.body)
        case .quote(let markdown):
            HStack(alignment: .top, spacing: LoopdyTokens.space8) {
                RoundedRectangle(cornerRadius: LoopdyTokens.hairline)
                    .fill(resolvedAccent.opacity(0.65))
                    .frame(width: 3)
                inlineText(markdown)
                    .loopdyMessageFont(.body, italic: true)
                    .foregroundStyle(resolvedSecondaryText)
            }
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                if let language {
                    Text(language.uppercased())
                        .loopdyMessageFont(.metadata, weight: .semibold)
                        .foregroundStyle(resolvedSecondaryText)
                }
                ScrollView(.horizontal) {
                    Text(text)
                        .loopdyMessageFont(.code)
                        .foregroundStyle(resolvedPrimaryText)
                        .textSelection(.enabled)
                }
            }
            .padding(LoopdyTokens.space12)
            .background(resolvedCodeBackground, in: .rect(cornerRadius: LoopdyTokens.radius12))
            .overlay {
                RoundedRectangle(cornerRadius: LoopdyTokens.radius12)
                    .stroke(theme.border, lineWidth: LoopdyTokens.hairline)
            }
        }
    }

    private func inlineText(_ markdown: String) -> some View {
        Text(ChatInlineMarkdown.attributedText(markdown))
            .lineSpacing(proseLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var resolvedPrimaryText: Color { primaryText ?? theme.primaryText }
    private var resolvedSecondaryText: Color { secondaryText ?? theme.secondaryText }
    private var resolvedAccent: Color { accent ?? theme.action }
    private var resolvedCodeBackground: Color { codeBackground ?? theme.raisedSurface }

    @LoopdyThemeReader private var theme: LoopdyTheme

}
