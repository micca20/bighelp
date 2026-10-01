import SwiftUI

/// Search on the Hermes Tools lists: a row matches when every word typed appears
/// in one of the fields it shows, ignoring case and accents. No search matches everything.
enum ManagementSearch {
    static func isActive(_ search: String) -> Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func matches(_ search: String, _ fields: String?...) -> Bool {
        let words = search.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = fields.compactMap { $0 }.joined(separator: " ")
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// Shown in place of a list's sections when a search finds nothing.
struct ManagementSearchEmptySection: View {
    let search: String

    var body: some View {
        Section {
            ContentUnavailableView.search(text: search.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .accessibilityIdentifier("management.search.empty")
    }
}
