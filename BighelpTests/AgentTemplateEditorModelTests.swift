import Foundation
import Testing
@testable import Bighelp

@MainActor
struct AgentTemplateEditorModelTests {
    @Test func emptyCatalogDerivesAnIndependentDraftWithoutSaving() async throws {
        let fixture = try TemplateEditorFixture()
        await fixture.model.load()
        #expect(fixture.client.listCalls == 1)
        #expect(fixture.client.deriveCalls == 1)
        #expect(fixture.client.saved.isEmpty)
        #expect(fixture.model.document?.sourceProfileID == AgentProfile.financeFixture.id)
        #expect(fixture.model.document?.revision == nil)
        #expect(fixture.model.isDirty && fixture.model.canSave)
        #expect(!fixture.model.isLoading)
    }

    @Test func saveAdoptsTheSameDocumentAndUsesAcceptedRevisionForNextEdit() async throws {
        let fixture = try TemplateEditorFixture()
        await fixture.model.load()
        let id = try #require(fixture.model.document?.id)
        fixture.model.updateTitle("  Independent plan  ")
        await fixture.model.save()
        #expect(fixture.client.saved.count == 1)
        #expect(fixture.client.saved[0].document.id == id)
        #expect(fixture.client.saved[0].document.title == "Independent plan")
        #expect(fixture.client.saved[0].expectedRevision == nil)
        #expect(fixture.client.saved[0].owner == fixture.owner)
        #expect(fixture.client.saved[0].document.sourceProfileID == AgentProfile.financeFixture.id)
        #expect(!fixture.model.isDirty && !fixture.model.canSave)
        #expect(fixture.model.confirmationMessage != nil)
        fixture.model.updateSection("A later SOUL edit")
        await fixture.model.save()
        #expect(fixture.client.saved.count == 2)
        #expect(fixture.client.saved[1].document.id == id)
        #expect(fixture.client.saved[1].expectedRevision == "accepted-revision-1")
        #expect(fixture.model.document?.soul == "A later SOUL edit")
        #expect(!fixture.model.isSaving)
    }

    @Test func allFiveSectionsEditOnlyTheIndependentDocument() async throws {
        let fixture = try TemplateEditorFixture()
        await fixture.model.load()
        let source = fixture.model.source
        for section in AgentTemplateSection.allCases {
            fixture.model.selectedSection = section
            fixture.model.updateSection("edited-\(section.rawValue)")
        }
        for section in AgentTemplateSection.allCases {
            #expect(fixture.model.document?.text(for: section) == "edited-\(section.rawValue)")
        }
        #expect(fixture.model.source == source)
        #expect(fixture.client.saved.isEmpty)
    }

    @Test func dirtyDraftCannotBeReplacedByOpenOrCreateNew() async throws {
        let fixture = try TemplateEditorFixture()
        await fixture.model.load()
        fixture.model.updateTitle("Keep my unsaved work")
        let before = fixture.model.document
        await fixture.model.open(UUID().uuidString.lowercased())
        await fixture.model.createNew()
        #expect(fixture.model.document == before)
        #expect(fixture.client.readCalls == 0)
        #expect(fixture.client.deriveCalls == 1)
    }

    @Test func ownerRetirementDuringCatalogReadCannotPublishOrDerive() async throws {
        let fixture = try TemplateEditorFixture()
        fixture.client.beforeListReturn = { fixture.current = false }
        await fixture.model.load()
        #expect(fixture.model.catalog == nil)
        #expect(fixture.model.document == nil)
        #expect(fixture.client.deriveCalls == 0)
        #expect(fixture.model.errorMessage == nil)
        #expect(!fixture.model.isLoading && !fixture.model.canSave)
        fixture.client.beforeListReturn = nil
    }

    @Test func cancellationFencesALateDerivedDocument() async throws {
        let fixture = try TemplateEditorFixture()
        fixture.client.beforeDeriveReturn = { fixture.model.cancel() }
        await fixture.model.load()
        #expect(fixture.model.document == nil)
        #expect(fixture.model.errorMessage == nil)
        #expect(!fixture.model.isLoading)
        fixture.client.beforeDeriveReturn = nil
    }

