import Foundation
import Testing
@testable import BuzzKit

/// A tenant identity-secret rotation leaves a device holding a retired identity
/// whose hash the provider now refuses. That cleanup can never succeed, so it
/// must not block the next identify (which carries a hash from the new secret).
@Suite struct RetiredIdentityRecoveryTests {
    private func makeManager(_ mock: MockAPI) throws -> (PushManager, IdentityStore, KeyValueStore) {
        let store = KeyValueStore(defaults: UserDefaults(suiteName: "buzzkit-retire-\(UUID().uuidString)")!)
        let identity = IdentityStore(store: store)
        let api = ClientAPI(http: mock.client(maxAttempts: 1))
        let queue = EventQueue(store: try SQLiteStore(path: ":memory:"), api: api, logger: BKLogger(level: .none))
        let manager = PushManager(
            configuration: BuzzKit.Configuration(apiKey: mock.key, automaticPushHandling: false),
            api: api,
            identity: identity,
            store: store,
            tracker: EventTracker(queue: queue, identity: identity, logger: BKLogger(level: .none)),
            logger: BKLogger(level: .none)
        )
        return (manager, identity, store)
    }

    private static func subscriber(_ externalId: String) -> String {
        #"{"success":true,"data":{"id":"sub_1","externalId":"\#(externalId)","attributes":{},"verified":true,"createdAt":"2026-09-23T00:00:00.000Z","updatedAt":"2026-09-23T00:00:00.000Z"}}"#
    }

    private func retireStaleIdentity(_ identity: IdentityStore, _ store: KeyValueStore) async {
        _ = await identity.identify(externalId: "notify_old", identityHash: String(repeating: "a", count: 64))
        store.set("sbn_old", for: StorageKey.subscriptionId)
        _ = await identity.retire()
    }

    @Test(arguments: ["invalid_identity_hash", "not_found"])
    func unusableRetiredAuthorityDoesNotBlockTheNextIdentify(code: String) async throws {
        let mock = MockAPI()
        let (manager, identity, store) = try makeManager(mock)
        await retireStaleIdentity(identity, store)
        mock.stub { request in
            if request.httpMethod == "DELETE" {
                return jsonResponse(401, #"{"success":false,"data":null,"error":{"code":"\#(code)","message":"x"}}"#, url: request.url!)
            }
            return jsonResponse(200, Self.subscriber("notify_new"), url: request.url!)
        }

        _ = try await manager.identify(externalId: "notify_new", email: nil,
            identityHash: String(repeating: "b", count: 64), attributes: nil, subscribe: [:])

        let current = await identity.snapshot
        #expect(!current.isRetired)
        #expect(current.externalId == "notify_new")
        #expect(store.string(StorageKey.subscriptionId) == nil)
        #expect(mock.requests().contains { $0.url?.path.hasSuffix("/v1/client/identify") == true })
    }

    @Test func transientCleanupFailureStillBlocksSoTheSubscriptionIsNotOrphaned() async throws {
        let mock = MockAPI()
        let (manager, identity, store) = try makeManager(mock)
        await retireStaleIdentity(identity, store)
        mock.stub { request in
            if request.httpMethod == "DELETE" {
                return jsonResponse(500, #"{"success":false,"data":null,"error":{"code":"internal_error","message":"x"}}"#, url: request.url!)
            }
            return jsonResponse(200, Self.subscriber("notify_new"), url: request.url!)
        }

        await #expect(throws: BuzzKitError.self) {
            _ = try await manager.identify(externalId: "notify_new", email: nil,
                identityHash: String(repeating: "b", count: 64), attributes: nil, subscribe: [:])
        }
        #expect(store.string(StorageKey.subscriptionId) == "sbn_old")
        #expect(await identity.snapshot.isRetired)
    }
}
