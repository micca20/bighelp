import SwiftUI
import Testing
import UIKit
@testable import Bighelp

/// Copying a whole table, and a card as a picture.
@MainActor
struct ChatCopyTests {
    private let table = MarkdownTable(
        header: ["Item", "**Cost**"],
        alignments: [.leading, .trailing],
        rows: [["Wax ring | kit", "$12"], ["Plumber <visit>", "$250"]]
    )

    @Test func aTableCopiesAsMarkdownForMessages() {
        #expect(ChatTableCopy.markdown(table) == """
        | Item | Cost |
        | --- | ---: |
        | Wax ring \\| kit | $12 |
        | Plumber <visit> | $250 |
        """)
    }

    @Test func aTableCopiesAsColumnsForSpreadsheets() {
        #expect(ChatTableCopy.tabSeparated(table) == "Item\tCost\nWax ring | kit\t$12\nPlumber <visit>\t$250")
    }

    @Test func aTableCopiesAsAnHTMLTableForMail() {
        let html = ChatTableCopy.html(table)
        #expect(html.hasPrefix("<table><thead><tr><th>Item</th><th>Cost</th></tr></thead>"))
        #expect(html.contains("<td>Plumber &lt;visit&gt;</td>"), "Cell text is escaped")
    }

    @Test func aCardCopiesAsASharpPicture() throws {
        let card = try #require(BighelpCardDemoFixtures.documents.first)
        let png = try #require(ChatCardImage.png(BighelpCardView(card: card), width: 320, scale: 3,
                                                 background: .white, environment: EnvironmentValues()))
        let image = try #require(UIImage(data: png))
        #expect(abs(image.size.width * image.scale - (320 + 32) * 3) < 1, "The card's width plus a margin, at screen scale")
        #expect(image.size.height > 100)
        #expect(ChatCardImage.png(BighelpCardView(card: card), width: 0, scale: 3, background: .white,
                                  environment: EnvironmentValues()) == nil, "Nothing before the card has a size")
    }
}
