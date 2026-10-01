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

    /// Hermes' browser vault asks for a site's one-time code. It used to be
    /// refused at once, so browser sign-ins with two-step codes always failed.
    @Test func aSitesOneTimeCodeGoesToTheWaitingRequest() async throws {
        let (store, connection) = try boundStore()
        defer { store.retireConnection(connection) }
        let task = Task { await store.handle(.init(id: "code-id", method: "vault.code", params: [
            "session_id": .string("runtime"), "site": .string("example.com"), "hint": .null,
        ]), connection: connection) }
        for _ in 0..<100 where store.activePrompt == nil { await Task.yield() }
        let prompt = try #require(store.activePrompt)
        #expect(prompt.kind == .vaultCode)
        #expect(prompt.site == "example.com")
        await store.submitCode(prompt, code: "482 913")
        #expect(await task.value == .result(.object(["value": .string("482913")])))
    }

    @Test func aSavedLoginIsSentAsTheJSONHermesReads() async throws {
        let (store, connection) = try boundStore()
        defer { store.retireConnection(connection) }
        let task = Task { await store.handle(.init(id: "login-id", method: "vault.save_login", params: [
            "session_id": .string("runtime"), "origin": .string("https://example.com"), "site": .string("example.com"),
        ]), connection: connection) }
        for _ in 0..<100 where store.activePrompt == nil { await Task.yield() }
        let prompt = try #require(store.activePrompt)
        #expect(prompt.kind == .vaultSaveLogin)
        #expect(prompt.site == "https://example.com")
        await store.submitLogin(prompt, identifier: " fixture@example.com ", password: "made-up \"pass\"")
        guard case .result(let value) = await task.value, let text = value.object?["value"]?.string,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String] else {
            Issue.record("No JSON answer"); return
        }
        #expect(object == ["identifier": "fixture@example.com", "password": "made-up \"pass\""])
    }

    @Test func aPasswordManagerUnlockNamesTheManagerAndCancelsEmpty() async throws {
        let (store, connection) = try boundStore()
        defer { store.retireConnection(connection) }
        let task = Task { await store.handle(.init(id: "unlock-id", method: "vault.unlock_prompt", params: [
            "session_id": .string("runtime"), "backend": .string("bitwarden"), "display_name": .string("Bitwarden"),
        ]), connection: connection) }
        for _ in 0..<100 where store.activePrompt == nil { await Task.yield() }
        let prompt = try #require(store.activePrompt)
        #expect(prompt.title == "Unlock Bitwarden")
        await store.cancel(prompt)
        #expect(await task.value == .result(.object(["value": .string("")])))
    }

    @Test(arguments: [
        ["origin": "javascript:alert(1)", "site": "x"],
        ["origin": "https://user:pw@example.com", "site": "x"],
        ["origin": "https://example.com"],
        ["origin": "https://example.com", "site": "x", "extra": "y"],
    ])
    func malformedVaultPromptsAreRefused(fields: [String: String]) async throws {
        let (store, connection) = try boundStore()
        defer { store.retireConnection(connection) }
        var params = fields.mapValues(BighelpJSONValue.string)
        params["session_id"] = .string("runtime")
        let result = await store.handle(.init(id: "bad", method: "vault.save_login", params: params),
                                        connection: connection)
        guard case .error = result else { Issue.record("Malformed vault prompt accepted"); return }
        #expect(store.activePrompt == nil)
    }

    private func boundStore() throws -> (DirectHermesSecurePromptStore, DirectHermesPromptConnection) {
        let identity = NSObject()
        let connection = DirectHermesPromptConnection(owner: UUID(), principalIdentity: "host",
            clientIdentity: ObjectIdentifier(identity), transportGeneration: .init(UUID()))
        let store = DirectHermesSecurePromptStore()
        store.beginConnection(connection, dependencies: dependencies)
        try store.bind(profile: "default", runtimeID: "runtime", visibleSessionID: "chat", connection: connection)
        objc_setAssociatedObject(store, &Self.identityKey, identity, .OBJC_ASSOCIATION_RETAIN)
        return (store, connection)
    }

    nonisolated(unsafe) private static var identityKey = 0

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
