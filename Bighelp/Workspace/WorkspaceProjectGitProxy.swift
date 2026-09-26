import Foundation

@MainActor
final class WorkspaceProjectGitProxy: ProjectGitClient {
    private let box: WorkspaceOwnedClientBox<any ProjectGitClient>
    init(box: WorkspaceOwnedClientBox<any ProjectGitClient>) { self.box = box }

    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities {
        try await box.value().capabilities(agentID: agentID, sessionID: sessionID, workspaceID: workspaceID)
    }
    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus {
        try await box.value().status(agentID: agentID, sessionID: sessionID, workspaceID: workspaceID)
    }
    func diff(agentID: String, sessionID: String, workspaceID: String, path: String,
              side: ProjectGitDiffSide, statusToken: String, offset: Int, limit: Int) async throws -> ProjectGitDiffPage {
        try await box.value().diff(agentID: agentID, sessionID: sessionID, workspaceID: workspaceID, path: path,
                                   side: side, statusToken: statusToken, offset: offset, limit: limit)
    }
    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
}
