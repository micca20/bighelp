import Foundation
import Testing
@testable import Bighelp

@MainActor
struct PersonalityStoreTests {
    @Test func staleMutationCleanupCannotClearNewAccountSaveState() async {
        let client = DeferredPersonalityMutationClient()
        let store = PersonalityStore(client: client)
        await store.load()

        let oldSave = Task {
            await store.save(Self.draft(name: "old-account"))
        }
        await client.waitUntilMutationStarts(count: 1)

        store.resetForAccountBoundary()
        await store.load()
        let newSave = Task {
            await store.save(Self.draft(name: "new-account"))
        }
        await client.waitUntilMutationStarts(count: 2)

        client.resumeMutation(
            request: 1,
            with: PersonalityCatalog(revision: 2, activeName: "old-account", personalities: [])
        )
        await oldSave.value
        #expect(store.isSaving)

        client.resumeMutation(
            request: 2,
            with: PersonalityCatalog(revision: 3, activeName: "new-account", personalities: [])
        )
        await newSave.value
        #expect(!store.isSaving)
    }

    @Test func resetInvalidatesAnInFlightRemoteLoad() async {
        let client = DeferredPersonalityClient()
        let store = PersonalityStore(client: client)
        let loading = Task { await store.load() }

        await client.waitUntilLoadStarts()
        store.resetForAccountBoundary()
        client.resumeLoad(with: PersonalityCatalog(revision: 9, activeName: "old", personalities: []))
        await loading.value

        #expect(store.catalog == nil)
        #expect(store.loadState == .idle)
        #expect(store.errorMessage == nil)
    }

    @Test func personalityActionsExposeEditAndOnlyAllowDeleteWhenSupported() {
        let builtIn = PersonalityDefinition(
            name: "helpful",
            description: "Friendly and useful",
            systemPrompt: "Be helpful.",
            tone: "Warm",
            style: "Clear",
            isBuiltIn: true,
            isCustomized: false
        )
        let customizedBuiltIn = PersonalityDefinition(
            name: "helpful",
            description: "Friendly and useful",
            systemPrompt: "Be helpful.",
            tone: "Warm",
            style: "Clear",
            isBuiltIn: true,
            isCustomized: true
        )
        let custom = PersonalityDefinition(
            name: "focused",
            description: "Quietly deliberate",
            systemPrompt: "Work carefully.",
            tone: "Calm",
            style: "Structured",
            isBuiltIn: false,
            isCustomized: true
        )

        #expect(builtIn.availableActions == [.use, .edit])
        #expect(customizedBuiltIn.availableActions == [.use, .edit, .delete])
        #expect(custom.availableActions == [.use, .edit, .delete])
    }

    @Test func loadsSavesActivatesAndDeletesThroughRevisionedHermesCatalogs() async throws {
        let helpful = PersonalityDefinition(
            name: "helpful",
            description: "Friendly and useful",
            systemPrompt: "Be helpful.",
            tone: "Warm",
            style: "Clear",
            isBuiltIn: true,
            isCustomized: false
        )
        let fixture = PersonalityClientFixture(
            catalog: PersonalityCatalog(revision: 3, activeName: "helpful", personalities: [helpful])
        )
        let store = PersonalityStore(client: fixture)

        await store.load()
        #expect(store.catalog?.activeName == "helpful")
        #expect(store.personalities.map(\.name) == ["helpful"])

        await store.save(
            PersonalityDraft(
                originalName: nil,
                name: "focused",
                description: "Quietly deliberate",
                systemPrompt: "Work carefully and stay focused.",
                tone: "Calm",
                style: "Structured"
            )
        )
        #expect(fixture.requests.last?.action == .save)
        #expect(fixture.requests.last?.expectedRevision == 3)
        #expect(store.personalities.contains { $0.name == "focused" })

        await store.activate(name: "focused")
        #expect(fixture.requests.last?.action == .activate)
        #expect(store.catalog?.activeName == "focused")

        await store.delete(name: "focused")
        #expect(fixture.requests.last?.action == .delete)
        #expect(!store.personalities.contains { $0.name == "focused" })
    }

