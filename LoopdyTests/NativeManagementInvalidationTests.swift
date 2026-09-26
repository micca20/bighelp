import Foundation
import Testing
@testable import Loopdy

@MainActor
struct NativeManagementInvalidationTests {
    @Test func pairingBurstCoalescesAndRetainsOneTrailingRead() async throws {
        let client = InvalidationPairingFixture()
        client.holdNextList = true
        let store = PairingManagementStore(hostName: "Fixture", profileID: "default", client: client, isCurrent: { true })
        defer { client.releaseList(); store.retire() }
        let review = PairingManagementStore.Review.clearPending(0)
        store.review = review
        store.receivePairingInvalidation(revision: 1)
        store.receivePairingInvalidation(revision: 2)
        try await waitUntil { client.listGate != nil }
        #expect(client.listCalls == 1)
        store.receivePairingInvalidation(revision: 3)
        store.receivePairingInvalidation(revision: 4)
        client.releaseList()
        try await waitUntil { client.listCalls == 2 && !store.isLoading }
        #expect(store.catalog?.profileID == "default")
        #expect(store.review == review)
        store.retire()
        store.receivePairingInvalidation(revision: 5)
        for _ in 0..<20 { await Task.yield() }
        #expect(client.listCalls == 2)
    }

    @Test func mutationDefersInvalidationAndPreservesConfirmedOutcome() async throws {
        let client = InvalidationPairingFixture()
        let store = PairingManagementStore(hostName: "Fixture", profileID: "default", client: client, isCurrent: { true })
        defer { client.releaseMutation(); store.retire() }
        let review = PairingManagementStore.Review.clearPending(0)
        store.review = review
        let mutation = Task { await store.confirm(review) }
        try await waitUntil { client.mutationGate != nil }
        store.receivePairingInvalidation(revision: 1)
        store.receivePairingInvalidation(revision: 2)
        for _ in 0..<20 { await Task.yield() }
        #expect(client.listCalls == 0)
        client.releaseMutation()
        await mutation.value
        try await waitUntil { client.listCalls == 2 && !store.isLoading }
        // One readback belongs to the mutation, one to the coalesced notice.
        #expect(client.clearCalls == 1)
        #expect(store.successMessage == "Hermes confirmed 0 pending requests cleared.")
        #expect(store.errorMessage == nil)
    }

    @Test func changedOwnerRejectsHeldReadPublication() async throws {
        let client = InvalidationPairingFixture()
        client.holdNextList = true
        var isCurrent = true
        let store = PairingManagementStore(hostName: "Fixture", profileID: "default", client: client, isCurrent: { isCurrent })
        defer { client.releaseList(); store.retire() }
        store.receivePairingInvalidation(revision: 1)
        try await waitUntil { client.listGate != nil }
        isCurrent = false
        client.releaseList()
        try await waitUntil { !store.isLoading }
        #expect(store.catalog == nil)
        store.receivePairingInvalidation(revision: 2)
        for _ in 0..<20 { await Task.yield() }
        #expect(client.listCalls == 1)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }
}

@MainActor
private final class InvalidationPairingFixture: HermesPairingManaging {
    var listCalls = 0
    var clearCalls = 0
    var holdNextList = false
    var listGate: CheckedContinuation<Void, Never>?
    var mutationGate: CheckedContinuation<Void, Never>?

    func list(profileID: String) async throws -> HermesPairingCatalog {
        listCalls += 1
        if holdNextList {
            holdNextList = false
            await withCheckedContinuation { listGate = $0 }
        }
        return .init(profileID: profileID, pending: [], approved: [])
    }
    func clearPending(profileID: String) async throws -> Int {
        clearCalls += 1
        await withCheckedContinuation { mutationGate = $0 }
        return 0
    }
    func approve(_ request: HermesPairingPendingRequest, profileID: String) async throws -> HermesPairingApprovedUser {
        throw DirectHermesError.invalidResponse
    }
    func revoke(_ user: HermesPairingApprovedUser, profileID: String) async throws {
        throw DirectHermesError.invalidResponse
    }
    func releaseList() {
        let pending = listGate
        listGate = nil
        pending?.resume()
    }
    func releaseMutation() {
        let pending = mutationGate
        mutationGate = nil
        pending?.resume()
    }
}
