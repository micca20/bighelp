import SwiftUI

/// The shape of a card still streaming in, when its JSON already names its
/// kind (the plugin writes keys in order, so `component` comes early).
/// Anything else, including `loopdy.card` documents, is a generic card.
enum ChatPendingCardKind: Equatable, Sendable {
    case generic, forecast, quote, list, metrics, summary

    /// Reads only the start of the partial card, never decoding it.
    init(partialCard: some StringProtocol) {
        guard let match = String(partialCard.prefix(2_048)).firstMatch(of: #/"component"\s*:\s*"([a-z_]{1,40})"/#),
              let component = GenerativeUIComponent(rawValue: String(match.1)) else {
            self = .generic
            return
        }
        self = switch component {
        case .weatherForecast: .forecast
        case .stockQuote: .quote
        case .metrics, .dashboard, .chart: .metrics
        case .summary: .summary
        case .list, .timeline, .checklist, .selection, .form, .automation, .sportsGame: .list
        }
    }
}

/// A card streaming in (#18): a real card of the coming kind, filled with
/// placeholder words and drawn as its own skeleton, so the card's code never
/// shows and the finished card lands in about the same space.
struct ChatPendingCardView: View {
    var kind: ChatPendingCardKind = .generic

    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space8) {
                Image(BighelpGlyph.sparkles.assetName)
                    .resizable().renderingMode(.template)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(theme.action)
                Text("Making a card…")
                    .bighelpShimmer(isActive: true)
            }
            .font(.bighelp(.subheadline, weight: .medium))
            if let placeholder = ChatPendingCardPlaceholder.document(for: kind) {
                BighelpCardView(card: placeholder)
                    .bighelpSkeleton(isLoading: true, accessibilityLabel: "Making a card")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Making a card")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("chat.card.pending")
    }
}

/// Placeholder cards, one per kind. The words are never shown or read: the
/// skeleton turns them into soft blocks the length of real text.
enum ChatPendingCardPlaceholder {
    static func document(for kind: ChatPendingCardKind) -> BighelpCardDocument? {
        documents[kind]
    }

    static let documents: [ChatPendingCardKind: BighelpCardDocument] = {
        var documents: [ChatPendingCardKind: BighelpCardDocument] = [:]
        let shapes: [(ChatPendingCardKind, [String: BighelpJSONValue])] = [
            (.generic, [
                "root": node("card", ["title": .string("A card on its way"), "subtitle": .string("Putting it together")],
                             ["lines", "figures"]),
                "lines": node("vstack", ["spacing": .string("small")], ["first", "second"]),
                "first": text("A line about what the card shows"),
                "second": text("A shorter second line"),
                "figures": node("hstack", ["spacing": .string("medium")], ["left", "right"]),
                "left": metric("First figure", 1_204),
                "right": metric("Second", 48),
            ]),
            (.forecast, [
                // No progress bar: a skeleton bar would read as real progress.
                "root": node("card", ["title": .string("Forecast for today"), "subtitle": .string("Conditions")],
                             ["grid", "outlook", "condition"]),
                "grid": node("grid", ["columns": .integer(2), "spacing": .string("small")], ["temperature", "wind"]),
                "temperature": metric("Temperature", 72),
                "wind": metric("Wind", 11),
                "outlook": text("Mild through the afternoon"),
                "condition": text("Partly cloudy later"),
            ]),
            (.quote, [
                "root": node("card", ["title": .string("Market quote"), "subtitle": .string("Latest price")], ["row"]),
                "row": node("hstack", ["spacing": .string("medium")], ["icon", "price", "change"]),
                "icon": .object(["type": .string("image"), "children": .array([]), "props": .object([
                    "name": .string("chart.line.uptrend.xyaxis"), "accessibility_label": .string("Price"),
                ])]),
                "price": metric("Price", 64_321),
                "change": badge("+1.2%"),
            ]),
            (.list, [
                "root": node("card", ["title": .string("A short list"), "subtitle": .string("Items")],
                             ["rows"]),
                "rows": node("vstack", ["spacing": .string("small")], ["one", "two", "three"]),
                "one": node("hstack", ["spacing": .string("small")], ["one_text", "one_badge"]),
                "one_text": text("The first item on the list"),
                "one_badge": badge("Ready"),
                "two": node("hstack", ["spacing": .string("small")], ["two_text", "two_badge"]),
                "two_text": text("A second, shorter item"),
                "two_badge": badge("Next"),
                "three": node("hstack", ["spacing": .string("small")], ["three_text", "three_badge"]),
                "three_text": text("And a third one"),
                "three_badge": badge("Later"),
            ]),
            (.metrics, [
                "root": node("card", ["title": .string("Key numbers"), "subtitle": .string("Overview")], ["grid"]),
                "grid": node("grid", ["columns": .integer(2), "spacing": .string("small")],
                             ["one", "two", "three", "four"]),
                "one": metric("First", 128),
                "two": metric("Second", 64),
                "three": metric("Third", 2_048),
                "four": metric("Fourth", 12),
            ]),
            (.summary, [
                "root": node("card", ["title": .string("A short summary")], ["body", "closing"]),
                "body": text("A few lines of summary text that wrap across the card the way a real summary does."),
                "closing": text("One closing line"),
            ]),
        ]
        for (index, shape) in shapes.enumerated() {
            documents[shape.0] = make(index: index, elements: shape.1)
        }
        return documents
    }()

    private static func make(index: Int, elements: [String: BighelpJSONValue]) -> BighelpCardDocument? {
        try? BighelpCardValidator.validateForStaticRelease(BighelpCardDocument(document: [
            "schema": .string("loopdy.card"),
            "version": .integer(1),
            "title": .string("Making a card"),
            "spoken_summary": .string("Making a card"),
            "importance": .string("normal"),
            "data_sources": .array([]),
            "root": .string("root"),
            "elements": .object(elements),
            "content_hash": .string(String(repeating: "0", count: 63) + String(index)),
            "card_id": .string(String(repeating: "0", count: 31) + String(index)),
            "origin": .string("live"),
            "created_at": .string("2026-09-02T12:00:00Z"),
        ]))
    }

    private static func node(_ type: String, _ props: [String: BighelpJSONValue],
                             _ children: [String] = []) -> BighelpJSONValue {
        .object(["type": .string(type), "props": .object(props), "children": .array(children.map(BighelpJSONValue.string))])
    }

    private static func literal(_ value: BighelpJSONValue) -> BighelpJSONValue {
        .object(["literal": value])
    }

    private static func text(_ value: String) -> BighelpJSONValue {
        node("text", ["value": literal(.string(value)), "typography": .string("body"), "line_limit": .integer(3)])
    }

    private static func metric(_ label: String, _ value: Int) -> BighelpJSONValue {
        node("metric", ["label": .string(label), "value": literal(.integer(value))])
    }

    private static func badge(_ value: String) -> BighelpJSONValue {
        node("badge", ["value": literal(.string(value)), "semantic": .string("neutral")])
    }
}
