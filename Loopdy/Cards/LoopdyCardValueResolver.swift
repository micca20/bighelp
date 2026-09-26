import Foundation

enum LoopdyCardResolvedValue: Sendable, Equatable {
    case value(LoopdyJSONValue)
    case unavailable(reason: String)
}

enum LoopdyCardValueResolver {
    private static let maximumExpressionDepth = 8
    private static let maximumArguments = 8

    static func pointer(_ pointer: String, in value: LoopdyJSONValue) -> LoopdyJSONValue? {
        guard pointer.isEmpty || pointer.hasPrefix("/") else { return nil }
        guard !pointer.isEmpty else { return value }

        return pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).reduce(value as LoopdyJSONValue?) { current, rawToken in
            guard let current else { return nil }
            let token = decodePointerToken(String(rawToken))
            switch current {
            case .object(let object):
                return object[token]
            case .array(let array):
                guard token != "-", let index = Int(token), index >= 0, index < array.count else { return nil }
                return array[index]
            default:
                return nil
            }
        }
    }

    static func resolve(
        _ specification: LoopdyJSONValue,
        sources: [String: LoopdyJSONValue],
        item: LoopdyJSONValue? = nil,
        itemSourceID: String? = nil
    ) -> LoopdyCardResolvedValue {
        resolve(specification, sources: sources, item: item, itemSourceID: itemSourceID, depth: 0)
    }

    private static func resolve(
        _ specification: LoopdyJSONValue,
        sources: [String: LoopdyJSONValue],
        item: LoopdyJSONValue?,
        itemSourceID: String?,
        depth: Int
    ) -> LoopdyCardResolvedValue {
        guard depth <= maximumExpressionDepth else {
            return .unavailable(reason: "expression depth exceeded")
        }
        guard case .object(let object) = specification else {
            return .value(specification)
        }
        if let literal = object["literal"] {
            return .value(literal)
        }
        if let sourceID = object["source"]?.string,
           let pointerPath = object["pointer"]?.string {
            let root: LoopdyJSONValue?
            if sourceID == itemSourceID, let item {
                root = item
            } else {
                root = sources[sourceID]
            }
            guard let root else { return .unavailable(reason: "source unavailable: \(sourceID)") }
            guard let result = pointer(pointerPath, in: root) else {
                return .unavailable(reason: "value unavailable at \(pointerPath)")
            }
            return .value(result)
        }
        guard case .object(let expression)? = object["expression"],
              let operation = expression["op"]?.string,
              case .array(let arguments)? = expression["arguments"],
              arguments.count <= maximumArguments else {
            return .unavailable(reason: "invalid value specification")
        }
        return evaluate(
            operation: operation,
            arguments: arguments,
            sources: sources,
            item: item,
            itemSourceID: itemSourceID,
            depth: depth + 1
        )
    }

    private static func evaluate(
        operation: String,
        arguments: [LoopdyJSONValue],
        sources: [String: LoopdyJSONValue],
        item: LoopdyJSONValue?,
        itemSourceID: String?,
        depth: Int
    ) -> LoopdyCardResolvedValue {
        let resolved = arguments.map {
            resolve($0, sources: sources, item: item, itemSourceID: itemSourceID, depth: depth)
        }
        if operation == "coalesce" {
            for value in resolved {
                if case .value(let candidate) = value, candidate != .null {
                    return .value(candidate)
                }
            }
            return .unavailable(reason: "no value available")
        }
        guard resolved.allSatisfy({ if case .value = $0 { true } else { false } }) else {
            return resolved.first { if case .unavailable = $0 { true } else { false } }
                ?? .unavailable(reason: "argument unavailable")
        }
        let values = resolved.compactMap { result -> LoopdyJSONValue? in
            guard case .value(let value) = result else { return nil }
            return value
        }
        let numbers = values.compactMap(number)

        switch operation {
        case "add" where numbers.count == values.count && !numbers.isEmpty:
            return .value(.number(numbers.reduce(0, +)))
        case "subtract" where numbers.count == 2:
            return .value(.number(numbers[0] - numbers[1]))
        case "multiply" where numbers.count == values.count && !numbers.isEmpty:
            return .value(.number(numbers.reduce(1, *)))
        case "divide" where numbers.count == 2:
            guard numbers[1] != 0 else { return .unavailable(reason: "division by zero") }
            return .value(.number(numbers[0] / numbers[1]))
        case "percent_change" where numbers.count == 2:
            guard numbers[1] != 0 else { return .unavailable(reason: "division by zero") }
            return .value(.number(((numbers[0] - numbers[1]) / abs(numbers[1])) * 100))
        case "equal" where values.count == 2:
            return .value(.boolean(values[0] == values[1]))
        case "not_equal" where values.count == 2:
            return .value(.boolean(values[0] != values[1]))
        case "greater_than" where numbers.count == 2:
            return .value(.boolean(numbers[0] > numbers[1]))
        case "greater_than_or_equal" where numbers.count == 2:
            return .value(.boolean(numbers[0] >= numbers[1]))
        case "less_than" where numbers.count == 2:
            return .value(.boolean(numbers[0] < numbers[1]))
        case "less_than_or_equal" where numbers.count == 2:
            return .value(.boolean(numbers[0] <= numbers[1]))
        case "and" where !values.isEmpty && values.allSatisfy({ $0.boolean != nil }):
            return .value(.boolean(values.allSatisfy { $0.boolean == true }))
        case "or" where !values.isEmpty && values.allSatisfy({ $0.boolean != nil }):
            return .value(.boolean(values.contains { $0.boolean == true }))
        case "not":
            guard values.count == 1, let boolean = values[0].boolean else {
                return .unavailable(reason: "invalid boolean arguments")
            }
            return .value(.boolean(!boolean))
        default:
            return .unavailable(reason: "unsupported expression: \(operation)")
        }
    }

    private static func number(_ value: LoopdyJSONValue) -> Double? {
        switch value {
        case .integer(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }

    private static func decodePointerToken(_ token: String) -> String {
        var result = ""
        var index = token.startIndex
        while index < token.endIndex {
            if token[index] == "~" {
                let next = token.index(after: index)
                if next < token.endIndex, token[next] == "0" {
                    result.append("~")
                    index = token.index(after: next)
                    continue
                }
                if next < token.endIndex, token[next] == "1" {
                    result.append("/")
                    index = token.index(after: next)
                    continue
                }
            }
            result.append(token[index])
            index = token.index(after: index)
        }
        return result
    }
}
