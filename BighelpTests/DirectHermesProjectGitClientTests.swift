import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesProjectGitClientTests {
    private let token = "sha256:" + String(repeating: "a", count: 64)
    private let nextToken = "sha256:" + String(repeating: "b", count: 64)

    @Test func capabilitiesUseFullNativeStoredSessionWithoutLinkFramingOrCallerPaths() async throws {
        let fixture = try GitFixture()
        fixture.responses[.projectsGitCapabilities] = [.success(capabilities())]
        let result = try await fixture.client.capabilities(agentID: "default", sessionID: "visible-chat", workspaceID: "p_notes")
        #expect(result.workspaces.first?.operations == [.status])
        #expect(!result.capabilities.stage && !result.capabilities.commit && !result.capabilities.fetch
            && !result.capabilities.pull && !result.capabilities.push)
        #expect(fixture.calls == [.init(operation: .projectsGitCapabilities, payload: [
            "agentId": .string("default"), "sessionId": .string(fixture.storedID), "workspaceId": .string("p_notes")
        ])])
    }

    @Test(arguments: ["missing", "profile", "owner", "visible", "stored"])
    func unresolvedOrMismatchedSessionFailsBeforeAnyRequest(_ mismatch: String) async throws {
        let fixture = try GitFixture()
        switch mismatch {
        case "missing": fixture.coordinate = nil
        case "profile": fixture.coordinate = try fixture.makeCoordinate(profile: "other")
        case "owner": fixture.coordinate = try fixture.makeCoordinate(owner: GitFixture.makeOwner())
        case "visible": fixture.coordinate = try fixture.makeCoordinate(visible: "other-visible")
        default: fixture.coordinate = try fixture.makeCoordinate(stored: nil)
        }
        await #expect(throws: WorkspaceClientError.unavailable(.identityContextUnavailable)) {
            try await fixture.client.status(agentID: "default", sessionID: "visible-chat", workspaceID: "p_notes")
        }
        #expect(fixture.calls.isEmpty)
    }

    @Test func nativeCoordinateBoundsAndGrammarAreEnforcedWithoutAliasResolution() async throws {
        let fixture = try GitFixture()
        fixture.coordinate = try fixture.makeCoordinate(stored: String(repeating: "a", count: 129))
        await #expect(throws: WorkspaceClientError.invalidRequest) {
            try await fixture.client.status(agentID: "default", sessionID: "visible-chat", workspaceID: "p_notes")
        }
        fixture.coordinate = try fixture.makeCoordinate(stored: "native/session")
        await #expect(throws: WorkspaceClientError.invalidRequest) {
            try await fixture.client.status(agentID: "default", sessionID: "visible-chat", workspaceID: "p_notes")
        }
        fixture.coordinate = try fixture.makeCoordinate()
        await #expect(throws: WorkspaceClientError.invalidRequest) {
            try await fixture.client.status(agentID: "default", sessionID: "visible-chat", workspaceID: String(repeating: "p", count: 81))
        }
        #expect(fixture.calls.isEmpty)
    }

    @Test(arguments: ["stage", "commit", "push", "fetch", "pull", "arbitraryCommand"])
    func advertisedMutationCapabilityNeverEnablesNativeWrites(_ key: String) async throws {
        let fixture = try GitFixture()
        var response = capabilities()
        var flags = try #require(response["capabilities"]?.object)
        flags[key] = .boolean(true)
        response["capabilities"] = .object(flags)
        fixture.responses[.projectsGitCapabilities] = [.success(response)]
        await #expect(throws: (any Error).self) {
            try await fixture.client.capabilities(agentID: "default", sessionID: "visible-chat", workspaceID: "p_notes")
        }
    }

    @Test func statusPreservesServerContentTokenAndExactMetadata() async throws {
        let fixture = try GitFixture()
        fixture.responses[.projectsGitStatus] = [.success(status())]
        let value = try await readStatus(fixture)
        #expect(value.statusToken == token)
        #expect(value.head.branch == "main")
        #expect(value.files.first?.availableDiffSides == [.staged, .worktree])
        #expect(value.changes == .init(files: 1, insertions: 2, deletions: 1))
        #expect(value.filesPage.isComplete)
        #expect(fixture.calls.first?.payload["path"] == nil)
    }

    @Test func incompleteStatusCannotPretendToHaveUsableStatusPagination() async throws {
        let fixture = try GitFixture()
        var value = status()
        value["filesPage"] = .object([
            "offset": .integer(0), "limit": .integer(500), "returned": .integer(1),
            "total": .integer(501), "nextOffset": .integer(1), "complete": .boolean(false)
        ])
        value["changes"] = .object(["files": .integer(501), "insertions": .integer(2), "deletions": .integer(1)])
        fixture.responses[.projectsGitStatus] = [.success(value)]
        await #expect(throws: WorkspaceClientError.capacityExceeded) { try await readStatus(fixture) }
        #expect(fixture.calls.count == 1)
    }

    @Test func wrongWorkspaceStatusAndConflictsOutsideItsFilesAreRejected() async throws {
        let fixture = try GitFixture()
        var wrong = status()
        wrong["workspaceId"] = .string("another-project")
        var conflict = status()
        conflict["conflicts"] = .array([.string("unlisted.swift")])
        conflict["conflictsPage"] = .object(page(count: 1))
        fixture.responses[.projectsGitStatus] = [.success(wrong), .success(conflict)]
        await #expect(throws: WorkspaceClientError.invalidResponse) { try await readStatus(fixture) }
        await #expect(throws: WorkspaceClientError.invalidResponse) { try await readStatus(fixture) }
    }

    @Test func diffRequiresTheExactObservedTokenAndListedSide() async throws {
        let fixture = try GitFixture()
        fixture.responses[.projectsGitStatus] = [.success(status())]
        _ = try await readStatus(fixture)
        await #expect(throws: (any Error).self) { try await readDiff(fixture, token: nextToken) }
        await #expect(throws: WorkspaceClientError.invalidRequest) { try await readDiff(fixture, path: "unlisted.md") }
        #expect(fixture.calls.count == 1)
        let stagedOnly = try GitFixture()
        stagedOnly.responses[.projectsGitStatus] = [.success(status(index: "M", worktree: "."))]
        _ = try await readStatus(stagedOnly)
        await #expect(throws: WorkspaceClientError.invalidRequest) { try await readDiff(stagedOnly) }
        #expect(stagedOnly.calls.count == 1)
    }

    @Test(arguments: ["/etc/passwd", "../secret", "a/../b", "a//b", ":(glob)**", "*.md", "file?.txt", "-option", "a\\b", "a\nb"])
    func unsafeDiffPathsNeverReachTheHost(_ path: String) async throws {
        let fixture = try GitFixture()
        await #expect(throws: WorkspaceClientError.invalidRequest) { try await readDiff(fixture, path: path) }
        #expect(fixture.calls.isEmpty)
    }

    @Test func unmergedDiffIsUnsupportedNotAnAvailableEmptyCombinedHunk() async throws {
        let fixture = try GitFixture()
        fixture.responses[.projectsGitStatus] = [.success(status(kind: "unmerged", index: "U", worktree: "U", conflict: true))]
        _ = try await readStatus(fixture)
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) { try await readDiff(fixture) }
        #expect(fixture.calls.count == 1)
    }

    @Test func diffPagesForwardUnchangedServerTokenAndPreserveTextPreviewBytes() async throws {
        let fixture = try GitFixture()
        let preview = "\u{FEFF}# Family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\n  text\t \r\n"
        fixture.responses[.projectsGitStatus] = [.success(status())]
        fixture.responses[.projectsGitDiff] = [
            .success(diff(offset: 0, next: 1, preview: preview)),
            .success(diff(offset: 1))
        ]
        let observedStatus = try await readStatus(fixture)
        let first = try await readDiff(fixture, limit: 1)
        let second = try await readDiff(fixture, offset: 1, limit: 1)
        #expect(first.previewContent.map { Data($0.utf8) } == Data(preview.utf8))
        #expect(first.nextOffset == 1)
        #expect(second.lines.first?.offset == 1)
        #expect(second.nextOffset == nil)
        #expect(fixture.calls.last?.payload == [
            "agentId": .string("default"), "sessionId": .string(fixture.storedID), "workspaceId": .string("p_notes"),
            "path": .string("README.md"), "side": .string("worktree"),
            "statusToken": .string(token), "offset": .integer(1), "limit": .integer(1)
        ])
        let file = try #require(observedStatus.files.first)
        #expect(ProjectChangesMarkdownPreviewBuilder.preview(for: first, file: file) == .content(preview))
    }

    @Test(arguments: ["binary", "oversized"])
    func nativeAvailabilityRemainsTypedWithNoFakePreview(_ availability: String) async throws {
        let fixture = try GitFixture()
        fixture.responses[.projectsGitStatus] = [.success(status())]
        fixture.responses[.projectsGitDiff] = [.success([
            "path": .string("README.md"), "side": .string("worktree"), "availability": .string(availability),
            "offset": .integer(0), "lines": .array([]), "nextOffset": .null
        ])]
        _ = try await readStatus(fixture)
        let page = try await readDiff(fixture)
        #expect(page.availability.rawValue == availability)
        #expect(page.lines.isEmpty && page.previewContent == nil && page.nextOffset == nil)
    }

    @Test func malformedPageCannotExceedRequestedLimitOrMakeNoProgress() async throws {
        let fixture = try GitFixture()
        fixture.responses[.projectsGitStatus] = [.success(status())]
        var tooMany = diff()
        tooMany["lines"] = .array([line(), line()])
        let stalled: [String: BighelpJSONValue] = [
            "path": .string("README.md"), "side": .string("worktree"), "availability": .string("available"),
            "offset": .integer(0), "lines": .array([]), "nextOffset": .integer(0)
        ]
        fixture.responses[.projectsGitDiff] = [.success(tooMany), .success(stalled)]
        _ = try await readStatus(fixture)
        await #expect(throws: WorkspaceClientError.invalidResponse) { try await readDiff(fixture, limit: 1) }
        await #expect(throws: WorkspaceClientError.invalidResponse) { try await readDiff(fixture) }
    }

    @Test func nativeScopeChangeDuringAwaitCannotPublishIntoAnotherSession() async throws {
        let fixture = try GitFixture()
        fixture.responses[.projectsGitStatus] = [.success(status())]
        fixture.afterResponse = { fixture.coordinate = try fixture.makeCoordinate(stored: "different-native-row") }
        await #expect(throws: WorkspaceClientError.ownerChanged) { try await readStatus(fixture) }
    }

    @Test func connectionReplacementRejectsLateResponse() async throws {
        let fixture = try GitFixture()
        fixture.responses[.projectsGitStatus] = [.success(status())]
        fixture.afterResponse = { fixture.owner = try GitFixture.makeOwner() }
        await #expect(throws: WorkspaceClientError.ownerChanged) { try await readStatus(fixture) }
    }

    @Test func changedStatusDuringDiffCannotPublishAgainstTheOldToken() async throws {
        let fixture = try GitFixture()
        fixture.responses[.projectsGitStatus] = [.success(status()), .success(status(token: nextToken))]
        _ = try await readStatus(fixture)
        fixture.suspendDiff = true
        let pending = Task { try await readDiff(fixture) }
        for _ in 0..<100 where fixture.diffContinuation == nil { await Task.yield() }
        let continuation = try #require(fixture.diffContinuation)
        _ = try await readStatus(fixture)
        continuation.resume(returning: diff())
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(fixture.calls.map(\.operation) == [.projectsGitStatus, .projectsGitDiff, .projectsGitStatus])
    }

    @Test func mismatchedDiffCoordinatesCannotBeRelabeledAsTheRequestedPage() async throws {
        let fixture = try GitFixture()
        fixture.responses[.projectsGitStatus] = [.success(status())]
        _ = try await readStatus(fixture)
        for (key, value) in [
            ("path", BighelpJSONValue.string("another.md")), ("side", .string("staged")), ("offset", .integer(1))
        ] {
            var response = diff()
            response[key] = value
            fixture.responses[.projectsGitDiff] = [.success(response)]
            await #expect(throws: WorkspaceClientError.invalidResponse) { try await readDiff(fixture) }
        }
    }

    @Test func onlyExactNativeNonRepositoryCodeBecomesNAInExistingStore() async throws {
        for code in ["project_not_repository", "git_unavailable", "scope_changed", "session_unavailable"] {
            let fixture = try GitFixture()
            fixture.responses[.projectsGitCapabilities] = [.failure(.rejected(code: code))]
            let store = ProjectChangesStore(client: fixture.client)
            await store.bind(target: target, enabled: true)
            #expect(store.isNotRepository == (code == "project_not_repository"))
            #expect((store.errorMessage == nil) == (code == "project_not_repository"))
            #expect(fixture.calls.count == 1)
        }
    }

    @Test func statusChangedUsesExistingSingleRefetchWithoutSplicingDiffRevisions() async throws {
        let fixture = try GitFixture()
        fixture.responses[.projectsGitCapabilities] = [.success(capabilities())]
        fixture.responses[.projectsGitStatus] = [.success(status()), .success(status(token: nextToken))]
        fixture.responses[.projectsGitDiff] = [.failure(.rejected(code: "status_changed")), .success(diff())]
        let store = ProjectChangesStore(client: fixture.client)
        await store.bind(target: target, enabled: true)
        await store.loadDiff(path: "README.md", side: .worktree)
        #expect(store.errorMessage == nil)
        #expect(store.status?.statusToken == nextToken)
        #expect(store.diff?.offset == 0)
        let calls = fixture.calls.filter { $0.operation == .projectsGitDiff }
        #expect(calls.map { $0.payload["statusToken"] } == [.string(token), .string(nextToken)])
        #expect(calls.map { $0.payload["offset"] } == [.integer(0), .integer(0)])
    }

    @Test func sensitiveAndUnsupportedNativeErrorsRemainFailuresWithoutAlternateReads() async throws {
        for code in ["sensitive_data_blocked", "diff_unsupported", "scope_changed", "status_oversized"] {
            let fixture = try GitFixture()
            fixture.responses[.projectsGitStatus] = [.success(status())]
            fixture.responses[.projectsGitDiff] = [.failure(.rejected(code: code))]
            _ = try await readStatus(fixture)
            await #expect(throws: WorkspaceClientError.rejected(code: code)) { try await readDiff(fixture) }
            #expect(fixture.calls.map(\.operation) == [.projectsGitStatus, .projectsGitDiff])
        }
    }

    @Test func everyMutationIsUnsupportedWithoutEvenReadingTheHost() async throws {
        let fixture = try GitFixture()
        let mutations: [ProjectGitMutation] = [
            .stage(mode: .stage, paths: ["README.md"]), .stage(mode: .unstage, paths: ["README.md"]),
            .commit(message: "Not executed"), .fetch(remote: "origin"), .pull(remote: "origin", branch: "main"),
            .push(remote: "origin", branch: "main")
        ]
        for mutation in mutations {
            let request = ProjectGitMutationRequest(agentID: "default", sessionID: "visible-chat",
                workspaceID: "p_notes", statusToken: token, mutation: mutation)
            await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
                try await fixture.client.prepare(request)
            }
            await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
                try await fixture.client.execute(.init(mutation: request, confirmationToken: "not-a-token", idempotencyKey: "not-an-operation"))
            }
        }
        #expect(fixture.calls.isEmpty)
    }

    private var target: ProjectGitTarget { .init(agentID: "default", sessionID: "visible-chat", workspaceID: "p_notes") }

    private func readStatus(_ fixture: GitFixture) async throws -> ProjectGitStatus {
        try await fixture.client.status(agentID: "default", sessionID: "visible-chat", workspaceID: "p_notes")
    }

    private func readDiff(_ fixture: GitFixture, path: String = "README.md", token: String? = nil,
                          offset: Int = 0, limit: Int = 300) async throws -> ProjectGitDiffPage {
        try await fixture.client.diff(agentID: "default", sessionID: "visible-chat", workspaceID: "p_notes",
            path: path, side: .worktree, statusToken: token ?? self.token, offset: offset, limit: limit)
    }

    private func capabilities() -> [String: BighelpJSONValue] {
        [
            "schemaVersion": .integer(1),
            "capabilities": .object(["status": .boolean(true), "stage": .boolean(false), "commit": .boolean(false),
                "push": .boolean(false), "fetch": .boolean(false), "pull": .boolean(false), "arbitraryCommand": .boolean(false)]),
            "workspaces": .array([.object([
                "workspaceId": .string("p_notes"), "label": .string("Notes"), "visibility": .string("private"),
                "operations": .array([.string("status")]), "remotes": .array([]), "branches": .array([]),
                "mutationsEnabled": .boolean(false)
            ])])
        ]
    }

    private func status(token: String? = nil, kind: String = "ordinary", index: String = "M",
                        worktree: String = "M", conflict: Bool = false) -> [String: BighelpJSONValue] {
        [
            "workspaceId": .string("p_notes"), "statusToken": .string(token ?? self.token),
            "head": .object(["oid": .string(String(repeating: "1", count: 40)), "branch": .string("main"),
                "detached": .boolean(false), "upstream": .null, "ahead": .integer(0), "behind": .integer(0)]),
            "files": .array([.object([
                "path": .string("README.md"), "originalPath": .null, "index": .string(index), "worktree": .string(worktree),
                "kind": .string(kind), "insertions": .integer(2), "deletions": .integer(1), "isBinary": .boolean(false)
            ])]),
            "filesPage": .object(page(count: 1)),
            "staged": .object(["files": .integer(1), "insertions": .integer(1), "deletions": .integer(0)]),
            "changes": .object(["files": .integer(1), "insertions": .integer(2), "deletions": .integer(1)]),
            "conflicts": .array(conflict ? [.string("README.md")] : []),
            "conflictsPage": .object(page(count: conflict ? 1 : 0)), "dirty": .boolean(true)
        ]
    }

    private func page(count: Int) -> [String: BighelpJSONValue] {
        ["offset": .integer(0), "limit": .integer(500), "returned": .integer(count),
         "total": .integer(count), "nextOffset": .null, "complete": .boolean(true)]
    }

    private func diff(offset: Int = 0, next: Int? = nil, preview: String? = nil) -> [String: BighelpJSONValue] {
        var result: [String: BighelpJSONValue] = [
            "path": .string("README.md"), "side": .string("worktree"), "availability": .string("available"),
            "offset": .integer(offset), "lines": .array([line()]), "nextOffset": next.map(BighelpJSONValue.integer) ?? .null
        ]
        if let preview { result["previewContent"] = .string(preview) }
        return result
    }

    private func line() -> BighelpJSONValue {
        .object(["kind": .string("addition"), "oldLine": .null, "newLine": .integer(1), "content": .string("  Synthetic text\t ")])
    }
}

