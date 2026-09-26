import CryptoKit
import Foundation
import Testing
@testable import Bighelp

struct BighelpNotificationHostTrustTests {
    @Test func hostGrantBindsRecipientSignerTimeAndAuthenticatedEvent() throws {
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        let keyID = BighelpNotificationBase64URL.encode(Data(SHA256.hash(data: key)))
        let grant = BighelpNotificationHostGrant(accountID: "account-a", hostConnectionID: "host-a",
            grantID: "97c36e37-72b3-4da1-9e5a-7b59df0cad01", tenantID: "tenant-a", deviceID: "phone-a",
            profileID: "default", hostKeyID: keyID, hostPublicKey: BighelpNotificationBase64URL.encode(key),
            createdAt: 1_800_000_000, expiresAt: 1_800_001_000, revision: 1)
        try grant.validate()
        let event = grant.grantID + ":" + String(repeating: "a", count: 64)
        #expect(grant.authorizes(tenantID: "tenant-a", deviceID: "phone-a", senderKeyID: keyID,
                                 issuedAt: 1_800_000_100, eventID: event))
        for malformed in [grant.grantID + ":event-hash", grant.grantID + ":" + String(repeating: "A", count: 64),
                          event + "a", grant.grantID + ":"] {
            #expect(!grant.authorizes(tenantID: "tenant-a", deviceID: "phone-a", senderKeyID: keyID,
                                      issuedAt: 1_800_000_100, eventID: malformed))
        }
        #expect(!grant.authorizes(tenantID: "tenant-a", deviceID: "phone-a", senderKeyID: keyID,
                                  issuedAt: 1_800_000_100, eventID: event, eventType: "approval.required"))
        #expect(!grant.authorizes(tenantID: "tenant-a", deviceID: "phone-b", senderKeyID: keyID,
                                 issuedAt: 1_800_000_100, eventID: event))
        #expect(!grant.authorizes(tenantID: "tenant-b", deviceID: "phone-a", senderKeyID: keyID,
                                 issuedAt: 1_800_000_100, eventID: event))
        #expect(!grant.authorizes(tenantID: "tenant-a", deviceID: "phone-a", senderKeyID: keyID,
                                 issuedAt: 1_800_001_001, eventID: event))
        #expect(!grant.authorizes(tenantID: "tenant-a", deviceID: "phone-a", senderKeyID: keyID,
                                 issuedAt: 1_800_000_100, eventID: "other-grant:event"))
    }

    @Test func realKeychainPreservesOtherAccountsAndRejectsReboundGrant() throws {
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        let keyID = BighelpNotificationBase64URL.encode(Data(SHA256.hash(data: key)))
        func make(account: String, host: String, id: String, revision: Int = 1) -> BighelpNotificationHostGrant {
            BighelpNotificationHostGrant(accountID: account, hostConnectionID: host, grantID: id,
                tenantID: "tenant-a", deviceID: "phone-a", profileID: "default", hostKeyID: keyID,
                hostPublicKey: BighelpNotificationBase64URL.encode(key), createdAt: 1_800_000_000,
                expiresAt: 1_800_001_000, revision: revision)
        }
        let first = make(account: "a", host: "host-a", id: UUID().uuidString.lowercased())
        let second = make(account: "b", host: "host-b", id: UUID().uuidString.lowercased())
        let service = "app.loopdy.test.notification-host-trust." + UUID().uuidString
        let store = BighelpNotificationHostTrustStore(accessGroup: nil, service: service)
        defer { try? store.removeAll() }
        try store.upsert(first)
        try store.upsert(second)
        try store.upsert(first)
        #expect(try store.load().count == 2)
        #expect(throws: BighelpRelayTrustError.self) {
            try store.upsert(make(account: "b", host: "host-b", id: first.grantID, revision: 2))
        }
        try store.remove(accountID: "a")
        #expect(try store.load() == [second])
        try store.remove(grantID: second.grantID, accountID: "a")
        #expect(try store.load() == [second])
        try store.remove(grantID: second.grantID, accountID: "b")
        #expect(try store.load().isEmpty)
    }
}
