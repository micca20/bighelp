import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesSecurePromptTests {
    @Test func canonicalSudoCancelReturnsEmptyValueAndRetiresPrompt() async throws {
        let identity = NSObject()
        let connection = DirectHermesPromptConnection(owner: UUID(), principalIdentity: "host",
            clientIdentity: ObjectIdentifier(identity), transportGeneration: .init(UUID()))
        let store = DirectHermesSecurePromptStore()
        store.beginConnection(connection, dependencies: dependencies)
        defer { store.retireConnection(connection) }
        try store.bind(profile: "default", runtimeID: "runtime", visibleSessionID: "chat", connection: connection)
        let task = Task { await store.handle(.init(id: "sudo-id", method: "sudo",
            params: ["session_id": .string("runtime")]), connection: connection) }
        for _ in 0..<100 where store.activePrompt == nil { await Task.yield() }
        let prompt = try #require(store.activePrompt)
        #expect(prompt.kind == .sudo)
        #expect(prompt.wireID == "sudo-id")
        await store.cancel(prompt)
        #expect(await task.value == .result(.object(["value": .string("")])))
        #expect(store.activePrompt == nil)
    }

    @Test func anAgentsSecureInputRequestShowsItsLabelAndSendsTheValueOnce() async throws {
        let identity = NSObject()
        let connection = DirectHermesPromptConnection(owner: UUID(), principalIdentity: "host",
            clientIdentity: ObjectIdentifier(identity), transportGeneration: .init(UUID()))
        let store = DirectHermesSecurePromptStore()
        store.beginConnection(connection, dependencies: dependencies)
        defer { store.retireConnection(connection) }
        try store.bind(profile: "juniper", runtimeID: "runtime", visibleSessionID: "chat", connection: connection)
        let task = Task { await store.handle(.init(id: "secret-id", method: "secret", params: [
            "session_id": .string("runtime"), "env_var": .string("GITHUB_TOKEN"),
            "prompt": .string("Paste a GitHub token so I can open the pull request."),
            "metadata": .object(["source": .string("agent"), "label": .string("GitHub token")]),
        ]), connection: connection) }
        for _ in 0..<100 where store.activePrompt == nil { await Task.yield() }
        let prompt = try #require(store.activePrompt)
        #expect(prompt.kind == .secret)
        #expect(prompt.isAgentRequest)
        #expect(prompt.title == "GitHub token")
        #expect(prompt.detail == "Paste a GitHub token so I can open the pull request.")
        await store.submitSecret(prompt, value: "ghp_fixture")
        #expect(await task.value == .result(.object(["value": .string("ghp_fixture")])))
        #expect(store.activePrompt == nil)
    }

    @Test func unboundOrUnsupportedSecureRequestsNeverBecomeActionable() async {
        let identity = NSObject()
        let connection = DirectHermesPromptConnection(owner: UUID(), principalIdentity: "host",
            clientIdentity: ObjectIdentifier(identity), transportGeneration: .init(UUID()))
        let store = DirectHermesSecurePromptStore()
        store.beginConnection(connection, dependencies: dependencies)
        defer { store.retireConnection(connection) }
        for method in ["sudo", "vault.code", "vault.unlock_prompt"] {
            let result = await store.handle(.init(id: "id", method: method,
                params: ["session_id": .string("foreign")]), connection: connection)
            guard case .error = result else { Issue.record("Unbound request accepted"); continue }
        }
        #expect(store.activePrompt == nil)
    }

    @Test func skillsActionNamesMatchBoundedHostFamily() {
        for value in ["skills-install-skill-0123abcd", "skills-uninstall-name-89abcdef", "skills-update"] {
            #expect(HermesHostAction(rawValue: value)?.rawValue == value)
        }
        for value in ["skills-install-../secret-0123abcd", "skills-install-name-0123abcg", "skills-install--0123abcd",
                      "skills-remove-name-0123abcd", "skills-install-" + String(repeating: "x", count: 49) + "-0123abcd"] {
            #expect(HermesHostAction(rawValue: value) == nil)
        }
    }

    private var dependencies: DirectHermesSecurePromptDependencies {
        .init(respondToLegacyPrompt: { _, _ in throw WorkspaceClientError.unavailable(.unsupportedOperation) },
              makeMCPClient: { _ in throw WorkspaceClientError.unavailable(.unsupportedOperation) },
              reloadMCP: { _ in throw WorkspaceClientError.unavailable(.unsupportedOperation) })
    }
}
