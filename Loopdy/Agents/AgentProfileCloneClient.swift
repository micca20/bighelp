import Foundation

struct AgentProfileClonePlan: Equatable, Sendable {
    let id: UUID
    let owner: WorkspaceOwner
    let sourceProfileID: String
    let destinationProfileID: String
    let includesCredentials: Bool
    let includesMemory: Bool
    let includesHistory: Bool
    let includesSkills: Bool
    var includesAvatar = false
}

struct AgentProfileMutationReceipt: Equatable, Sendable {
    let profileID: String
}

@MainActor
protocol AgentProfileCloneClient: AnyObject {
    func prepareClone(sourceProfileID: String, destinationProfileID: String,
                      owner: WorkspaceOwner) async throws -> AgentProfileClonePlan
    func clone(_ reviewedPlan: AgentProfileClonePlan) async throws
        -> WorkspaceMutationOutcome<AgentProfileMutationReceipt>
}