@MainActor
private final class GitFixture: WorkspaceOperationPerforming {
    struct Call: Equatable { let operation: WorkspaceOperation; let payload: [String: BighelpJSONValue] }
    let storedID = "01994b80-2631-7000-8000-000000000001"
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities { .init(owner: owner, values: [.projectChangesRead: .available]) }
    var coordinate: WorkspaceSessionCoordinate?
    var calls: [Call] = []
    var responses: [WorkspaceOperation: [Result<[String: BighelpJSONValue], WorkspaceClientError>]] = [:]
    var afterResponse: (@MainActor () throws -> Void)?
    var suspendDiff = false
    var diffContinuation: CheckedContinuation<[String: BighelpJSONValue], any Error>?
    let client: DirectHermesProjectGitClient

    init() throws {
        let owner = try Self.makeOwner()
        let binding = GitBinding()
        self.owner = owner
        coordinate = try .init(owner: owner, profileID: "default", sessionID: "visible-chat",
            storedSessionID: storedID, runtimeSessionID: "runtime-session")
        client = DirectHermesProjectGitClient(workspace: binding, owner: owner,
            currentOwner: { binding.fixture?.owner }, resolveSession: { binding.fixture?.coordinateFor($0) })
        binding.fixture = self
    }

    static func makeOwner() throws -> WorkspaceOwner {
        .init(authority: try .direct(endpointIdentity: "https://hermes.example", providerID: "password", userID: "fixture"),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    func makeCoordinate(profile: String = "default", visible: String = "visible-chat",
                        stored: String? = "01994b80-2631-7000-8000-000000000001", owner: WorkspaceOwner? = nil) throws -> WorkspaceSessionCoordinate {
        try .init(owner: owner ?? self.owner!, profileID: profile, sessionID: visible,
            storedSessionID: stored, runtimeSessionID: "runtime-session")
    }

    func coordinateFor(_ visible: String) -> WorkspaceSessionCoordinate? { visible == "visible-chat" ? coordinate : nil }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue], owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        calls.append(.init(operation: operation, payload: payload))
        if operation == .projectsGitDiff && suspendDiff {
            return try await withCheckedThrowingContinuation { diffContinuation = $0 }
        }
        guard let response = responses[operation]?.first else { throw WorkspaceClientError.invalidResponse }
        responses[operation]?.removeFirst()
        try afterResponse?()
        return try response.get()
    }
}

@MainActor
private final class GitBinding: WorkspaceOperationPerforming {
    weak var fixture: GitFixture?
    var owner: WorkspaceOwner? { fixture?.owner }
    var capabilities: WorkspaceCapabilities { fixture?.capabilities ?? .disconnected }
    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue], owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        guard let fixture else { throw WorkspaceClientError.ownerChanged }
        return try await fixture.perform(operation, payload: payload, owner: owner)
    }
}
