import Foundation

/// Exact-owner prompt binding and presentation-ID routing; no alternative prompt authority.
extension NativeWorkspaceSessionBridge {
    func bindPromptSession(
        owner: WorkspaceOwner,
        transport: DirectHermesClient,
        profile: String,
        runtimeID: String,
        visibleSessionID: String
    ) throws -> (store: DirectHermesPromptStore, recovery: DirectHermesOpenRequestRecovery) {
        guard !retired, connections.owner == owner,
              let workspace = connections.hosts.selectedWorkspace,
              workspace.nativeClient === transport,
              workspace.connectionGeneration == owner.connectionGeneration else {
            throw WorkspaceClientError.ownerChanged
        }
        return try workspace.bindPromptSession(
            profile: profile,
            runtimeID: runtimeID,
            visibleSessionID: visibleSessionID,
            expectedOwner: owner.connectionGeneration,
            transport: transport
        )
    }

    func unbindPromptSession(_ stream: Stream, visibleSessionID: String) {
        guard let transport = connections.hosts.selectedWorkspace?.nativeClient else { return }
        unbindPromptSession(
            owner: stream.owner,
            transport: transport,
            profile: stream.client.profile,
            runtimeID: stream.client.runtimeID,
            visibleSessionID: visibleSessionID
        )
    }

    func unbindPromptSession(
        owner: WorkspaceOwner,
        transport: DirectHermesClient,
        profile: String,
        runtimeID: String,
        visibleSessionID: String
    ) {
        guard let workspace = connections.hosts.selectedWorkspace else { return }
        workspace.unbindPromptSession(
            profile: profile,
            runtimeID: runtimeID,
            visibleSessionID: visibleSessionID,
            expectedOwner: owner.connectionGeneration,
            transport: transport
        )
    }

    func respondToPromptApproval(presentationID: String, decision: ApprovalDecision) async throws {
        let owner = try currentOwner()
        let (client, prompt) = try promptOwner(presentationID: presentationID, owner: owner)
        try await client.respond(to: prompt, decision: decision)
        guard !retired, connections.owner == owner else { throw WorkspaceClientError.ownerChanged }
    }

    func respondToPromptClarification(presentationID: String, answer: String) async throws {
        let owner = try currentOwner()
        let (client, prompt) = try promptOwner(presentationID: presentationID, owner: owner)
        try await client.respond(to: prompt, value: answer)
        guard !retired, connections.owner == owner else { throw WorkspaceClientError.ownerChanged }
    }

    func respondToPromptClarification(presentationID: String, response: DashboardClarificationResponse) async throws {
        let owner = try currentOwner()
        let (client, prompt) = try promptOwner(presentationID: presentationID, owner: owner)
        try await client.respond(to: prompt, response: response)
        guard !retired, connections.owner == owner else { throw WorkspaceClientError.ownerChanged }
    }

    private func promptOwner(
        presentationID: String,
        owner: WorkspaceOwner
    ) throws -> (DirectHermesConversationClient, DirectHermesPrompt) {
        let identity = Data(presentationID.utf8)
        let matches = streams.values.compactMap { stream -> (DirectHermesConversationClient, DirectHermesPrompt)? in
            guard stream.owner == owner else { return nil }
            let prompts = stream.client.prompts.filter { Data($0.id.utf8) == identity }
            guard prompts.count == 1, let prompt = prompts.first else { return nil }
            return (stream.client, prompt)
        }
        guard matches.count == 1, let match = matches.first else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        return match
    }
}
