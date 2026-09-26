import CoreFoundation
import Foundation

struct ModelNameCatalog: Equatable, Sendable {
    static let maximumBytes = 256 * 1_024
    static let maximumEntries = 2_000
    static let maximumModelIDLength = 256
    static let maximumLabelLength = 100
    static let maximumRevisionLength = 80

    let revision: String
    private let labels: [String: String]

    private init(revision: String, labels: [String: String]) {
        self.revision = revision
        self.labels = labels
    }

    static func decode(_ data: Data) throws -> ModelNameCatalog {
        guard data.count <= maximumBytes else {
            throw ModelNameCatalogError.payloadTooLarge
        }

        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ModelNameCatalogError.malformedPayload
        }

        guard
            let object = value as? [String: Any],
            Set(object.keys) == Set(["version", "revision", "models"]),
            let version = object["version"] as? NSNumber,
            CFGetTypeID(version) != CFBooleanGetTypeID(),
            Self.isInteger(version),
            version.intValue == 1,
            let revision = object["revision"] as? String,
            Self.isValidText(
                revision,
                maximumLength: maximumRevisionLength,
                permitsEmpty: false
            ),
            let modelValues = object["models"] as? [String: Any],
            modelValues.count <= maximumEntries
        else {
            throw ModelNameCatalogError.malformedPayload
        }

        var labels: [String: String] = [:]
        labels.reserveCapacity(modelValues.count)
        for (modelID, value) in modelValues {
            guard
                Self.isValidText(
                    modelID,
                    maximumLength: maximumModelIDLength,
                    permitsEmpty: false
                ),
                let label = value as? String,
                Self.isValidText(
                    label,
                    maximumLength: maximumLabelLength,
                    permitsEmpty: false
                )
            else {
                throw ModelNameCatalogError.malformedPayload
            }
            labels[modelID] = label
        }

        return ModelNameCatalog(revision: revision, labels: labels)
    }

    func displayName(for modelID: String) -> String {
        labels[modelID] ?? Self.knownDisplayName(for: modelID) ?? modelID
    }

    static var empty: ModelNameCatalog {
        ModelNameCatalog(revision: "built-in", labels: [:])
    }

    private static let knownAliases: [(modelID: String, label: String)] = [
        ("gpt-6-astra", "GPT-6 Astra"),
        ("claude-opus-5", "Opus 5"),
        ("fable-5.1", "Fable 5.1"),
        ("gemini-3.8-flash", "Gemini 3.8 Flash"),
    ]

    private static func knownDisplayName(for modelID: String) -> String? {
        if modelID.contains("/") {
            let parts = modelID.split(separator: "/", omittingEmptySubsequences: false)
            let namespaces: Set<String> = ["openai", "anthropic", "google", "x-ai", "deepseek", "mistralai", "meta-llama", "qwen", "nousresearch"]
            guard parts.count == 2, namespaces.contains(parts[0].lowercased()) else { return nil }
            return knownDisplayName(for: String(parts[1]))
        }
        for alias in knownAliases {
            if modelID == alias.modelID {
                return alias.label
            }

            let prefix = alias.modelID + "-"
            if modelID.hasPrefix(prefix) {
                let suffix = modelID.dropFirst(prefix.count)
                guard !suffix.isEmpty else { continue }
                // Keep provider-supplied disambiguators exact instead of guessing
                // whether a suffix is a date, tier, preview, or routing variant.
                return "\(alias.label) · \(suffix)"
            }
        }
        var words = modelID.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard words.count >= 2, !words.contains("") else { return nil }
        let families: Set<String> = ["gpt", "claude", "opus", "sonnet", "haiku", "fable", "gemini", "deepseek", "grok", "llama", "qwen", "kimi", "mistral", "hermes"]
        guard families.contains(words[0].lowercased()) else { return nil }
        if words[0].lowercased() == "claude", ["opus", "sonnet", "haiku", "fable"].contains(words[1].lowercased()) {
            words.removeFirst()
        }
        let casing = ["gpt": "GPT", "oss": "OSS", "deepseek": "DeepSeek"]
        let formatted = words.map { word in
            casing[word.lowercased()] ?? String(word.prefix(1)).uppercased() + word.dropFirst()
        }
        if formatted[0] == "GPT" { return "GPT-" + formatted.dropFirst().joined(separator: " ") }
        return formatted.joined(separator: " ")
    }

    private static func isInteger(_ number: NSNumber) -> Bool {
        switch String(cString: number.objCType) {
        case "s", "i", "l", "q", "S", "I", "L", "Q":
            true
        default:
            false
        }
    }

    private static func isValidText(
        _ value: String,
        maximumLength: Int,
        permitsEmpty: Bool
    ) -> Bool {
        guard value.count <= maximumLength else { return false }
        if !permitsEmpty, value.isEmpty { return false }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

enum ModelNameCatalogError: Error, Equatable {
    case payloadTooLarge
    case malformedPayload
}
