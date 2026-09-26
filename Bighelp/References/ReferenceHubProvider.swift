import Foundation

/// Ephemeral authority coordinates. Never encode these into reference appendices.
struct ReferenceHubOwner: Equatable, Sendable {
    let accountID: String
    let hostID: String
    let deviceID: String
    let authorizationEpoch: String
    let sessionID: String
    let agentID: String
    let recipientIDs: [String]
}

struct ReferenceHubResult: Identifiable, Equatable, Sendable {
    /// Stable within this adapter and authority epoch, not a credential.
    let resourceID: String
    let providerID: String
    let category: ReferenceCategory
    let title: String
    let subtitle: String
    let state: String?
    let isCached: Bool
    var id: String { "\(providerID.utf8.count):\(providerID)\(resourceID)" }
}

struct ReferenceHubSearchPage: Sendable {
    let results: [ReferenceHubResult]
    let isPartial: Bool
}

/// Each choice is already bounded and contains exactly what its label offers.
/// GitHub adapters put metadata-only first; descriptions require an explicit choice.
/// Wiki adapters can offer the page and individually resolved sections.
struct ReferenceContentOption: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let snapshot: ReferenceSnapshot
}

struct ReferenceHubPreview: Equatable, Sendable {
    let result: ReferenceHubResult
    let sourceKindLabel: String
    let options: [ReferenceContentOption]
}

/// Adapters own credentials, permission checks, paging and provider budgets.
/// Closures must validate ALL supplied owner coordinates before and after I/O.
/// Search/resolve must be read-only. Revalidate must preserve the user's selected
/// section/description scope and throw on revoked/offline/unverifiable access.
@MainActor
struct ReferenceHubProvider {
    let id: String
    let label: String
    let categories: Set<ReferenceCategory>
    let search: @MainActor (ReferenceHubOwner, ReferenceCategory, String) async throws -> ReferenceHubSearchPage
    let resolve: @MainActor (ReferenceHubOwner, ReferenceHubResult) async throws -> ReferenceHubPreview
    let revalidate: @MainActor (ReferenceHubOwner, ReferenceSnapshot) async throws -> ReferenceSnapshot
}

struct ReferenceDraftSelection: Identifiable, Equatable, Sendable {
    let id: UUID
    let providerID: String
    let sourceKindLabel: String
    let snapshot: ReferenceSnapshot

    init(id: UUID = UUID(), providerID: String, sourceKindLabel: String, snapshot: ReferenceSnapshot) {
        self.id = id
        self.providerID = providerID
        self.sourceKindLabel = sourceKindLabel
        self.snapshot = snapshot
    }
}

/// Parent freezes submission identity and transport envelope bounds before using
/// canonicalText. Route ONLY from routingSource and the explicit owner recipients;
/// never parse imported appendix/title/body as command or mention input.
struct ReferenceFrozenDraft: Sendable {
    let submissionID: UUID
    let draftID: UUID
    let revision: UInt64
    let owner: ReferenceHubOwner
    let routingSource: String
    let canonicalText: String
    let selections: [ReferenceDraftSelection]
    var snapshots: [ReferenceSnapshot] { selections.map(\.snapshot) }
}

struct ReferenceRevalidationChange: Identifiable, Sendable {
    let original: ReferenceDraftSelection
    let current: ReferenceSnapshot
    var id: UUID { original.id }
}

enum ReferenceSendPreparation: Sendable {
    case ready(ReferenceFrozenDraft)
    case needsConfirmation([ReferenceRevalidationChange])
    case unavailable
    case superseded
}

/// Synchronous native transaction. The editor must check exact source, selection,
/// revision, draft and marked text, and register one undo operation.
struct ReferenceNativeEdit {
    let draftID: UUID
    let revision: UInt64
    let source: String
    let selection: NSRange
    let range: NSRange
    let replacement: String
    let resultingSelection: NSRange
    let selections: [ReferenceDraftSelection]
    let actionName: String
}