    @Test func unknownSaveKeepsDraftAndDoesNotClaimSuccessOrAutomaticallyRetry() async throws {
        let fixture = try TemplateEditorFixture()
        await fixture.model.load()
        fixture.model.updateSection("Keep this after an uncertain save")
        let before = fixture.model.document
        fixture.client.saveError = .outcomeUnknown
        await fixture.model.save()
        #expect(fixture.client.saved.count == 1)
        #expect(fixture.model.document == before)
        #expect(fixture.model.isDirty)
        #expect(fixture.model.confirmationMessage == nil)
        #expect(fixture.model.errorMessage != nil)
        #expect(!fixture.model.isSaving)
    }

    @Test func wrongProfileCatalogIsRejectedBeforeOpeningItsContent() async throws {
        let fixture = try TemplateEditorFixture()
        fixture.client.catalogProfileOverride = "other-profile"
        await fixture.model.load()
        #expect(fixture.model.document == nil && fixture.model.catalog == nil)
        #expect(fixture.client.deriveCalls == 0 && fixture.client.readCalls == 0)
        #expect(fixture.model.errorMessage != nil)
    }
}

@MainActor
private final class TemplateEditorFixture {
    let owner: WorkspaceOwner
    let client = TemplateEditorClient()
    var current = true
    lazy var model = AgentTemplateEditorModel(source: .financeFixture, owner: owner, client: client,
                                             isCurrent: { [weak self] in self?.current == true })
    init() throws {
        owner = WorkspaceOwner(authority: try .fixture(id: "template-editor"),
                               authenticationGeneration: UUID(), connectionGeneration: UUID())
    }
}

@MainActor
private final class TemplateEditorClient: AgentProfileTemplateClient {
    struct Save {
        let document: AgentTemplateDocument
        let expectedRevision: String?
        let owner: WorkspaceOwner
    }
    var listCalls = 0
    var deriveCalls = 0
    var readCalls = 0
    var saved: [Save] = []
    var saveError: WorkspaceClientError?
    var catalogProfileOverride: String?
    var beforeListReturn: (() -> Void)?
    var beforeDeriveReturn: (() -> Void)?

    func list(profileID: String, owner: WorkspaceOwner) async throws -> AgentTemplateCatalog {
        listCalls += 1
        beforeListReturn?()
        return AgentTemplateCatalog(profileID: catalogProfileOverride ?? profileID,
                                    storageFolder: ".loopdy/agent-templates/\(profileID)", templates: [])
    }
    func derive(profileID: String, templateID: UUID, owner: WorkspaceOwner) async throws -> AgentTemplateDocument {
        deriveCalls += 1
        beforeDeriveReturn?()
        return AgentTemplateDocument(id: templateID.uuidString.lowercased(), title: "Independent draft",
                                     sourceProfileID: profileID, sourceSnapshotRevision: "source-revision",
                                     derivedAt: Date(timeIntervalSince1970: 1_700_000_000), soul: "Original independent SOUL",
                                     skillsJSON: "[]", mcpServersJSON: "[]", toolsJSON: "[]", configJSON: "{}",
                                     omissions: ["Credentials omitted"], revision: nil)
    }
    func read(profileID: String, templateID: String, owner: WorkspaceOwner) async throws -> AgentTemplateDocument {
        readCalls += 1
        throw WorkspaceClientError.invalidRequest
    }
    func save(_ document: AgentTemplateDocument, profileID: String, expectedRevision: String?,
              owner: WorkspaceOwner) async throws -> AgentTemplateDocument {
        saved.append(Save(document: document, expectedRevision: expectedRevision, owner: owner))
        if let saveError { throw saveError }
        var result = document
        result.revision = "accepted-revision-\(saved.count)"
        return result
    }
}
