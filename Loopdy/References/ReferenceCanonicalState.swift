import Foundation

/// Local selection routing only. Never included in user.message or its appendix.
/// These are adapter identifiers, not credentials, grants, tokens or vault records.
struct ReferenceCanonicalSelectionBinding: Codable, Equatable, Sendable {
    let id: UUID
    let providerID: String
    let sourceKindLabel: String
    let identityKey: String

    init(_ selection: ReferenceDraftSelection) {
        id = selection.id
        providerID = selection.providerID
        sourceKindLabel = selection.sourceKindLabel
        identityKey = selection.snapshot.identityKey
    }

    func selection(snapshot: ReferenceSnapshot) -> ReferenceDraftSelection {
        ReferenceDraftSelection(id: id, providerID: providerID,
            sourceKindLabel: sourceKindLabel, snapshot: snapshot)
    }
}

/// Explicit Codable wrapper keeps ephemeral hub DTOs out of the wire schema.
struct ReferenceCanonicalOwner: Codable, Equatable, Sendable {
    let accountID: String
    let hostID: String
    let deviceID: String
    let authorizationEpoch: String
    let sessionID: String
    let agentID: String
    let recipientIDs: [String]

    init(_ owner: ReferenceHubOwner) {
        accountID = owner.accountID
        hostID = owner.hostID
        deviceID = owner.deviceID
        authorizationEpoch = owner.authorizationEpoch
        sessionID = owner.sessionID
        agentID = owner.agentID
        recipientIDs = owner.recipientIDs
    }

    var hubOwner: ReferenceHubOwner {
        ReferenceHubOwner(accountID: accountID, hostID: hostID, deviceID: deviceID,
            authorizationEpoch: authorizationEpoch, sessionID: sessionID,
            agentID: agentID, recipientIDs: recipientIDs)
    }

    func matches(_ owner: ReferenceHubOwner) -> Bool {
        let lhs = [accountID, hostID, deviceID, authorizationEpoch, sessionID, agentID] + recipientIDs
        let rhs = [owner.accountID, owner.hostID, owner.deviceID, owner.authorizationEpoch,
                   owner.sessionID, owner.agentID] + owner.recipientIDs
        return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            Data($0.utf8) == Data($1.utf8)
        }
    }
}

/// One unresolved submission lives in the existing SessionRecord, not another
/// transcript/outbox. Retain the exact prepared wire request and attachment data
/// before the first upload. Reopening never automatically uploads or resubmits.
struct ReferenceCanonicalSubmission: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared
        case indeterminate
        case accepted
        case rejected
    }

    let submissionID: UUID
    let draftID: UUID
    let revision: UInt64
    let owner: ReferenceCanonicalOwner
    let routingSource: String
    let selections: [ReferenceCanonicalSelectionBinding]
    let message: LoopdyLinkUserMessage
    let attachments: [ChatAttachment]
    var phase: Phase

    init(frozen: ReferenceFrozenDraft, message: LoopdyLinkUserMessage,
         attachments: [ChatAttachment]) {
        submissionID = frozen.submissionID
        draftID = frozen.draftID
        revision = frozen.revision
        owner = ReferenceCanonicalOwner(frozen.owner)
        routingSource = frozen.routingSource
        selections = frozen.selections.map(ReferenceCanonicalSelectionBinding.init)
        self.message = message
        self.attachments = attachments
        phase = .prepared
    }

    var frozenDraft: ReferenceFrozenDraft? {
        let decoded = ReferenceCodec.decode(message.text)
        guard decoded.hasValidAppendix,
              Data(decoded.prose.utf8) == Data(routingSource.utf8),
              message.sessionID == owner.sessionID, message.agentID == owner.agentID,
              message.messageID == Self.messageID(for: submissionID),
              let restored = ReferenceCanonicalState.restoreSelections(
                decoded.references, bindings: selections)
        else { return nil }
        return ReferenceFrozenDraft(submissionID: submissionID, draftID: draftID,
            revision: revision, owner: owner.hubOwner, routingSource: routingSource,
            canonicalText: message.text, selections: restored)
    }

    static func messageID(for submissionID: UUID) -> String {
        "message_" + submissionID.uuidString
    }
}

/// Nullable, legacy-safe local metadata alongside SessionRecord.draft. Snapshot
/// bytes remain authoritative in the existing canonical draft string.
struct ReferenceCanonicalState: Codable, Equatable, Sendable {
    var selections: [ReferenceCanonicalSelectionBinding]
    var submission: ReferenceCanonicalSubmission?
    var draftID: UUID? = nil
    var draftRevision: UInt64? = nil

