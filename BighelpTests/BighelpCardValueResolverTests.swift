import Testing
@testable import Bighelp

struct BighelpCardValueResolverTests {
    @Test func resolvesRFC6901EscapingArraysLiteralsAndListItemContext() {
        let source: BighelpJSONValue = .object([
            "a/b": .object(["~key": .array([.string("zero"), .string("one")])]),
            "features": .array([
                .object(["properties": .object(["place": .string("Kansas")])]),
            ]),
        ])
        #expect(
            BighelpCardValueResolver.pointer("/a~1b/~0key/1", in: source)
                == .string("one")
        )
        #expect(
            BighelpCardValueResolver.resolve(
                .object(["literal": .string("Ready")]),
                sources: ["feed": source]
            ) == .value(.string("Ready"))
        )
        let item = source.object?["features"]?.array?.first
        #expect(
            BighelpCardValueResolver.resolve(
                .object(["source": .string("feed"), "pointer": .string("/properties/place")]),
                sources: ["feed": source],
                item: item,
                itemSourceID: "feed"
            ) == .value(.string("Kansas"))
        )
    }

    @Test func evaluatesFiniteExpressionsAndReturnsTypedUnavailableFailures() {
        let source: BighelpJSONValue = .object(["current": .integer(120), "previous": .integer(100)])
        let expression: BighelpJSONValue = .object([
            "expression": .object([
                "op": .string("percent_change"),
                "arguments": .array([
                    .object(["source": .string("prices"), "pointer": .string("/current")]),
                    .object(["source": .string("prices"), "pointer": .string("/previous")]),
                ]),
            ]),
        ])
        #expect(
            BighelpCardValueResolver.resolve(expression, sources: ["prices": source])
                == .value(.number(20))
        )

        let fallback: BighelpJSONValue = .object([
            "expression": .object([
                "op": .string("coalesce"),
                "arguments": .array([
                    .object(["source": .string("prices"), "pointer": .string("/missing")]),
                    .object(["literal": .string("Unavailable")]),
                ]),
            ]),
        ])
        #expect(
            BighelpCardValueResolver.resolve(fallback, sources: ["prices": source])
                == .value(.string("Unavailable"))
        )

        let divisionByZero: BighelpJSONValue = .object([
            "expression": .object([
                "op": .string("divide"),
                "arguments": .array([
                    .object(["literal": .integer(1)]),
                    .object(["literal": .integer(0)]),
                ]),
            ]),
        ])
        #expect(
            BighelpCardValueResolver.resolve(divisionByZero, sources: [:])
                == .unavailable(reason: "division by zero")
        )
    }
}
