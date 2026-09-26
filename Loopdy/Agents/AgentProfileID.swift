import Foundation

/// Derives a new host identifier without changing the user-facing name or any
/// existing profile ID. Stock Hermes accepts lowercase ASCII IDs up to64 bytes.
enum AgentProfileID {
    static func generated(from displayName: String, occupied: Set<String> = []) -> String {
        let allowed = AgentHandle.normalized(displayName).unicodeScalars.filter {
            $0.isASCII && ((97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "-")
        }
        let trimmed = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = trimmed.isEmpty ? "agent" : String(trimmed.prefix(48))
        let unavailable = Set(occupied.map { $0.lowercased(with: Locale(identifier: "en_US_POSIX")) })
            .union(["hermes", "default", "test", "tmp", "root", "sudo"])
        if !unavailable.contains(base) { return base }
        var suffix = 2
        while unavailable.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }
}