    static func restoreSelections(_ snapshots: [ReferenceSnapshot],
                                  bindings: [ReferenceCanonicalSelectionBinding]) -> [ReferenceDraftSelection]? {
        guard snapshots.count == bindings.count,
              Set(bindings.map(\.id)).count == bindings.count else { return nil }
        var result: [ReferenceDraftSelection] = []
        for (snapshot, binding) in zip(snapshots, bindings) {
            guard Data(snapshot.identityKey.utf8) == Data(binding.identityKey.utf8) else { return nil }
            result.append(binding.selection(snapshot: snapshot))
        }
        return result
    }

    /// Missing legacy bindings still restore the exact snapshots, but have no
    /// provider authority. The root must explicitly bind a selected provider;
    /// an empty providerID deliberately cannot revalidate private cached data.
    static func restoredDraft(_ canonical: String, state: Self?)
        -> (source: String, selections: [ReferenceDraftSelection]) {
        let decoded = ReferenceCodec.decode(canonical)
        guard decoded.hasValidAppendix else { return (canonical, []) }
        let restored = restoreSelections(decoded.references, bindings: state?.selections ?? [])
            ?? decoded.references.map {
                ReferenceDraftSelection(providerID: "", sourceKindLabel: $0.kind.rawValue, snapshot: $0)
            }
        return (decoded.prose, restored)
    }
}

enum ReferenceCanonicalSendOutcome: Equatable, Sendable {
    case accepted
    case rejected
    case indeterminate
    case superseded
    case unavailable
}

enum ReferenceCanonicalSendError: Error, Equatable {
    case unavailable
    case invalidDraft
    case persistenceUnavailable
    /// Only a matching authenticated negative receipt or a proven pre-write
    /// refusal may use this case. Timeout/cancellation/disconnect never may.
    case rejected
}

/// The actual socket must implement this opt-in boundary. There is intentionally
/// no fallback to unguarded submit/send. Existing ordinary messaging is unchanged.
@MainActor
protocol ReferenceCanonicalLinkMessaging: LoopdyLinkChatMessaging {
    /// Synchronous, no vault/provider/network/outbox mutation. Use the actual
    /// selected-host cipher + encrypted frame encoder, not a plaintext estimate.
    func validateReferenceEnvelopes(
        message: LoopdyLinkUserMessage,
        chunks: [LoopdyLinkAttachmentChunk],
        owner: ReferenceHubOwner
    ) throws

    /// Recheck after EVERY internal connection/backpressure await and immediately
    /// before each enqueue/upload/transmit. Keep an already-enqueued frame in the
    /// existing socket outbox on ambiguity; never enqueue a different intent.
    func uploadReferenceAttachmentChunks(
        _ chunks: [LoopdyLinkAttachmentChunk],
        owner: ReferenceHubOwner,
        remainsOwned: @escaping @MainActor () -> Bool
    ) async throws

    /// Return only on the existing validated user.message.result accepted
    /// receipt for the exact message/session/agent, not relay frame acceptance.
    func submitReferenceMessage(
        _ message: LoopdyLinkUserMessage,
        owner: ReferenceHubOwner,
        remainsOwned: @escaping @MainActor () -> Bool
    ) async throws
}

@MainActor
protocol ReferenceCanonicalConversationClient: ConversationClient {
    func prepareReferenceSubmission(
        _ frozen: ReferenceFrozenDraft,
        attachments: [ChatAttachment],
        behavior: MidSessionChatBehavior?
    ) throws -> ReferenceCanonicalSubmission

    func submitReference(
        _ submission: ReferenceCanonicalSubmission,
        remainsOwned: @escaping @MainActor () -> Bool
    ) async throws
}

/// Canonical rows awaiting host history remain in the existing transcript. Match
/// only IDs/platform IDs, never equal prose or a newly seen assistant reply.
enum ReferenceCanonicalHistory {
    static func matchingHuman(in items: [TimelineItem], submission: ReferenceCanonicalSubmission) -> TimelineItem? {
        let matches = items.filter {
            $0.role == .human && $0.metadata.platformMessageID == submission.message.messageID
        }
        guard matches.count == 1, let item = matches.first,
              case .message(let text) = item.content,
              Data(text.utf8) == Data(submission.message.text.utf8) else { return nil }
        return item
    }

    static func preservingAcceptedRows(local: [TimelineItem], incoming: [TimelineItem]) -> [TimelineItem] {
        var result = incoming
        for row in local where row.role == .human {
            guard let platformID = row.metadata.platformMessageID,
                  case .message(let text) = row.content,
                  ReferenceCodec.decode(text).hasValidAppendix,
                  !incoming.contains(where: { $0.id == row.id || $0.metadata.platformMessageID == platformID })
            else { continue }
            result.append(row)
        }
        return result
    }
}
