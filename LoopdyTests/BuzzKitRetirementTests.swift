import Foundation
import Testing
@testable import BuzzKit

@MainActor struct BuzzKitRetirementTests {
    @Test func retiredAuthorityStaysMaskedAfterRelaunchAndFailedCleanup() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        _ = await f.identity.identify(externalId: "owner-A", identityHash: "hash-A")
        f.store.set("subscription-A", for: StorageKey.subscriptionId)
        f.identity.retireSynchronously()
        f.mock.stub { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: (any Error).self) { try await f.push.reconcileRetiredIdentity() }
        let restored = IdentityStore(store: f.store)
        #expect(await restored.isRetired)
        #expect(await restored.current.isAnonymous)
        #expect(!(await restored.allowsPublishing(.init(externalId: "owner-A", identityHash: "hash-A"))))
        #expect(f.store.string(StorageKey.subscriptionId) == "subscription-A")
        #expect(f.store.string(StorageKey.externalId) == "owner-A")
    }

    @Test(arguments: ["false", "null", "wrong-id", "malformed", "true"])
    func deletionRequiresExactAffirmativeReceipt(reply: String) async throws {
        let f = Fixture()
        defer { f.cleanup() }
        _ = await f.identity.identify(externalId: "owner-A", identityHash: "hash-A")
        f.store.set("subscription-A", for: StorageKey.subscriptionId)
        f.identity.retireSynchronously()
        f.mock.stub { request in
            if reply == "malformed" { return sdkJSONResponse(200, "not-json", url: request.url!) }
            let id = reply == "wrong-id" ? "foreign-subscription" : "subscription-A"
            return sdkJSONResponse(200, Self.subscription(id: id, deleted: reply == "wrong-id" ? "true" : reply), url: request.url!)
        }
        if reply == "true" {
            try await f.push.reconcileRetiredIdentity()
            #expect(f.store.string(StorageKey.subscriptionId) == nil)
            #expect(f.store.string(StorageKey.externalId) == nil)
        } else {
            await #expect(throws: (any Error).self) { try await f.push.reconcileRetiredIdentity() }
            #expect(f.store.string(StorageKey.subscriptionId) == "subscription-A")
            #expect(f.store.string(StorageKey.externalId) == "owner-A")
        }
        #expect(await f.identity.isRetired)
    }

    @Test func accountSwitchDeletesThenIdentifiesAndRegistersWithoutAnonymousWrite() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        _ = await f.identity.identify(externalId: "owner-A", identityHash: "hash-A")
        f.store.set("subscription-A", for: StorageKey.subscriptionId)
        f.store.set("0102", for: StorageKey.deviceToken)
        f.mock.stub { request in
            if request.httpMethod == "DELETE" { return sdkJSONResponse(200, Self.subscription(id: "subscription-A", deleted: "true"), url: request.url!) }
            if request.url?.lastPathComponent == "identify" { return sdkJSONResponse(200, Self.subscriberB, url: request.url!) }
            return sdkJSONResponse(200, Self.subscription(id: "subscription-B", deleted: "null"), url: request.url!)
        }
        _ = try await f.push.identify(externalId: "owner-B", email: nil, identityHash: "hash-B", attributes: nil, subscribe: [:])
        let requests = f.mock.requests()
        #expect(requests.map { ($0.httpMethod ?? "") + " " + ($0.url?.lastPathComponent ?? "") } == ["DELETE subscription-A", "POST identify", "POST subscriptions"])
        for request in requests where request.httpMethod == "POST" {
            let body = try #require(JSONSerialization.jsonObject(with: sdkBodyData(of: request)) as? [String: Any])
            #expect(body["externalId"] as? String == "owner-B")
        }
        #expect(await f.identity.current.externalId == "owner-B")
        #expect(f.store.string(StorageKey.subscriptionId) == "subscription-B")
    }

    @Test func repeatedRetirementInvalidatesAnAlreadyRetiredIdentifySnapshot() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.identity.retireSynchronously()
        let expected = await f.identity.snapshot
        f.identity.retireSynchronously()
        let result = await f.identity.identify(externalId: "owner-B", identityHash: "hash-B", ifUnchangedFrom: expected)
        #expect(result == nil, "A later logout must invalidate an in-flight identify even when already retired")
        #expect(await f.identity.isRetired)
    }

    nonisolated private static let subscriberB = #"{"success":true,"data":{"id":"subscriber-B","externalId":"owner-B","attributes":{},"verified":true,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}"#
    nonisolated private static func subscription(id: String, deleted: String) -> String {
        "{\"success\":true,\"data\":{\"id\":\"\(id)\",\"subscriberId\":\"subscriber-B\",\"channel\":\"push\",\"platform\":\"ios\",\"environment\":\"sandbox\",\"endpoint\":\"0102\",\"enabled\":true,\"status\":\"active\",\"deleted\":\(deleted)}}"
    }

    @MainActor private final class Fixture {
        let suite = "app.loopdy.sdk-retirement-test." + UUID().uuidString
        let defaults: UserDefaults
        let store: KeyValueStore
        let identity: IdentityStore
        let mock = SDKRetirementAPI()
        let push: PushManager
        init() {
            defaults = UserDefaults(suiteName: suite)!
            store = KeyValueStore(defaults: defaults)
            identity = IdentityStore(store: store)
            let api = ClientAPI(http: mock.client(maxAttempts: 1))
            let logger = BKLogger(level: .none)
            let queue = EventQueue(store: nil, api: api, logger: logger, identity: identity)
            let tracker = EventTracker(queue: queue, identity: identity, logger: logger)
            push = PushManager(configuration: .init(apiKey: mock.key, automaticSessionTracking: false,
                pushEnvironment: .sandbox, automaticPushHandling: false), api: api, identity: identity,
                store: store, tracker: tracker, logger: logger)
        }
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
    }
}
