import Foundation

/// Equivalent JSON primitives only. Each schema explicitly chooses its error
/// domain, array-overflow error and whether required text may be empty. Missing
/// and null optional values are absent; wrong types, NUL text and nonfinite
/// numbers always fail. Integer decoding never coerces a floating-point value.
/// Domain rules (identifiers, uniqueness, URLs, receipts) stay with the schema.
protocol DirectHermesPayloadDecoding {
    static var invalidResponse: any Error { get }
    static var arrayOverflow: any Error { get }
    static var requiresNonemptyText: Bool { get }
}

extension DirectHermesPayloadDecoding {
    static func object(_ value: BighelpJSONValue?) throws -> [String: BighelpJSONValue] {
        guard let object = value?.object else { throw invalidResponse }
        return object
    }

    static func array(_ value: BighelpJSONValue?, maximum: Int) throws -> [BighelpJSONValue] {
        guard let array = value?.array else { throw invalidResponse }
        guard array.count <= maximum else { throw arrayOverflow }
        return array
    }

    static func text(_ value: BighelpJSONValue?, maximumBytes: Int, required: Bool? = nil) throws -> String {
        guard let text = value?.string, text.utf8.count <= maximumBytes,
              (!(required ?? requiresNonemptyText) || !text.isEmpty),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw invalidResponse }
        return text
    }

    static func optionalText(_ value: BighelpJSONValue?, maximumBytes: Int) throws -> String? {
        guard let value, value != .null else { return nil }
        return try text(value, maximumBytes: maximumBytes, required: false)
    }

    static func boolean(_ value: BighelpJSONValue?) throws -> Bool {
        guard let value = value?.boolean else { throw invalidResponse }
        return value
    }

    static func optionalBoolean(_ value: BighelpJSONValue?) throws -> Bool? {
        guard let value, value != .null else { return nil }
        return try boolean(value)
    }

    static func integer(_ value: BighelpJSONValue?, range: ClosedRange<Int>) throws -> Int {
        guard let value = value?.integer, range.contains(value) else { throw invalidResponse }
        return value
    }

    static func optionalInteger(_ value: BighelpJSONValue?, range: ClosedRange<Int>) throws -> Int? {
        guard let value, value != .null else { return nil }
        return try integer(value, range: range)
    }

    static func number(
        _ value: BighelpJSONValue?,
        range: ClosedRange<Double> = -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
    ) throws -> Double {
        guard let value = value?.number, value.isFinite, range.contains(value) else { throw invalidResponse }
        return value
    }

    static func optionalNumber(
        _ value: BighelpJSONValue?,
        range: ClosedRange<Double> = -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
    ) throws -> Double? {
        guard let value, value != .null else { return nil }
        return try number(value, range: range)
    }
}
