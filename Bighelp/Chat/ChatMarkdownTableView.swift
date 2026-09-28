import SwiftUI

/// A Markdown pipe table in a chat: a header row and rows of cells that wrap
/// at a readable width. A table wider than the bubble scrolls sideways.
struct ChatMarkdownTableView: View {
    let table: MarkdownTable
    var textColor: Color?

    @BighelpThemeReader private var theme: BighelpTheme

    /// Cells wrap here instead of growing into one long line.
    static let maximumColumnWidth: CGFloat = 220

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ChatTableLayout(columns: table.header.count, maximumColumnWidth: Self.maximumColumnWidth) {
                ForEach(table.header.indices, id: \.self) { column in
                    cell(table.header[column], column: column, isHeader: true, isLastRow: table.rows.isEmpty)
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        cell(table.rows[row][column], column: column, isHeader: false,
                             isLastRow: row == table.rows.count - 1)
                            .accessibilityLabel(cellLabel(row: table.rows[row], column: column))
                    }
                }
            }
            .clipShape(.rect(cornerRadius: BighelpTokens.radius12))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                    .stroke(theme.border, lineWidth: BighelpTokens.hairline)
            }
            // The stroke sits half outside the table; keep it from being clipped.
            .padding(BighelpTokens.hairline)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.markdown-table")
    }

    private func cell(_ markdown: String, column: Int, isHeader: Bool, isLastRow: Bool) -> some View {
        let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
        return Text(ChatInlineMarkdown.attributedText(markdown))
            .bighelpMessageFont(.body, weight: isHeader ? .semibold : nil)
            .foregroundStyle(textColor ?? theme.primaryText)
            .multilineTextAlignment(textAlignment(alignment))
            .padding(.horizontal, BighelpTokens.space12)
            .padding(.vertical, BighelpTokens.space8)
            // The layout sizes every cell to its column and row; fill it so the
            // header shading and row lines have no gaps.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment(alignment))
            .background(isHeader ? theme.primaryText.opacity(0.06) : .clear)
            .overlay(alignment: .bottom) {
                if !isLastRow {
                    Rectangle().fill(theme.border).frame(height: BighelpTokens.hairline)
                }
            }
            .accessibilityAddTraits(isHeader ? .isHeader : [])
    }

    /// "Total: $270" reads better than the bare value.
    private func cellLabel(row: [String], column: Int) -> String {
        let value = MarkdownDocument(row[column]).visiblePlainText
        let name = table.header.indices.contains(column)
            ? MarkdownDocument(table.header[column]).visiblePlainText : ""
        return name.isEmpty ? value : "\(name): \(value)"
    }

    private func textAlignment(_ alignment: MarkdownTable.Alignment) -> TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func frameAlignment(_ alignment: MarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Cells in row order. Each column is as wide as its widest cell (capped, so
/// long text wraps), and each row as tall as its tallest cell at those widths.
/// (Grid measures a wrapping cell's height before its width is capped, so
/// wrapped rows came out too short.)
struct ChatTableLayout: Layout {
    let columns: Int
    let maximumColumnWidth: CGFloat

    struct Measurement {
        var widths: [CGFloat]
        var heights: [CGFloat]
    }

    func makeCache(subviews: Subviews) -> Measurement {
        guard columns > 0 else { return Measurement(widths: [], heights: []) }
        var widths = Array(repeating: CGFloat.zero, count: columns)
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified).width
            widths[index % columns] = max(widths[index % columns], min(ideal, maximumColumnWidth))
        }
        widths = widths.map { $0.rounded(.up) }
        var heights: [CGFloat] = []
        for start in stride(from: 0, to: subviews.count, by: columns) {
            var height = CGFloat.zero
            for column in 0..<columns where start + column < subviews.count {
                let size = subviews[start + column].sizeThatFits(ProposedViewSize(width: widths[column], height: nil))
                height = max(height, size.height)
            }
            heights.append(height.rounded(.up))
        }
        return Measurement(widths: widths, heights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Measurement) -> CGSize {
        CGSize(width: cache.widths.reduce(0, +), height: cache.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Measurement) {
        guard columns > 0 else { return }
        var y = bounds.minY
        for (row, height) in cache.heights.enumerated() {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: cache.widths[column], height: height))
                x += cache.widths[column]
            }
            y += height
        }
    }
}

/// A Markdown thematic break (`---`).
struct ChatMarkdownRuleView: View {
    @BighelpThemeReader private var theme: BighelpTheme

    var body: some View {
        Rectangle()
            .fill(theme.border)
            .frame(maxWidth: .infinity)
            .frame(height: BighelpTokens.hairline)
            .padding(.vertical, BighelpTokens.space4)
            .accessibilityHidden(true)
    }
}
