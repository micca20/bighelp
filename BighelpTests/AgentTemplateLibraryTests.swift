import Foundation
import Testing
@testable import Bighelp

@MainActor
struct AgentTemplateLibraryTests {
    private func libraryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-templates-\(UUID().uuidString).json")
    }

    @Test func savedTemplatesKeepTheAgentsSetupAndSurviveRelaunch() throws {
        let url = libraryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let library = AgentTemplateLibrary(fileURL: url)
        let first = library.save(from: .financeFixture)
        let second = library.save(from: .financeFixture)

        #expect(first.title == "Finley")
        #expect(second.title == "Finley 2")
        #expect(first.role == "Finance")
        #expect(first.instructions == "Help with budgets.")
        #expect(library.templates.map(\.id) == [second.id, first.id])

        library.rename(first.id, to: "  Budget helper  ")
        library.rename(second.id, to: "   ")
        library.delete(second.id)

        let reopened = AgentTemplateLibrary(fileURL: url)
        #expect(reopened.templates.map(\.title) == ["Budget helper"])
    }

    @Test func newAgentFromTemplateGetsAnUnusedName() async throws {
        let url = libraryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let store = AgentDirectoryStore(client: client, defaults: isolatedDefaults())
        try await store.load()
        let template = AgentTemplateLibrary(fileURL: url).save(from: .financeFixture)

        let model = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor(), template: template)

        #expect(model.editingAgentID == nil)
        #expect(model.draft.name == "Finley 2")
        #expect(model.draft.role == "Finance")
        #expect(model.draft.summary == "A finance specialist.")
        #expect(model.draft.instructions == "Help with budgets.")
    }

    @Test func theDefaultAgentCannotBeDeleted() {
        #expect(!AgentDeletionPresentation.canDelete(.defaultFixture))
        #expect(AgentDeletionPresentation.canDelete(.financeFixture))
        #expect(AgentDeletionPresentation.title(.financeFixture) == "Delete Finley?")
    }
}