    @Test func draftValidationRejectsNeutralNamesAndEmptyPrompts() {
        #expect(throws: PersonalityValidationError.self) {
            try PersonalityDraft.validated(
                originalName: nil,
                name: "none",
                description: "No overlay",
                systemPrompt: "Do something",
                tone: "",
                style: ""
            )
        }
        #expect(throws: PersonalityValidationError.self) {
            try PersonalityDraft.validated(
                originalName: nil,
                name: "focused",
                description: "Focused",
                systemPrompt: "   ",
                tone: "",
                style: ""
            )
        }
    }

    @Test func draftValidationPreservesHermesMultilineSystemPrompts() throws {
        let draft = try PersonalityDraft.validated(
            originalName: nil,
            name: "focused",
            description: "Quietly deliberate",
            systemPrompt: "Work carefully.\n\n- Verify assumptions\n- Explain decisions",
            tone: "Calm",
            style: "Structured"
        )

        #expect(draft.systemPrompt == "Work carefully.\n\n- Verify assumptions\n- Explain decisions")
    }

    private static func draft(name: String) -> PersonalityDraft {
        PersonalityDraft(
            originalName: nil,
            name: name,
            description: "Test personality",
            systemPrompt: "Be useful.",
            tone: "Warm",
            style: "Clear"
        )
    }
}

@MainActor
private final class PersonalityClientFixture: PersonalityClient {
    private var value: PersonalityCatalog
    private(set) var requests: [PersonalityMutation] = []

    init(catalog: PersonalityCatalog) {
        value = catalog
    }

    func load() async throws -> PersonalityCatalog { value }

    func mutate(_ request: PersonalityMutation) async throws -> PersonalityCatalog {
        requests.append(request)
        var personalities = value.personalities
        var activeName = value.activeName
        switch request.action {
        case .save:
            let draft = try #require(request.draft)
            personalities.removeAll { $0.name == draft.originalName || $0.name == draft.name }
            personalities.append(
                PersonalityDefinition(
                    name: draft.name,
                    description: draft.description,
                    systemPrompt: draft.systemPrompt,
                    tone: draft.tone,
                    style: draft.style,
                    isBuiltIn: false,
                    isCustomized: true
                )
            )
        case .delete:
            personalities.removeAll { $0.name == request.name }
            if activeName == request.name { activeName = "" }
        case .activate:
            activeName = request.name ?? ""
        }
        value = PersonalityCatalog(
            revision: value.revision + 1,
            activeName: activeName,
            personalities: personalities.sorted { $0.name < $1.name }
        )
        return value
    }
}

@MainActor
private final class DeferredPersonalityClient: PersonalityClient {
    private var loadContinuation: CheckedContinuation<PersonalityCatalog, Error>?
    private var loadStarted = false

    func load() async throws -> PersonalityCatalog {
        loadStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
        }
    }

    func mutate(_ request: PersonalityMutation) async throws -> PersonalityCatalog {
        throw BighelpLinkWireError.invalidValue
    }

    func waitUntilLoadStarts() async {
        while !loadStarted { await Task.yield() }
    }

    func resumeLoad(with catalog: PersonalityCatalog) {
        loadContinuation?.resume(returning: catalog)
        loadContinuation = nil
    }
}

@MainActor
private final class DeferredPersonalityMutationClient: PersonalityClient {
    private let value = PersonalityCatalog(revision: 1, activeName: "helpful", personalities: [])
    private var mutationContinuations: [Int: CheckedContinuation<PersonalityCatalog, Error>] = [:]
    private var mutationCount = 0

    func load() async throws -> PersonalityCatalog { value }

    func mutate(_ request: PersonalityMutation) async throws -> PersonalityCatalog {
        mutationCount += 1
        let requestNumber = mutationCount
        return try await withCheckedThrowingContinuation { continuation in
            mutationContinuations[requestNumber] = continuation
        }
    }

    func waitUntilMutationStarts(count: Int) async {
        while mutationCount < count { await Task.yield() }
    }

    func resumeMutation(request: Int, with catalog: PersonalityCatalog) {
        mutationContinuations.removeValue(forKey: request)?.resume(returning: catalog)
    }
}
