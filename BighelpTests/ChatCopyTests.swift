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

    /// Issue #17: the forecast row scrolls on screen, and the copied image left
    /// it blank. Five periods must draw more than one in the image.
    @Test func aWeatherCardsForecastIsInItsImage() throws {
        let one = try varied(rowsIn: weatherCard(periods: 1))
        let five = try varied(rowsIn: weatherCard(periods: 5))
        #expect(five > one + 40, "Five forecast periods draw a second line of pills (one: \(one), five: \(five))")
    }

    private func weatherCard(periods: Int) throws -> Data {
        let labels = ["Mon", "Tue", "Wed", "Thu", "Fri"]
        let card = try GenerativeUICard.decode([
            "schema": "loopdy.generative_ui", "version": 2, "component": "weather_forecast", "title": "Tomorrow",
            "content_hash": String(repeating: "a", count: 64), "card_id": String(repeating: "b", count: 32),
            "origin": "live", "created_at": "2026-10-01T12:00:00Z", "provenance": ["source": "fixture"],
            "data": [
                "location": "Example City", "units": "imperial",
                "current": ["temperature": 61, "condition_code": "clear", "condition_label": "Clear"],
                "periods": (0..<periods).map { index in
                    ["id": "p\(index)", "label": labels[index], "condition_code": "rain", "high": 70 + index] as [String: Any]
                },
            ] as [String: Any],
        ])
        return try #require(ChatCardImage.png(GenerativeUICardView(card: card, messageID: "m"), width: 320, scale: 2,
                                              background: .white, environment: EnvironmentValues()))
    }

    /// Rows of the image that aren't one flat color.
    private func varied(rowsIn png: Data) throws -> Int {
        let image = try #require(UIImage(data: png)?.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<height).filter { row in
            var low = 255, high = 0
            for column in stride(from: 0, to: width, by: 2) {
                let offset = (row * width + column) * 4
                let luminance = (Int(pixels[offset]) * 3 + Int(pixels[offset + 1]) * 6 + Int(pixels[offset + 2])) / 10
                low = min(low, luminance)
                high = max(high, luminance)
            }
            return high - low > 24
        }.count
    }
}
