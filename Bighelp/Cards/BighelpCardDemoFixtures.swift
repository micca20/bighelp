import Foundation

enum BighelpCardDemoFixtures {
    static let documents: [BighelpCardDocument] = [bitcoin, earthquakes, weather]

    private static let bitcoin = make(
        id: "11111111111111111111111111111111",
        title: "Bitcoin",
        summary: "Bitcoin's deterministic demo price is shown.",
        importance: "important",
        elements: [
            "root": node("card", ["title": .string("Bitcoin"), "subtitle": .string("Demo market data")], ["row"]),
            "row": node("hstack", ["spacing": .string("medium")], ["icon", "price", "trend"]),
            "icon": node("image", ["name": .string("bitcoinsign.circle.fill"), "accessibility_label": .string("Bitcoin"), "semantic": .string("accent")]),
            "price": node("metric", ["label": .string("BTC-USD"), "value": literal(.number(64_321.12)), "format": .object(["style": .string("currency"), "currency": .string("USD")])]),
            "trend": node("badge", ["value": literal(.string("+2.4%")), "semantic": .string("positive")]),
        ]
    )

    private static let earthquakes = make(
        id: "22222222222222222222222222222222",
        title: "Significant earthquakes",
        summary: "Deterministic earthquake demo data is listed.",
        importance: "urgent",
        elements: [
            "root": node("card", ["title": .string("Significant earthquakes"), "subtitle": .string("Demo snapshot")], ["rows"]),
            "rows": node("vstack", ["spacing": .string("small")], ["row_one", "row_two"]),
            "row_one": node("hstack", ["spacing": .string("small")], ["place_one", "magnitude_one"]),
            "place_one": node("text", ["value": literal(.string("18 km south of Demo Ridge")), "typography": .string("body"), "line_limit": .integer(2)]),
            "magnitude_one": node("badge", ["value": literal(.number(5.4)), "semantic": .string("warning")]),
            "row_two": node("hstack", ["spacing": .string("small")], ["place_two", "magnitude_two"]),
            "place_two": node("text", ["value": literal(.string("7 km east of Sample Bay")), "typography": .string("body"), "line_limit": .integer(2)]),
            "magnitude_two": node("badge", ["value": literal(.number(4.8)), "semantic": .string("warning")]),
        ]
    )

    private static let weather = make(
        id: "33333333333333333333333333333333",
        title: "Chicago weather",
        summary: "Deterministic Chicago weather demo data is shown.",
        importance: "normal",
        elements: [
            "root": node("card", ["title": .string("Chicago weather"), "subtitle": .string("Demo conditions")], ["grid", "humidity", "condition"]),
            "grid": node("grid", ["columns": .integer(2), "spacing": .string("small")], ["temperature", "wind"]),
            "temperature": node("metric", ["label": .string("Temperature"), "value": literal(.number(72.4)), "format": .object(["style": .string("number"), "maximum_fraction_digits": .integer(1)])]),
            "wind": node("metric", ["label": .string("Wind"), "value": literal(.number(11.2)), "format": .object(["style": .string("number"), "maximum_fraction_digits": .integer(1)])]),
            "humidity": node("progress", ["label": .string("Humidity"), "value": literal(.integer(63)), "maximum": literal(.integer(100)), "format": .object(["style": .string("percent")]), "semantic": .string("accent")]),
            "condition": node("text", ["value": literal(.string("Partly cloudy")), "typography": .string("callout"), "color": .string("secondary")]),
        ]
    )

    private static func make(
        id: String,
        title: String,
        summary: String,
        importance: String,
        elements: [String: BighelpJSONValue]
    ) -> BighelpCardDocument {
        try! BighelpCardValidator.validateForStaticRelease(BighelpCardDocument(document: [
            "schema": .string("loopdy.card"),
            "version": .integer(1),
            "title": .string(title),
            "spoken_summary": .string(summary),
            "importance": .string(importance),
            "data_sources": .array([]),
            "root": .string("root"),
            "elements": .object(elements),
            "content_hash": .string(String(repeating: "a", count: 64)),
            "card_id": .string(id),
            "origin": .string("live"),
            "created_at": .string("2026-09-02T12:00:00Z"),
        ]))
    }

    private static func node(
        _ type: String,
        _ props: [String: BighelpJSONValue],
        _ children: [String] = []
    ) -> BighelpJSONValue {
        .object([
            "type": .string(type),
            "props": .object(props),
            "children": .array(children.map(BighelpJSONValue.string)),
        ])
    }

    private static func literal(_ value: BighelpJSONValue) -> BighelpJSONValue {
        .object(["literal": value])
    }
}
