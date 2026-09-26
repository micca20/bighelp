import Foundation

struct WorkspaceOwner: Hashable, Sendable {
    let authority: WorkspaceAuthority
    let authenticationGeneration: UUID
    let connectionGeneration: UUID

    var cacheScopeID: String { authority.cacheScopeID }
}

struct WorkspaceSessionCoordinate: Hashable, Sendable {
    let owner: WorkspaceOwner
    let profileID: String
    let sessionID: String
    let storedSessionID: String?
    let runtimeSessionID: String?

    init(owner: WorkspaceOwner, profileID: String, sessionID: String,
         storedSessionID: String?, runtimeSessionID: String?) throws {
        try WorkspaceAuthority.validateIdentifier(profileID, maximumBytes: 128)
        try WorkspaceAuthority.validateIdentifier(sessionID, maximumBytes: 4_096)
        if let storedSessionID {
            try WorkspaceAuthority.validateIdentifier(storedSessionID, maximumBytes: 512)
        }
        if let runtimeSessionID {
            try WorkspaceAuthority.validateIdentifier(runtimeSessionID, maximumBytes: 512)
        }
        self.owner = owner
        self.profileID = profileID
        self.sessionID = sessionID
        self.storedSessionID = storedSessionID
        self.runtimeSessionID = runtimeSessionID
    }
}
