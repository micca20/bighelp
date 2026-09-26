import Foundation

/// Source strings are encoded without normalization; byte equality, not Swift
/// canonical String equality, decides whether a draft has changed.
struct WikiDraft: Codable, Identifiable, Sendable {
    let id: UUID
    var document: WikiDocument
    var workingSource: String
    var currentDocument: WikiDocument?
    var recoveryCopies: [WikiDraftRecoveryCopy] = []
    var updatedAt: Date

    var isDirty: Bool { Data(workingSource.utf8) != document.originalBytes }
    var needsFreshBase: Bool { currentDocument != nil }

    init(document: WikiDocument) {
        id = UUID()
        self.document = document
        workingSource = document.originalSource
        updatedAt = .now
    }

    static func sameFile(_ lhs: WikiDocument, _ rhs: WikiDocument) -> Bool {
        lhs.owner == rhs.owner && lhs.root.wikiId == rhs.root.wikiId
            && Data(lhs.path.utf8) == Data(rhs.path.utf8)
    }
}

struct WikiDraftRecoveryCopy: Codable, Identifiable, Sendable {
    let id: UUID
    let document: WikiDocument
    let workingSource: String
    let operationID: String?
    let retainedAt: Date
}

struct WikiDraftState: Codable, Sendable {
    let owner: WikiOwner
    var drafts: [WikiDraft]
}

enum WikiDraftLimits {
    static let draftsPerOwner = 8
    static let recoveryCopiesPerDraft = 4
    static let ownerFilesPerAccount = 64
    static let accountBytes = 40 * 1_024 * 1_024
    static let memoryDrafts = 32

    static func validateDocument(_ document: WikiDocument, owner: WikiOwner) throws {
        guard owner.isValid, document.owner == owner, document.connection.owner == owner,
              document.path.utf8.count <= 4_096, WikiNavigation.isMarkdownPath(document.path),
              !document.path.hasPrefix("/"),
              !document.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                  $0.isEmpty || $0 == "." || $0 == ".."
              }),
              !document.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              document.connection.name.utf8.count <= 1_024,
              document.root.name.utf8.count <= 1_024,
              document.root.wikiId.utf8.count <= 1_024,
              document.root.sourceKind.utf8.count <= 64,
              Data(document.originalSource.utf8) == document.originalBytes,
              document.isNewFile || (WikiLimits.validRevision(document.baseRevision, generation: document.root.generation)
                && document.baseRevision.hasSuffix(":" + WikiLimits.digest(document.originalBytes))) else { throw WikiError.invalidResponse }
        guard document.originalBytes.count <= WikiLimits.editBytes else { throw WikiError.oversized }
    }

    static func validate(_ state: WikiDraftState) throws {
        guard state.owner.isValid, state.drafts.count <= draftsPerOwner,
              Set(state.drafts.map(\.id)).count == state.drafts.count else { throw WikiError.quota }
        for (index, draft) in state.drafts.enumerated() {
            try validateDocument(draft.document, owner: state.owner)
            guard draft.workingSource.utf8.count <= WikiLimits.editBytes,
                  draft.recoveryCopies.count <= recoveryCopiesPerDraft else { throw WikiError.quota }
            guard !state.drafts.prefix(index).contains(where: { WikiDraft.sameFile($0.document, draft.document) }) else {
                throw WikiError.invalidResponse
            }
            if let current = draft.currentDocument {
                try validateDocument(current, owner: state.owner)
                guard WikiDraft.sameFile(current, draft.document) else { throw WikiError.invalidResponse }
            }
            for copy in draft.recoveryCopies {
                try validateDocument(copy.document, owner: state.owner)
                guard WikiDraft.sameFile(copy.document, draft.document),
                      copy.workingSource.utf8.count <= WikiLimits.editBytes,
                      (copy.operationID?.utf8.count ?? 0) <= 512 else { throw WikiError.invalidResponse }
            }
        }
    }
}

enum WikiDraftError: Error, LocalizedError {
    case persistence, editLimit, inactive, copiesFull

    var errorDescription: String? {
        switch self {
        case .persistence:
            "The local Wiki draft could not be preserved. Keep this editor open and retry after unlocking the device, or export a copy."
        case .editLimit:
            "This change was not applied because the editable draft limit is 1 MiB. Export or split the document instead; nothing was truncated."
        case .inactive:
            "This Wiki editor is no longer bound to the active account and host. Reopen the file from Wiki."
        case .copiesFull:
            "This draft has reached its recovery-copy limit. Export and explicitly remove a retained copy before accepting another base."
        }
    }

    static func message(_ error: Error) -> String {
        if let error = error as? WikiDraftError { return error.localizedDescription }
        if let error = error as? WikiError { return error.localizedDescription }
        return WikiDraftError.persistence.localizedDescription
    }
}
