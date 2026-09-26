import Foundation

struct GitHubIdentity: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let login: String

    static func decode(_ data: Data) throws -> GitHubIdentity {
        let object = try GitHubJSON.parse(data).object()
        let id = try object.required("id").integer(min: 1)
        let login = try object.required("login").string(max: 100)
        guard login.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,99}$"#, options: .regularExpression) != nil,
              try object.required("type").string() == "User"
        else { throw GitHubError.invalidResponse }
        return GitHubIdentity(id: id, login: login)
    }
}

enum GitHubResourceKind: String, Codable, CaseIterable, Sendable {
    case repository, issue, pullRequest
}

/// Provider-neutral source metadata, NOT a credential/connection/reference model.
/// `description` is nil unless explicitly requested; content is inert external data.
struct GitHubResource: Equatable, Identifiable, Sendable {
    let kind: GitHubResourceKind
    let nodeID: String
    /// Exact positive REST decimal lexemes; never derived from the display number or node ID.
    let repositoryID: String
    let resourceID: String
    /// Catalog/search observations must be resolved before mapping to a reference snapshot.
    let isResolved: Bool
    let isDraft: Bool
    let repository: String
    let number: Int?
    let title: String
    let url: URL
    let state: String
    let isPrivate: Bool
    let description: String?
    let descriptionTruncated: Bool
    let revision: String
    let fetchedAt: Date

    var id: String { "github.com:\(kind.rawValue):\(nodeID)" }

    var withoutDescription: GitHubResource {
        GitHubResource(kind: kind, nodeID: nodeID, repositoryID: repositoryID, resourceID: resourceID,
                       isResolved: isResolved, isDraft: isDraft, repository: repository, number: number, title: title,
                       url: url, state: state, isPrivate: isPrivate, description: nil, descriptionTruncated: false,
                       revision: revision, fetchedAt: fetchedAt)
    }

    /// Timestamp-only observations do not require renewed content confirmation.
    func hasSameContent(as other: GitHubResource) -> Bool {
        kind == other.kind && nodeID == other.nodeID && repositoryID == other.repositoryID
            && resourceID == other.resourceID && isResolved == other.isResolved && isDraft == other.isDraft
            && repository == other.repository && number == other.number
            && title == other.title && url == other.url && state == other.state && isPrivate == other.isPrivate
            && description == other.description && descriptionTruncated == other.descriptionTruncated
    }
}

struct GitHubResourcePage: Sendable {
    let resources: [GitHubResource]
    /// Includes pagination/search-budget truncation, incomplete_results and inaccessible installations.
    let isPartial: Bool
    let retryAfter: Date?
    let fetchedAt: Date
    let isCached: Bool

    init(resources: [GitHubResource], isPartial: Bool, retryAfter: Date?, fetchedAt: Date, isCached: Bool = false) {
        self.resources = resources
        self.isPartial = isPartial
        self.retryAfter = retryAfter
        self.fetchedAt = fetchedAt
        self.isCached = isCached
    }
}

enum GitHubContent {
    static func safe(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)(?:github_pat_|gh[pousr]_)[A-Za-z0-9_]+"#,
            with: "[credential redacted]", options: .regularExpression
        )
    }
}
