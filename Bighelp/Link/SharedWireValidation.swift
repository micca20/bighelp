import Foundation

// Shared strict wire primitives. Historical Link type names remain compatible
// with native consumers; these values do not provide a chat transport.

enum BighelpLinkWireError: Error, Equatable {
    case invalidValue
}

enum BighelpLinkSessionCoordinate {
    static func isValid(_ value: String) -> Bool {
        BighelpLinkPickerValidation.opaque(value, minimum: 1, maximum: 180)
    }

    static func decode(_ value: Any?) -> String? {
        guard let value = value as? String, isValid(value) else { return nil }
        return value
    }
}

enum BighelpLinkPickerValidation {
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func keys(from decoder: any Decoder) throws -> Set<String> {
        Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
    }

    static func opaque(_ value: String, minimum: Int, maximum: Int) -> Bool {
        (minimum...maximum).contains(value.count)
            && value.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
            })
    }

    static func identifier(_ value: String, maximum: Int) -> String? {
        guard
            !value.isEmpty,
            value.count <= maximum,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            })
        else { return nil }
        return value
    }

    /// Model names may be human-readable presets (for example, "Hermes 4 405B").
    /// Keep the field printable and bounded while allowing ordinary spaces; IDs
    /// and protocol coordinates continue to use `identifier` above.
    static func modelIdentifier(_ value: String, maximum: Int) -> String? {
        guard
            !value.isEmpty,
            value.count <= maximum,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    || (CharacterSet.whitespacesAndNewlines.contains($0) && $0 != " ")
            })
        else { return nil }
        return value
    }

    static func label(_ value: String, maximum: Int) -> String? {
        let normalized = value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard
            !normalized.isEmpty,
            normalized == value.trimmingCharacters(in: .whitespacesAndNewlines),
            normalized.count <= maximum,
            !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return normalized
    }
}
