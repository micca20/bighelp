import Foundation

/// Request identity and journal-derived locking for Wiki file creation.
@MainActor
enum WikiCreationState {
    struct FolderRequest: Hashable {
        let rootID: String
        let folder: String
        let offset: Int
        let refreshID: UUID
    }

    /// Only the journal-derived creation lock is retired; the caller owns the free source.
    static func resetRetiredDocument(_ document: inout WikiDocument?, pendingID: String?, saving: Bool) {
        if !saving && pendingID == nil { document = nil }
    }
}
