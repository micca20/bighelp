import Foundation

/// A strict, readable JSON metadata envelope records inclusion intent durably.
/// Node identity belongs to the resource, never the selected credential/user.
enum ReferenceGitHubAdapterSnapshot {
    struct Selection {
        let kind: GitHubResourceKind
        let repository: String
        let number: Int?
        let repositoryID: String
        let resourceID: String
        let nodeID: String
        let includesDescription: Bool
    }

    private static let keys: Set<String> = ["schema", "nodeID", "state", "isPrivate", "isDraft",
                                            "includesDescription", "description", "descriptionTruncated"]

    static func make(_ resource: GitHubResource, includesDescription: Bool) throws -> ReferenceSnapshot {
        guard resource.isResolved,
              resource.url == (try GitHubURLPolicy.canonicalURL(repository: resource.repository,
                                                               kind: resource.kind, number: resource.number)),
              validNode(resource.nodeID) else { throw ReferenceAdapterError.invalidSource }
        let names = resource.repository.split(separator: "/", omittingEmptySubsequences: false)
        guard names.count == 2 else { throw ReferenceAdapterError.invalidSource }
        let kind: ReferenceKind
        switch resource.kind {
        case .repository: kind = .repository
        case .issue: kind = .issue
        case .pullRequest: kind = .pullRequest
        }
        let identity = GitHubReferenceIdentity(repositoryID: resource.repositoryID,
            resourceID: kind == .repository ? nil : resource.resourceID,
            owner: String(names[0]), repository: String(names[1]), number: resource.number)
        var budget = 4_096
        while true {
            let excerpt = ReferenceAdapterContent.prefix(resource.description ?? "", maximumBytes: budget)
            let truncated = includesDescription && (resource.descriptionTruncated || excerpt.truncated)
            let description: Any
            if includesDescription, resource.description != nil {
                description = excerpt.text + (truncated ? ReferenceAdapterContent.truncationMarker : "")
            } else { description = NSNull() }
            let object: [String: Any] = [
                "schema": "loopdy-github-reference-v1", "nodeID": resource.nodeID,
                "state": resource.state, "isPrivate": resource.isPrivate, "isDraft": resource.isDraft,
                "includesDescription": includesDescription, "description": description,
                "descriptionTruncated": truncated
            ]
            let data = try JSONSerialization.data(withJSONObject: object,
                                                 options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
            let snapshot = try ReferenceSnapshot(kind: kind, identity: .github(identity), title: resource.title,
                selectedContent: String(decoding: data, as: UTF8.self), sourceRevision: resource.revision,
                fetchedAt: resource.fetchedAt, isTruncated: truncated)
            _ = try selection(snapshot)
            if ReferenceAdapterContent.fits(snapshot) { return snapshot }
            guard includesDescription, budget > 0 else { throw ReferenceAdapterError.invalidSource }
            budget /= 2
        }
    }

    static func selection(_ snapshot: ReferenceSnapshot) throws -> Selection {
        guard case .github(let identity) = snapshot.identity else { throw ReferenceAdapterError.invalidSource }
        let kind: GitHubResourceKind
        switch snapshot.kind {
        case .repository: kind = .repository
        case .issue: kind = .issue
        case .pullRequest: kind = .pullRequest
        case .wiki: throw ReferenceAdapterError.invalidSource
        }
        do {
            let fields = try GitHubJSON.parse(Data(snapshot.selectedContent.utf8), limit: 16_384).object()
            guard Set(fields.keys) == keys,
                  try fields.required("schema").string() == "loopdy-github-reference-v1" else {
                throw ReferenceAdapterError.invalidSource
            }
            let nodeID = try fields.required("nodeID").string(max: 200)
            let includes = try fields.required("includesDescription").boolean()
            let truncated = try fields.required("descriptionTruncated").boolean()
            let description = try fields.optionalString("description", max: 8_192)
            let isDraft = try fields.required("isDraft").boolean()
            _ = try fields.required("isPrivate").boolean()
            let state = try fields.required("state").string(max: 20)
            let states: Set<String>
            switch kind {
            case .repository: states = ["active", "archived", "disabled"]
            case .issue: states = ["open", "closed"]
            case .pullRequest: states = ["open", "closed", "merged"]
            }
            guard validNode(nodeID), states.contains(state), (!isDraft || kind == .pullRequest),
                  truncated == snapshot.isTruncated,
                  includes || (description == nil && !truncated),
                  !truncated || (description?.hasSuffix(ReferenceAdapterContent.truncationMarker) == true),
                  ISO8601DateFormatter().date(from: snapshot.sourceRevision) != nil else {
                throw ReferenceAdapterError.invalidSource
            }
            return Selection(kind: kind, repository: identity.owner + "/" + identity.repository,
                number: identity.number, repositoryID: identity.repositoryID,
                resourceID: identity.resourceID ?? identity.repositoryID, nodeID: nodeID,
                includesDescription: includes)
        } catch { throw ReferenceAdapterError.invalidSource }
    }

    private static func validNode(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200 && GitHubContent.safe(value) == value
            && value.range(of: #"^[A-Za-z0-9_+/=-]+$"#, options: .regularExpression) != nil
    }
}
