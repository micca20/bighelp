import Foundation

/// Unimplemented optional surfaces fail explicitly instead of inheriting Link
/// clients, fixture data, local Bot execution, or a synthetic native fork.
@MainActor
final class NativeWorkspaceUnavailableClient: BotModeMemberTurnClient, SessionForkClient,
    VoiceSessionClient, DashboardDataSource, PersonalityClient, HermesSkillsAndToolsCatalogClient,
    ProjectGitClient, ConversationClient {
    var allowsLocalAgentReassignment: Bool { false }
    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        throw WorkspaceClientError.transportUnavailable
    }
    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        throw WorkspaceClientError.transportUnavailable
    }
    func performMemberTurn(_ request: BotModeMemberTurnRequest) async throws -> BotModeMemberTurnResult {
        throw WorkspaceClientError.unavailable(.driverUnavailable)
    }
    func fork(_ request: SessionForkRequest) async throws -> SessionForkReceipt {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func respond(to transcript: String, conversationID: String,
                 onDraft: @escaping (String) -> Void) async throws -> VoiceAgentReply {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func steer(_ transcript: String, conversationID: String) async throws {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func speak(_ text: String) async throws { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
    func speak(_ text: String, onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void) async throws {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func stopSpeaking() {}
    func endSession(conversationID: String) async throws {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func loadDashboard() async throws -> DashboardSnapshot {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func load() async throws -> PersonalityCatalog { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
    func mutate(_ request: PersonalityMutation) async throws -> PersonalityCatalog {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func load(agentID: String) async throws -> HermesSkillsAndToolsCatalog {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func diff(agentID: String, sessionID: String, workspaceID: String, path: String,
              side: ProjectGitDiffSide, statusToken: String, offset: Int, limit: Int) async throws -> ProjectGitDiffPage {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
}
