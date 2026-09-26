import Foundation

struct AgentHandle: Identifiable, Equatable, Sendable {
    let profileID: String
    let handle: String

    var id: String { profileID }

    static func directory(for profiles: [AgentProfile]) -> [AgentHandle] {
        var assigned: Set<String> = []
        return profiles.map { profile in
            let base = normalized(profile.name)
            let handle = nextAvailable(base: base, occupied: assigned)
            assigned.insert(handle)
            return AgentHandle(profileID: profile.id, handle: handle)
        }
    }

    static func unique(base: String, excluding profileID: String?, profiles: [AgentProfile]) -> String {
        let occupied = Set(
            directory(for: profiles)
                .filter { $0.profileID != profileID }
                .map(\.handle)
        )
        return nextAvailable(base: normalized(base), occupied: occupied)
    }

    private static func nextAvailable(base: String, occupied: Set<String>) -> String {
        guard occupied.contains(base) else { return base }
        var suffix = 2
        while occupied.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    static func normalized(_ value: String, locale: Locale = normalizationLocale) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        let pieces = folded.unicodeScalars.split(whereSeparator: { scalar in
            !CharacterSet.alphanumerics.contains(scalar)
        })
        let handle = pieces.map(String.init).joined(separator: "-").lowercased(with: locale)
        return handle.isEmpty ? "agent" : handle
    }

    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")
}
