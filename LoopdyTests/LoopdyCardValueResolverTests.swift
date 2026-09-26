import Testing
@testable import Loopdy

struct LoopdyCardValueResolverTests {
    @Test func resolvesRFC6901EscapingArraysLiteralsAndListItemContext() {
        let source: LoopdyJSONValue = .object([
            "a/b": .object(["~key": .array([.string("zero"), .string("one")])]),
            "features": .array([
                .object(["properties": .object(["place": .string("Kansas")])]),
            ]),
        ])
        #expect(
            LoopdyCardValueResolver.pointer("/a~1b/~0key/1", in: source)
                == .string("one")
        )
        #expect(
            LoopdyCardValueResolver.resolve(
                .object(["literal": .string("Ready")]),
                sources: ["feed": source]
            ) == .value(.string("Ready"))
        )
        let item = source.object?["features"]?.array?.first
        #expect(
            LoopdyCardValueResolver.resolve(
                .object(["source": .string("feed"), "pointer": .string("/properties/place")]),
                sources: ["feed": source],
                item: item,
                itemSourceID: "feed"
            ) == .value(.string("Kansas"))
        )
    }

    @Test func evaluatesFiniteExpressionsAndReturnsTypedUnavailableFailures() {
        let source: LoopdyJSONValue = .object(["current": .integer(120), "previous": .integer(100)])
        let expression: LoopdyJSONValue = .object([
            "expression": .object([
                "op": .string("percent_change"),
                "arguments": .array([
                    .object(["source": .string("prices"), "pointer": .string("/current")]),
                    .object(["source": .string("prices"), "pointer": .string("/previous")]),
                ]),
            ]),
        ])
        #expect(
            LoopdyCardValueResolver.resolve(expression, sources: ["prices": source])
                == .value(.number(20))
        )

        let fallback: LoopdyJSONValue = .object([
            "expression": .object([
                "op": .string("coalesce"),
                "arguments": .array([
                    .object(["source": .string("prices"), "pointer": .string("/missing")]),
                    .object(["literal": .string("Unavailable")]),
                ]),
            ]),
        ])
        #expect(
            LoopdyCardValueResolver.resolve(fallback, sources: ["prices": source])
                == .value(.string("Unavailable"))
        )

        let divisionByZero: LoopdyJSONValue = .object([
            "expression": .object([
                "op": .string("divide"),
                "arguments": .array([
                    .object(["literal": .integer(1)]),
                    .object(["literal": .integer(0)]),
                ]),
            ]),
        ])
        #expect(
            LoopdyCardValueResolver.resolve(divisionByZero, sources: [:])
                == .unavailable(reason: "division by zero")
        )
    }
}
