import Foundation
import Testing
@testable import Bighelp

@MainActor
struct AgentDuplicateModelTests {
    @Test func sensitiveCloneRequiresExplicitReviewConsent() async throws {
        let client = CloneClient()
        let model = try model(client)
        model.destinationProfileID = "new-profile"
        await model.prepare()
        #expect(model.requiresSensitiveConsent)
        #expect(!model.canConfirm)
        await model.confirm()
        #expect(client.cloneCalls == 0)
        model.acknowledgesSensitiveCopy = true
        await model.confirm()
        #expect(client.cloneCalls == 1)
        #expect(model.result == .committed)
    }

    @Test func unconfirmedOutcomeNeverAllowsASecondCreate() async throws {
        let client = CloneClient()
        client.outcome = .unconfirmed
        let model = try model(client)
        model.destinationProfileID = "new-profile"
        await model.prepare()
        model.acknowledgesSensitiveCopy = true
        await model.confirm()
        await model.confirm()
        #expect(model.result == .unconfirmed)
        #expect(!model.canConfirm)
        #expect(client.cloneCalls == 1)
    }

    @Test func mismatchedReadbackIsUnconfirmedNotSuccess() async throws {
        let client = CloneClient()
        client.outcome = .committed(AgentProfileMutationReceipt(profileID: "different-profile"))
        let model = try model(client)
        model.destinationProfileID = "new-profile"
        await model.prepare()
        model.acknowledgesSensitiveCopy = true
        await model.confirm()
        #expect(model.result == .unconfirmed)
    }

    @Test func mismatchedPlanCannotBeConfirmed() async throws {
        let client = CloneClient()
        client.changesDestination = true
        let model = try model(client)
        model.destinationProfileID = "new-profile"
        await model.prepare()
        #expect(model.plan == nil)
        #expect(model.errorMessage != nil)
        #expect(!model.canConfirm)
    }

    @Test func partialOutcomeRetainsTruthAndCannotRepeatCreate() async throws {
        let client = CloneClient()
        client.outcome = .partial(value: AgentProfileMutationReceipt(profileID: "new-profile"), unappliedFields: ["avatar"])
        let model = try model(client)
        model.destinationProfileID = "new-profile"
        await model.prepare()
        model.acknowledgesSensitiveCopy = true
        await model.confirm()
        #expect(model.result == .partial)
        #expect(!model.canConfirm)
    }

    @Test func replacedOwnerCannotSubmitAReviewedPlan() async throws {
        let client = CloneClient()
        let model = try model(client, isCurrent: { client.isCurrent })
        model.destinationProfileID = "new-profile"
        await model.prepare()
        model.acknowledgesSensitiveCopy = true
        client.isCurrent = false
        await model.confirm()
        #expect(client.cloneCalls == 0)
        #expect(!model.canConfirm)
    }

    private func model(
        _ client: CloneClient, isCurrent: @escaping @MainActor () -> Bool = { true }
    ) throws -> AgentDuplicateModel {
        AgentDuplicateModel(
            source: .financeFixture,
            owner: WorkspaceOwner(authority: try .fixture(id: "clone-test"), authenticationGeneration: UUID(), connectionGeneration: UUID()),
            client: client, isCurrent: isCurrent
        )
    }
}

@MainActor
private final class CloneClient: AgentProfileCloneClient {
    var cloneCalls = 0
    var changesDestination = false
    var isCurrent = true
    var outcome: WorkspaceMutationOutcome<AgentProfileMutationReceipt> = .committed(.init(profileID: "new-profile"))

    func prepareClone(sourceProfileID: String, destinationProfileID: String, owner: WorkspaceOwner) async throws -> AgentProfileClonePlan {
        AgentProfileClonePlan(
            id: UUID(), owner: owner, sourceProfileID: sourceProfileID,
            destinationProfileID: changesDestination ? "other-profile" : destinationProfileID,
            includesCredentials: true, includesMemory: true, includesHistory: false, includesSkills: true
        )
    }

    func clone(_ reviewedPlan: AgentProfileClonePlan) async throws -> WorkspaceMutationOutcome<AgentProfileMutationReceipt> {
        cloneCalls += 1
        return outcome
    }
}
