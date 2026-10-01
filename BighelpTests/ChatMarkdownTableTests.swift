import Foundation
import Testing
@testable import Bighelp

struct ChatMarkdownTableTests {
    private let quote = """
    You're most likely looking at about **$320**. These are the flat rates:

    | Likely cause | Labor | Materials | Total |
    |---|---|---|---|
    | **Tank bolt / gasket** (most likely) | $300 | $20 | **$320** |
    | Fill valve, if the leak is at the supply hookup | $250 | $20 | $270 |
    | Cracked tank → toilet replacement (worst case) | $400 | toilet cost | $400 + toilet |

    A few things to keep in mind:
    """

    @Test func pipeTablesBecomeTablesBetweenTheirParagraphs() throws {
        let blocks = MarkdownDocument(quote).blocks
        #expect(blocks.count == 3)
        guard case .table(let table) = blocks[1] else {
            Issue.record("Expected a table, got \(blocks[1])")
            return
        }
        #expect(table.header == ["Likely cause", "Labor", "Materials", "Total"])
        #expect(table.alignments == Array(repeating: .leading, count: 4))
        #expect(table.rows.count == 3)
        #expect(table.rows[0] == ["**Tank bolt / gasket** (most likely)", "$300", "$20", "**$320**"])
        #expect(blocks[2] == .paragraph(markdown: "A few things to keep in mind:"))
    }

    @Test func alignmentsPipesAndRaggedRows() throws {
        let source = """
        Name | Code | Price
        :--- | :---: | ---:
        Pipe `a|b` | x \\| y | 3
        Short
        """
        guard case .table(let table) = MarkdownDocument(source).blocks.first else {
            Issue.record("Expected a table")
            return
        }
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(table.rows == [["Pipe `a|b`", "x | y", "3"]], "A line without a pipe ends the table")
        guard case .table(let ragged) = MarkdownDocument("| a | b |\n|-|-|\n| 1 |\n| 1 | 2 | 3 |").blocks.first else {
            Issue.record("Expected a table")
            return
        }
        #expect(ragged.rows == [["1", ""], ["1", "2"]])
    }

    @Test func pipesWithoutADelimiterRowStayText() {
        #expect(MarkdownDocument("Choose A | B | C").blocks == [.paragraph(markdown: "Choose A | B | C")])
        #expect(MarkdownDocument("| a | b |\n| c | d |").blocks.allSatisfy {
            if case .table = $0 { false } else { true }
        })
    }

    @Test func rulesSetextHeadingsAndTasks() {
        #expect(MarkdownDocument("One\n\n---\n\nTwo").blocks
            == [.paragraph(markdown: "One"), .rule, .paragraph(markdown: "Two")])
        #expect(MarkdownDocument("* * *").blocks == [.rule])
        #expect(MarkdownDocument("Summary\n---").blocks == [.heading(level: 2, markdown: "Summary")])
        #expect(MarkdownDocument("Title\n===").blocks == [.heading(level: 1, markdown: "Title")])
        #expect(MarkdownTaskItem.split("[x] Book the plumber") == (true, "Book the plumber"))
        #expect(MarkdownTaskItem.split("[ ] Buy a toilet") == (false, "Buy a toilet"))
        #expect(MarkdownTaskItem.split("Plain item") == (nil, "Plain item"))
        #expect(MarkdownDocument("- [ ] Buy a toilet").visiblePlainText == "Buy a toilet")
    }

    @Test func chatMessagesDrawTablesAndRulesAsTheirOwnParts() {
        let projection = ChatCardMessageProjection(source: quote + "\n\n---\n\nThat's it.", role: .assistant)
        let kinds = projection.segments.map { segment -> String in
            switch segment {
            case .markdown: "text"
            case .table: "table"
            case .rule: "rule"
            case .card, .pendingCard, .unavailableCard: "card"
            }
        }
        #expect(kinds == ["text", "table", "text", "rule", "text"])
        // A plain message is still one text part.
        #expect(ChatCardMessageProjection(source: "Hello **there**", role: .assistant).segments.count == 1)
    }

    @Test func tablesReadAsTextForCopyAndSpeech() {
        let text = MarkdownDocument("| A | B |\n|---|---|\n| **1** | 2 |").visiblePlainText
        #expect(text == "A\tB\n1\t2")
    }
}
